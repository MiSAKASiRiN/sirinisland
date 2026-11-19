import Foundation
import Combine
import Darwin

struct CodexWindow: Decodable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var percent: String { remaining.formatted(.number.precision(.fractionLength(0...1))) + "%" }

    func label(slot: String) -> String {
        guard let mins = windowDurationMins, mins > 0 else { return slot == "primary" ? "主要额度" : "次要额度" }
        if mins == 10080 { return "周额度" }
        if mins == 1440 { return "日额度" }
        if mins.isMultiple(of: 60) { return "\(mins / 60) 小时额度" }
        return "\(mins) 分钟额度"
    }
}

struct CodexQuota: Decodable {
    struct Limits: Decodable {
        let primary: CodexWindow?
        let secondary: CodexWindow?
    }
    struct ResetCredits: Decodable { let availableCount: Int }
    let accountId: String?
    let ordinaryUsageAllowed: Bool?
    let rateLimits: Limits
    let rateLimitsByLimitId: [String: Limits]?
    let rateLimitResetCredits: ResetCredits?

    var windows: [(slot: String, window: CodexWindow)] {
        let limits = rateLimitsByLimitId?["codex"] ?? rateLimits
        return [("primary", limits.primary), ("secondary", limits.secondary)].compactMap { slot, value in
            value.map { (slot, $0) }
        }
    }
}

private enum QuotaError: String, Error {
    case folder = "请选择 Codex 数据目录"
    case executable = "找不到 Codex 客户端"
    case unavailable = "额度读取失败，请检查登录和网络"
    case timeout = "额度查询超时"
}

private enum CodexQuotaReader {
    struct Reply: Decodable { let id: Int?; let result: CodexQuota? }

    static func read(directory: String) throws -> CodexQuota {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let fm = FileManager.default
        guard ["auth.json", "sessions", "config.toml"].contains(where: {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }) else { throw QuotaError.folder }
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let binary = candidates.first(where: fm.isExecutableFile(atPath:)) else { throw QuotaError.executable }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        // Let the official client resolve credentials for the chosen home.
        process.environment = ["CODEX_HOME": root.path, "HOME": NSHomeDirectory(),
                               "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "TMPDIR": NSTemporaryDirectory()]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting, reader = output.fileHandleForReading
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        defer {
            try? writer.close()
            if process.isRunning { process.terminate() }
            try? reader.close()
        }
        func send(_ line: String) throws { try writer.write(contentsOf: Data((line + "\n").utf8)) }
        try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"SirinIsland","version":"1"},"capabilities":{"experimentalApi":true}}}"#)
        let deadline = ProcessInfo.processInfo.systemUptime + 18
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw QuotaError.timeout }
            var fd = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, Int32(ceil(left * 1000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready != 0 else { throw QuotaError.timeout }
            guard ready > 0 else { throw QuotaError.unavailable }
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw QuotaError.unavailable }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count < 2_000_000 else { throw QuotaError.unavailable }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                defer { pending.removeSubrange(...newline) }
                guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = json["id"] as? Int else { continue }
                guard json["error"] == nil else { throw QuotaError.unavailable }
                if id == 1 {
                    try send(#"{"method":"initialized"}"#)
                    try send(#"{"id":2,"method":"account/rateLimits/read","params":{}}"#)
                } else if id == 2, let result = try JSONDecoder().decode(Reply.self, from: line).result {
                    return result
                }
            }
        }
    }
}

struct CodexThreshold: Codable, Equatable {
    var reset: Int?
    var lastLevel: Int?

    mutating func observe(_ window: CodexWindow, now: Date) -> Int? {
        if let end = window.resetsAt, Double(end) <= now.timeIntervalSince1970 { return nil }
        if let end = window.resetsAt, reset != end { reset = end; lastLevel = nil }
        if window.remaining > 20 {
            if window.resetsAt == nil { lastLevel = nil }
            return nil
        }
        let level = window.remaining <= 5 ? 5 : 20
        guard level < (lastLevel ?? 100) else { return nil }
        lastLevel = level
        return level
    }
}

final class CodexQuotaMonitor: ObservableObject {
    @Published private(set) var directory: String
    @Published private(set) var quota: CodexQuota?
    @Published private(set) var status = "正在读取额度…"
    var onLowQuota: ((String, String) -> Void)?
    private let defaults: UserDefaults
    private var alerts: [String: CodexThreshold]
    private var request: UUID?
    private var timer: Timer?
    private var fetched: Date?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser
        let business = home.appendingPathComponent(".codex-business").path
        directory = defaults.string(forKey: "codexDirectory") ??
            (FileManager.default.fileExists(atPath: business) ? business : home.appendingPathComponent(".codex").path)
        alerts = defaults.data(forKey: "codexThresholds").flatMap {
            try? JSONDecoder().decode([String: CodexThreshold].self, from: $0)
        } ?? [:]
    }

    func select(_ url: URL) {
        let next = url.standardizedFileURL.path
        guard next != directory else { refresh(); return }
        directory = next
        defaults.set(next, forKey: "codexDirectory")
        request = nil
        quota = nil
        fetched = nil
        status = "正在读取额度…"
        refresh()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
    }
    func stop() { timer?.invalidate(); timer = nil; request = nil }

    func refreshIfNeeded() {
        if fetched.map({ Date().timeIntervalSince($0) < 30 }) != true { refresh() }
    }

    private func refresh() {
        guard request == nil else { return }
        let id = UUID(), path = directory
        request = id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CodexQuotaReader.read(directory: path) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == id else { return }
                self.request = nil
                self.fetched = Date()
                switch result {
                case .success(let snapshot):
                    self.quota = snapshot
                    self.notify(snapshot)
                case .failure(let error):
                    self.quota = nil
                    self.status = (error as? QuotaError ?? .unavailable).rawValue
                }
            }
        }
    }

    private func notify(_ snapshot: CodexQuota) {
        let previous = alerts
        for (slot, window) in snapshot.windows {
            let source = snapshot.accountId ?? directory
            let key = "\(source)|\(slot)|\(window.windowDurationMins ?? 0)"
            var threshold = alerts[key] ?? CodexThreshold()
            if let level = threshold.observe(window, now: Date()) {
                onLowQuota?("codex-\(key)-\(threshold.reset ?? 0)-\(level)",
                            "\(window.label(slot: slot))剩余 \(window.percent)")
            }
            alerts[key] = threshold
        }
        if previous != alerts { defaults.set(try? JSONEncoder().encode(alerts), forKey: "codexThresholds") }
    }
}

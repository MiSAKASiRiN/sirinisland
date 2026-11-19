import AppKit
import SwiftUI

enum IslandTab: CaseIterable, Hashable {
    case focus, shelf, music, codex, terminal

    var title: String {
        switch self {
        case .focus: return "专注"
        case .shelf: return "暂存"
        case .music: return "音乐"
        case .codex: return "Codex"
        case .terminal: return "终端"
        }
    }

    var symbol: String {
        switch self {
        case .focus: return "timer"
        case .shelf: return "tray"
        case .music: return "music.note"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        }
    }
}
enum ClockPhase: String, Codable { case ready, running, paused, finished }

struct FocusClock: Codable {
    static let durations = [5, 25, 45]
    var canChangeDuration: Bool { phase == .ready || phase == .finished }

    var minutes = 25
    var phase = ClockPhase.ready
    var deadline: Date?
    var held = 25 * 60

    func remaining(at now: Date) -> Int {
        guard phase == .running, let deadline else { return held }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    mutating func sync(_ now: Date) {
        if phase == .running && remaining(at: now) == 0 {
            phase = .finished
            deadline = nil
            held = 0
        }
    }

    mutating func reset(_ duration: Int) {
        minutes = duration
        held = duration * 60
        deadline = nil
        phase = .ready
    }

    mutating func toggle(at now: Date) {
        sync(now)
        if phase == .running {
            held = remaining(at: now)
            deadline = nil
            phase = .paused
        } else {
            if phase == .finished { reset(minutes) }
            deadline = now.addingTimeInterval(TimeInterval(held))
            phase = .running
        }
    }
}

struct ShelfItem: Codable, Identifiable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var url: URL {
        var stale = false
        if let bookmark,
           let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale) { return resolved }
        return URL(fileURLWithPath: path)
    }
    func copyFileReference(to pasteboard: NSPasteboard = .general) -> Bool {
        let file = url
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([file as NSURL])
    }
    init(_ url: URL) {
        path = url.path
        bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

enum LyricRenderer: String, CaseIterable {
    case native, amll
}

final class IslandModel: ObservableObject {
    @Published var lyricRenderer: LyricRenderer {
        didSet { defaults.set(lyricRenderer.rawValue, forKey: "lyricRenderer") }
    }
    @Published var keepsCompactLyrics: Bool {
        didSet { defaults.set(keepsCompactLyrics,forKey:"keepsCompactLyrics") }
    }
    static let previewSecondsRange = 1...30
    @Published var autoExpandsOnTrackChange: Bool {
        didSet { defaults.set(autoExpandsOnTrackChange,forKey:"autoExpandsOnTrackChange") }
    }
    @Published private(set) var previewSeconds: Int
    func setPreviewSeconds(_ seconds: Int) {
        let value = Self.boundedPreviewSeconds(seconds)
        guard value != previewSeconds else { return }
        previewSeconds = value
        defaults.set(value,forKey:"previewSeconds")
    }
    private static func boundedPreviewSeconds(_ seconds: Int) -> Int {
        min(previewSecondsRange.upperBound,max(previewSecondsRange.lowerBound,seconds))
    }
    @Published var song: IslandSong?
    // Keep the outgoing metadata and marquee alive until the compact wing has faded.
    @Published var departingCompactSong: IslandSong?
    let meter = SpectrumMeter()
    let terminal = IslandTerminal()

    func selectPage(_ page: IslandTab) {
        terminal.wantsFocus = page == .terminal
        tab = page
    }

    let codex: CodexQuotaMonitor
    let lyrics: IslandLyrics
    // During an automatic opening both views keep drawing the last presented cover.
    @Published var openingCover: IslandSong?
    @Published private(set) var coverViewRevision = 0
    func finishCoverHold(interrupted: Bool = false) {
        guard openingCover != nil else { return }
        if interrupted { coverViewRevision += 1 }
        openingCover = nil
    }
    @Published var panelExpanded = false
    @Published var showFooterMenu = false
    @Published var footerEvent: FooterEvent?
    @Published var volumeKeysActive = false
    var toggleMusic: (() -> Void)?
    @Published var tab: IslandTab = .focus
    @Published var pinned = false
    @Published var dragOver = false
    @Published var now = Date()
    @Published private(set) var clock: FocusClock
    @Published private(set) var items: [ShelfItem]
    var exporting = false
    var exportEnded: (() -> Void)?
    var onFinish: (() -> Void)?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        codex = CodexQuotaMonitor(defaults: defaults)
        lyrics = IslandLyrics(defaults: defaults)
        lyricRenderer = defaults.string(forKey: "lyricRenderer").flatMap(LyricRenderer.init(rawValue:)) ?? .native
        autoExpandsOnTrackChange = defaults.object(forKey:"autoExpandsOnTrackChange") as? Bool ?? true
        previewSeconds = Self.boundedPreviewSeconds(defaults.object(forKey:"previewSeconds") as? Int ?? 4)
        keepsCompactLyrics = defaults.bool(forKey:"keepsCompactLyrics")
        clock = defaults.data(forKey: "clock").flatMap { try? JSONDecoder().decode(FocusClock.self, from: $0) } ?? FocusClock()
        items = defaults.data(forKey: "shelf").flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
    }
    func tick(_ date: Date = Date()) {
        let changedMinute = Int(now.timeIntervalSince1970 / 60) != Int(date.timeIntervalSince1970 / 60)
        if changedMinute || (clock.phase == .running && remaining != clock.remaining(at: date)) {
            now = date
        }
        if clock.phase == .running && clock.remaining(at: date) == 0 {
            clock.sync(date)
            saveClock()
            onFinish?()
        }
    }
    var remaining: Int { clock.remaining(at: now) }
    var digits: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
    func toggle() { now = Date(); clock.toggle(at: now); saveClock() }
    func reset(_ minutes: Int) { clock.reset(minutes); saveClock() }
    func stash(_ urls: [URL]) {
        var known = Set(items.map { $0.url.standardizedFileURL.path })
        let fresh = urls.filter { $0.isFileURL && known.insert($0.standardizedFileURL.path).inserted }
        items.insert(contentsOf: fresh.map(ShelfItem.init), at: 0)
        tab = .shelf
        saveShelf()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; saveShelf() }
    private func saveClock() { defaults.set(try? JSONEncoder().encode(clock), forKey: "clock") }
    private func saveShelf() { defaults.set(try? JSONEncoder().encode(items), forKey: "shelf") }
}

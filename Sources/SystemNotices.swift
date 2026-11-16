import AppKit
import ApplicationServices

struct BannerNotice: Equatable {
    let id: String
    let application: String
    let title: String
    let preview: String

    var applicationIcon: NSImage? {
        let workspace = NSWorkspace.shared
        if let icon = workspace.runningApplications.first(where: { $0.localizedName == application })?.icon { return icon }
        // Notification Center supplies a localized display name, not a bundle identifier.
        guard !application.isEmpty, !application.contains("/"),
              let path = workspace.fullPath(forApplication: application), path.hasSuffix(".app") else { return nil }
        return workspace.icon(forFile: path)
    }

    init(id: String, description: String, fields: [String: String]) {
        self.id = id
        let title = fields["title"] ?? ""
        let subtitle = fields["subtitle"] ?? ""
        let body = fields["body"] ?? ""
        let separators = CharacterSet(charactersIn: ",，、").union(.whitespacesAndNewlines)
        // The banner description begins with its sender, followed by the visible fields.
        let firstField = [title, subtitle, body].first { !$0.isEmpty }
        if let firstField, let boundary = [", ", "，", "、", ",", "， "].compactMap({
            description.range(of: $0 + firstField)
        }).map(\.lowerBound).min() {
            application = String(description[..<boundary]).trimmingCharacters(in: separators)
        } else {
            application = String(description.prefix { !",，、".contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.title = title.isEmpty ? application : title
        self.preview = [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private func axAttribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}

struct SystemFocusNotice: Equatable {
    let mode: String
    let state: String
    let symbol: String

    var label: String {
        let status: String
        switch state.lowercased() {
        case "on", "开", "開", "开启", "開啟": status = "已开启"
        case "off", "关", "關", "关闭", "關閉": status = "已关闭"
        default: status = state
        }
        return mode + " · " + status
    }
}

final class SystemBannerMonitor {
    enum Source: String {
        case notifications = "com.apple.notificationcenterui"
        case focus = "com.apple.MenuBarAgent"
    }

    private let source: Source
    var onNotice: ((FooterEvent) -> Void)?
    private var lastFocus: SystemFocusNotice?

    init(_ source: Source) { self.source = source }
    private let reader = DispatchQueue(label: "SirinIsland.notification-banners", qos: .utility)
    private var pid: pid_t?
    private var observer: AXObserver?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var reading = false
    private var known: [String] = []
    private var generation = 0

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.3
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func refresh() {
        let next = AXIsProcessTrusted() ? NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).first?.processIdentifier : nil
        if next != pid {
            unbind()
            pid = next
            if let next {
                let app = AXUIElementCreateApplication(next)
                var listener: AXObserver?
                let status = AXObserverCreate(next, { _, _, _, context in
                    guard let context else { return }
                    Unmanaged<SystemBannerMonitor>.fromOpaque(context).takeUnretainedValue().schedule()
                }, &listener)
                if status == .success, let listener {
                    observer = listener
                    for event in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
                        AXObserverAddNotification(listener, app, event as CFString, Unmanaged.passUnretained(self).toOpaque())
                    }
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(listener), .commonModes)
                }
            }
        }
        scan()
    }

    private func schedule() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.scan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scan() {
        guard let pid, !reading else { return }
        reading = true
        let revision = generation
        let source = self.source
        reader.async { [weak self] in
            let notices = source == .notifications ? Self.banners(pid: pid) : []
            let focus = source == .focus ? Self.focusBanner(pid: pid) : nil
            DispatchQueue.main.async {
                guard let self, self.generation == revision else { return }
                self.reading = false
                if let focus, focus != self.lastFocus {
                    self.lastFocus = focus
                    self.onNotice?(.focus(focus))
                }
                for notice in notices where !self.known.contains(notice.id) {
                    self.known.append(notice.id)
                    if self.known.count > 128 { self.known.removeFirst() }
                    self.onNotice?(.banner(notice))
                }
            }
        }
    }

    static func banners(pid: pid_t) -> [BannerNotice] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var result: [BannerNotice] = []
        func visit(_ node: AXUIElement, _ depth: Int) {
            guard depth < 10 else { return }
            if axAttribute(node, kAXSubroleAttribute) as? String == "AXNotificationCenterBanner" {
                guard let id = axAttribute(node, kAXIdentifierAttribute) as? String else { return }
                let description = axAttribute(node, kAXDescriptionAttribute) as? String ?? ""
                var fields: [String: String] = [:]
                for child in axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    guard let key = axAttribute(child, kAXIdentifierAttribute) as? String,
                          ["title", "subtitle", "body"].contains(key) else { continue }
                    fields[key] = axAttribute(child, kAXValueAttribute) as? String
                }
                let notice = BannerNotice(id: id, description: description, fields: fields)
                if !notice.title.isEmpty || !notice.preview.isEmpty { result.append(notice) }
                return
            }
            if axAttribute(node, kAXIdentifierAttribute) as? String == "widgets-overlay-view" { return }
            for child in axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        for window in axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if axAttribute(window, kAXSubroleAttribute) as? String == kAXSystemDialogSubrole { visit(window, 0) }
        }
        return result
    }

    static func focusBanner(pid: pid_t) -> SystemFocusNotice? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for window in axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        where axAttribute(window, kAXIdentifierAttribute) as? String == "focus-system-banner" {
            var text: [String] = []
            var symbol = "moon.fill"
            func visit(_ node: AXUIElement, _ depth: Int) {
                guard depth < 7 else { return }
                switch axAttribute(node, kAXRoleAttribute) as? String {
                case kAXStaticTextRole:
                    if let value = axAttribute(node, kAXValueAttribute) as? String, !value.isEmpty { text.append(value) }
                case kAXImageRole:
                    if let name = axAttribute(node, kAXIdentifierAttribute) as? String, !name.isEmpty { symbol = name }
                default:
                    for child in axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
                }
            }
            visit(window, 0)
            if text.count >= 2 { return .init(mode: text[0], state: text[1], symbol: symbol) }
        }
        return nil
    }

    private func unbind() {
        generation += 1
        pending?.cancel()
        pending = nil
        reading = false
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        pid = nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        unbind()
    }
}

import AppKit
import SwiftUI
import TerminalSupport

final class IslandTerminal: ObservableObject {
    static let extraHeight: CGFloat = 150
    static var shellPath: String {
        if let configured = getpwuid(getuid())?.pointee.pw_shell {
            let path = String(cString: configured)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    @Published private(set) var ended = false
    @Published var wantsFocus = false
    private var shell: IslandShell?

    @MainActor func attach(to container: NSView) {
        let needsLaunch = shell == nil
        let view: IslandShell
        if let shell { view = shell }
        else {
            view = IslandShell(frame: container.bounds)
            view.font = NSFont(name: "MesloLGS-NF-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.nativeBackgroundColor = NSColor(white: 0.065, alpha: 1)
            view.nativeForegroundColor = NSColor(white: 0.96, alpha: 1)
            view.onEnd = { [weak self] in self?.ended = true }
            shell = view
        }
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        if needsLaunch {
            let path = Self.shellPath
            view.startProcess(executable: path, execName: "-" + URL(fileURLWithPath: path).lastPathComponent,
                              currentDirectory: NSHomeDirectory())
        }
        if wantsFocus, let window = container.window {
            window.makeKey()
            if window.makeFirstResponder(view) { wantsFocus = false }
        }
    }

    func restart() {
        guard ended else { return }
        shell?.removeFromSuperview()
        shell = nil
        wantsFocus = true
        ended = false
    }

    func stop() { shell?.terminate() }
}

private final class TerminalContainer: NSView {
    var attach: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attach?() }
    }
}

private struct TerminalViewport: NSViewRepresentable {
    @ObservedObject var terminal: IslandTerminal
    let active: Bool

    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        container.attach = { [weak container, weak terminal] in
            // Let SwiftUI finish applying the tab and its geometry before requesting the keyboard.
            DispatchQueue.main.async {
                guard let container, container.window != nil, container.attach != nil else { return }
                terminal?.attach(to: container)
            }
        }
        if active { container.attach?() } else { container.attach = nil }
    }

    static func dismantleNSView(_ container: TerminalContainer, coordinator: ()) { container.attach = nil }
}

struct IslandTerminalPane: View {
    @ObservedObject var terminal: IslandTerminal
    let active: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TerminalViewport(terminal: terminal, active: active)
                .padding(7)
            if terminal.ended {
                Button("重新启动终端", action: terminal.restart)
                    .buttonStyle(.borderedProminent).padding(8)
            }
        }
        .frame(height: 105 + IslandTerminal.extraHeight)
        .background(Color(white: 0.065))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

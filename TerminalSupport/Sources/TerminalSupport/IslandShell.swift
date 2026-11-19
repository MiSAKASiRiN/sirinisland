import AppKit
import SwiftTerm

public final class IslandShell: LocalProcessTerminalView {
    public var onEnd: (() -> Void)?

    public override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onEnd?()
    }

    public override func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        super.processFailedToStart(source, error: error)
        onEnd?()
    }
}

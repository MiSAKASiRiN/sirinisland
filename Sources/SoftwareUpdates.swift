import AppKit
import Sparkle
import SwiftUI

final class SoftwareUpdates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let useGitHubKey = "SirinUpdatesUseGitHub"
    private(set) var controller: SPUStandardUpdaterController?
    private(set) var pendingVersion: String?

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard UserDefaults.standard.bool(forKey: Self.useGitHubKey) else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "SirinGitHubFeedURL") as? String
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverWillFinishUpdateSession() { pendingVersion = nil }
}

struct UpdateSettings: View {
    let controller: SPUStandardUpdaterController
    @AppStorage(SoftwareUpdates.useGitHubKey) private var useGitHub = false
    @State private var checks = false
    @State private var downloads = false
    @State private var canCheck = false

    var body: some View {
        let updater = controller.updater
        VStack(spacing: 8) {
            if Bundle.main.object(forInfoDictionaryKey: "SirinGitHubFeedURL") != nil {
                Picker("更新来源", selection: $useGitHub) {
                    Text("七牛 CDN").tag(false)
                    Text("GitHub Releases").tag(true)
                }
                .disabled(!canCheck)
            }
            Toggle("自动检查更新", isOn: Binding(get: { checks }, set: { updater.automaticallyChecksForUpdates = $0 }))
            Toggle("自动下载并在退出时安装", isOn: Binding(get: { downloads }, set: { updater.automaticallyDownloadsUpdates = $0 }))
                .disabled(!checks)
            Button("检查更新…") { controller.checkForUpdates(nil) }.disabled(!canCheck)
        }
        .fixedSize()
        .onReceive(updater.publisher(for: \.automaticallyChecksForUpdates)) { checks = $0 }
        .onReceive(updater.publisher(for: \.automaticallyDownloadsUpdates)) { downloads = $0 }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}

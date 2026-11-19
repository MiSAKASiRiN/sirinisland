import AppKit
import SwiftUI

private enum SettingsPage: Hashable {
    case general, island(IslandTab), about

    var title: String {
        switch self {
        case .general: return "通用"
        case .island(let tab): return tab.title
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .island(let tab): return tab.symbol
        case .about: return "info.circle"
        }
    }
}

private struct IslandSettings: View {
    @ObservedObject var model: IslandModel
    @State private var showingLyricFilters = false
    @State private var selection: SettingsPage = .general
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                row(.general)
                Section("页面") {
                    ForEach(IslandTab.allCases, id: \.self) { row(.island($0)) }
                }
                Section { row(.about) }
            }
            .listStyle(.sidebar)
            .frame(width: 176)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                detail
            }
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(IslandMotion.reveal(reduced: reducedMotion))
            .animation(IslandMotion.curve(0.18), value: model.autoExpandsOnTrackChange)
        }
        .animation(IslandMotion.settle(0.24, reduced: reducedMotion), value: selection)
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(minWidth: 580, minHeight: 358)
        .sheet(isPresented: $showingLyricFilters) { LyricFilterSettings(lyrics: model.lyrics) }
    }

    private func row(_ page: SettingsPage) -> some View {
        Label(page.title, systemImage: page.symbol).tag(page)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:
            Form {
                Section("系统提示") {
                    LabeledContent("音量与屏幕亮度") {
                        if model.volumeKeysActive { Text("由灵动岛显示") }
                        else { Button("授权接管调节键…", action: SystemVolume.openAccess) }
                    }
                }
            }
        case .island(.focus):
            Form {
                Section("专注计时") {
                    Picker("计时时长", selection: Binding(get: { model.clock.minutes }, set: model.reset)) {
                        ForEach(FocusClock.durations, id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                    .disabled(!model.clock.canChangeDuration)
                    if !model.clock.canChangeDuration {
                        LabeledContent(model.clock.phase == .running ? "计时中" : "已暂停", value: model.digits)
                            .monospacedDigit()
                    }
                }
            }
        case .island(.shelf):
            Form {
                Section("暂存文件") {
                    if model.items.isEmpty {
                        Text("将文件拖到灵动岛即可暂存").foregroundStyle(.secondary)
                    }
                    ForEach(model.items) { item in
                        HStack {
                            Image(systemName: "doc")
                            Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle).help(item.path)
                            Spacer()
                            Button("移出暂存架") { model.remove(item.id) }
                        }
                    }
                }
            }
        case .island(.codex):
            CodexQuotaSettings(monitor: model.codex)
        case .island(.music):
            Form {
                Section("歌词") {
                    Picker("歌词渲染器", selection: $model.lyricRenderer) {
                        Text("Swift 原生").tag(LyricRenderer.native)
                        Text("AMLL").tag(LyricRenderer.amll)
                    }
                    Toggle("收起时显示歌词", isOn: $model.keepsCompactLyrics)
                    LabeledContent("歌词过滤") {
                        Button("管理规则…") { showingLyricFilters = true }
                    }
                }
                Section("切歌预览") {
                    Toggle("切歌时自动展开", isOn: $model.autoExpandsOnTrackChange)
                    Stepper(value: Binding(get: { model.previewSeconds }, set: model.setPreviewSeconds),
                            in: IslandModel.previewSecondsRange) {
                        LabeledContent("展开停留时间", value: "\(model.previewSeconds) 秒").monospacedDigit()
                    }
                    .accessibilityValue("\(model.previewSeconds) 秒")
                    .disabled(!model.autoExpandsOnTrackChange)
                }
            }
        case .about:
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
                    .accessibilityHidden(true)
                Text("SirinIsland").font(.title.bold())
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("版本 \(version)").font(.callout).foregroundStyle(.secondary)
                }
                Text("Designed by Sirin").padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class SettingsWindow: NSWindowController {
    init(model: IslandModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: IslandSettings(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "SirinIsland 设置"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow
        window.collectionBehavior = [.moveToActiveSpace]
        window.setContentSize(NSSize(width: 680, height: 410))
        window.center()
        window.setFrameAutosaveName("SirinIslandSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

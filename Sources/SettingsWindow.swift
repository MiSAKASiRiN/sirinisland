import AppKit
import SwiftUI

private struct IslandSettings: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Form {
            Section("系统提示") {
                LabeledContent("音量与屏幕亮度") {
                    if model.volumeKeysActive { Text("由灵动岛显示") }
                    else { Button("授权接管调节键…",action:SystemVolume.openAccess) }
                }
            }
            Section("歌词") {
                Picker("歌词渲染器", selection: $model.lyricRenderer) {
                    Text("Swift 原生").tag(LyricRenderer.native)
                    Text("AMLL").tag(LyricRenderer.amll)
                }
                .pickerStyle(.menu)
                Toggle("收起时显示歌词", isOn:$model.keepsCompactLyrics)
            }
            Section("切歌预览") {
                Toggle("切歌时自动展开", isOn:$model.autoExpandsOnTrackChange)
                LabeledContent("展开停留时间") {
                    Stepper(value:Binding(get:{ model.previewSeconds },set:model.setPreviewSeconds),
                            in:IslandModel.previewSecondsRange) {
                        Text("\(model.previewSeconds) 秒").monospacedDigit()
                    }
                    .accessibilityLabel("展开停留时间")
                    .accessibilityValue("\(model.previewSeconds) 秒")
                }
                .disabled(!model.autoExpandsOnTrackChange)
            }
        }
        .toggleStyle(.switch)
        .formStyle(.grouped)
        .animation(IslandMotion.curve(0.18), value:model.autoExpandsOnTrackChange)
        .frame(width:380, height:356)
    }
}

final class SettingsWindow: NSWindowController {
    init(model: IslandModel) {
        let window = NSWindow(contentViewController:NSHostingController(rootView:IslandSettings(model:model)))
        window.styleMask = [.titled,.closable,.miniaturizable]
        window.title = "SirinIsland 设置"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        super.init(window:window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps:true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

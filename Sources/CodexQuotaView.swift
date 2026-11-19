import SwiftUI

struct CodexQuotaCard: View {
    @ObservedObject var monitor: CodexQuotaMonitor
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quota = monitor.quota {
                HStack {
                    Label("Codex", systemImage: "terminal").foregroundStyle(honey)
                    Spacer()
                    Text(quota.ordinaryUsageAllowed.map { $0 ? "可继续使用" : "暂不可用" } ?? "使用状态未知")
                        .foregroundStyle(quota.ordinaryUsageAllowed == false ? Color.orange : .secondary)
                }.font(.system(size: 12, weight: .semibold))
                ForEach(quota.windows, id: \.slot) { slot, window in
                    HStack(spacing: 6) {
                        Text(window.label(slot: slot))
                        Text("剩余 " + window.percent).bold().monospacedDigit()
                            .foregroundStyle(window.remaining <= 5 ? .red : window.remaining <= 20 ? .orange : .white)
                        Spacer(minLength: 0)
                        if let reset = window.resetsAt {
                            let date = Date(timeIntervalSince1970: Double(reset))
                            Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) + " 重置")
                                .foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 11))
                }
                if quota.windows.isEmpty { Text("暂无额度窗口").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text("可用重置次数").foregroundStyle(.secondary)
                    Text(quota.rateLimitResetCredits.map { "\($0.availableCount) 次" } ?? "未知").monospacedDigit()
                }.font(.system(size: 11))
            } else {
                Label("Codex", systemImage: "terminal").font(.headline).foregroundStyle(honey)
                Text(monitor.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13).frame(maxWidth: .infinity, alignment: .leading).frame(height: 105)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color(white: 0.075)))
        .animation(IslandMotion.settle(0.26, reduced: reduced), value: monitor.quota?.windows.count)
        .onAppear { if expanded { monitor.refreshIfNeeded() } }
        .onChange(of: expanded) { if $0 { monitor.refreshIfNeeded() } }
    }
}

struct CodexQuotaSettings: View {
    @ObservedObject var monitor: CodexQuotaMonitor

    var body: some View {
        Form {
            Section("额度来源") {
                Text(monitor.directory).textSelection(.enabled)
                Button("选择 Codex 数据目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.showsHiddenFiles = true
                    panel.directoryURL = URL(fileURLWithPath: monitor.directory).deletingLastPathComponent()
                    panel.prompt = "选择"
                    if panel.runModal() == .OK, let url = panel.url { monitor.select(url) }
                }
            }
        }
    }
}

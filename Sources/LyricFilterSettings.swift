import SwiftUI

struct LyricFilterSettings: View {
    @ObservedObject var lyrics: IslandLyrics
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var draft = ""
    @State private var editing: String?
    @FocusState private var fieldFocused: Bool

    private var validation: String? {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入正则表达式" }
        if lyrics.filters.customPatterns.contains(draft), draft != editing { return "这条规则已存在" }
        do { _ = try NSRegularExpression(pattern: draft) }
        catch { return "正则语法无效，请检查括号或转义符。" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("歌词过滤").font(.title2.bold()).padding([.horizontal, .top], 20)
            Form {
                Section("内置规则") {
                    ForEach(BuiltInLyricFilter.allCases, id: \.self) { rule in
                        Toggle(rule.title, isOn: Binding(
                            get: { !lyrics.filters.disabledBuiltIns.contains(rule.rawValue) },
                            set: { enabled in
                                if enabled { lyrics.filters.disabledBuiltIns.remove(rule.rawValue) }
                                else { lyrics.filters.disabledBuiltIns.insert(rule.rawValue) }
                            }))
                    }
                }
                Section("自定义正则") {
                    ForEach(lyrics.filters.customPatterns, id: \.self) { pattern in
                        HStack {
                            Text(verbatim: pattern).font(.system(.body, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle).help(pattern)
                            Spacer()
                            Button { editing = pattern; draft = pattern; fieldFocused = true } label: {
                                Image(systemName: "pencil")
                            }.accessibilityLabel("编辑规则")
                            Button {
                                lyrics.filters.customPatterns.removeAll { $0 == pattern }
                                if editing == pattern { clearDraft() }
                            } label: { Image(systemName: "minus.circle") }.accessibilityLabel("删除规则")
                        }
                    }
                    HStack {
                        TextField("正则表达式", text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .focused($fieldFocused)
                            .onSubmit(save)
                        if editing != nil { Button("取消", action: clearDraft) }
                        Button(editing == nil ? "添加" : "保存", action: save)
                            .disabled(validation != nil)
                    }
                    if !draft.isEmpty, let validation {
                        Text(validation).foregroundStyle(.red).font(.callout)
                    }
                }
                Text("原文匹配时隐藏整句。仅译文匹配时保留原文和注音。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(width: 460, height: 410)
        .animation(IslandMotion.settle(0.24, reduced: reducedMotion), value: lyrics.filters)
    }

    private func save() {
        guard validation == nil else { return }
        if let editing, let index = lyrics.filters.customPatterns.firstIndex(of: editing) {
            lyrics.filters.customPatterns[index] = draft
        } else {
            lyrics.filters.customPatterns.append(draft)
        }
        clearDraft()
    }

    private func clearDraft() {
        draft = ""
        editing = nil
    }
}

import Foundation

enum BuiltInLyricFilter: String, CaseIterable {
    case credits, translation, instrumental

    var title: String {
        switch self {
        case .credits: return "词曲与制作署名"
        case .translation: return "翻译来源"
        case .instrumental: return "纯音乐提示"
        }
    }

    var pattern: String {
        switch self {
        case .credits:
            let english = #"(?:composed|lyric(?:e?s)?|written|arranged|produced|mixed|mastered|music|words)\s+by\b"#
            let role = #"(?:作[词詞曲]|[编編]曲|填[词詞]|[词詞]曲|[製制]作人|混音|母[带帶]|[监監][制製]|[录錄]音|和[声聲]|演唱)"#
            let label = #"(?:lyrics?|composer|producer|arranger|[词詞曲](?:\s*[/／、&]\s*[词詞曲])?)\s*[:：]"#
            let credit = role + #"(?:\s*[/／、・&]\s*"# + role + #")*(?:\s*(?:[a-z ]+\s*)?[:：=】\]]|\s+|$)"#
            return #"(?i)^\s*[\[【（(]?\s*(?:"# + [english, label, credit].joined(separator: "|") + ")"
        case .translation:
            return #"(?i)^\s*[\[【（(]?\s*(?:(?:以下|本首|本曲)?(?:歌曲|歌词|歌詞)?(?:的)?(?:中文|简体中文|繁體中文)?(?:翻[译譯]|[译譯]文)\s*(?:由\s*.+?\s*(?:提供|贡献|貢獻|制作|製作)|[:：])|translated\s+by\b|translation\s+(?:by|provided\s+by)\b)"#
        case .instrumental:
            return #"^\s*[\[【（(]?\s*(?:(?:此歌曲|本歌曲|本曲|此曲|本首歌曲)\s*[为為是]\s*)?(?:(?:没有|沒有|未)填[词詞]的)?[纯純]音[乐樂][\s,，、。.!！：:～~—]*(?:[请請](?:您)?欣[赏賞])?[\s。.!！～~）)】\]]*$"#
        }
    }
}

struct LyricFilterPreferences: Codable, Equatable {
    var disabledBuiltIns: Set<String> = []
    var customPatterns: [String] = []

    func expressions() -> [NSRegularExpression] {
        let builtIns = BuiltInLyricFilter.allCases.filter { !disabledBuiltIns.contains($0.rawValue) }
        return (builtIns.map(\.pattern) + customPatterns).compactMap { try? NSRegularExpression(pattern: $0) }
    }
}

enum LyricFilter {
    // Run on the generic executor so a custom expression never blocks rendering.
    static func apply(_ expressions: [NSRegularExpression], to cues: [LyricCue]) async -> [LyricCue] {
        var timedOut = IndexSet()
        func matches(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let range = NSRange(text.startIndex..., in: text)
            for (i, expression) in expressions.enumerated() where !timedOut.contains(i) {
                var found = false
                let deadline = ContinuousClock.now + .milliseconds(30)
                expression.enumerateMatches(in: text, options: .reportProgress, range: range) { match, flags, stop in
                    if match != nil {
                        found = true
                        stop.pointee = true
                    } else if flags.contains(.progress), Task.isCancelled || ContinuousClock.now >= deadline {
                        timedOut.insert(i)
                        stop.pointee = true
                    }
                }
                if found { return true }
            }
            return false
        }

        var kept = [LyricCue]()
        for var cue in cues {
            if Task.isCancelled { return [] }
            if matches(cue.text) { continue }
            if matches(cue.translation) { cue.translation = "" }
            kept.append(cue)
        }
        return kept
    }
}

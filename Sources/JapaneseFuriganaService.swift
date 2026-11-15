import Foundation

struct FuriganaSpan: Equatable, Sendable {
    let range: Range<Int>
    let reading: String
}

// Owned by LyricLibrary and called on its actor.
final class JapaneseFuriganaService {
    func supplement(_ lines: [LyricCue]) -> [LyricCue] {
        let spans = annotations(for: lines.map(\.text))
        return zip(lines, spans).map { line, generated in
            var updated = line
            for span in generated {
                let start = line.text.index(line.text.startIndex, offsetBy: span.range.lowerBound)
                let end = line.text.index(start, offsetBy: span.range.count)
                let range = NSRange(start..<end, in: line.text)
                guard !line.readings.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                updated.readings.append(.init(range: range, kana: span.reading))
            }
            return updated
        }
    }

    private var bridge: AMLLMeCabBridge?
    private var didAttemptBridgeInitialization = false

    func annotations(for lines: [String]) -> [[FuriganaSpan]] {
        guard Self.isJapaneseSong(lines) else {
            return Array(repeating: [], count: lines.count)
        }
        guard let bridge = makeBridgeIfNeeded() else {
            return Array(repeating: [], count: lines.count)
        }

        return lines.map { line in
            guard Self.containsHan(line) else { return [] }
            do {
                let tokens = try bridge.tokens(forText: line)
                return tokens.flatMap { token -> [FuriganaSpan] in
                    guard let tokenRange = Self.characterRange(
                        in: line,
                        utf8Location: Int(token.utf8Location),
                        utf8Length: Int(token.utf8Length)
                    ) else { return [] }
                    return Self.align(
                        surface: token.surface,
                        reading: token.reading
                    ).map { span in
                        FuriganaSpan(
                            range: (
                                tokenRange.lowerBound + span.range.lowerBound
                            )..<(
                                tokenRange.lowerBound + span.range.upperBound
                            ),
                            reading: span.reading
                        )
                    }
                }
            } catch {
                NSLog("[SirinIsland] MeCab parse failed: %@", error.localizedDescription)
                return []
            }
        }
    }

    static func isJapaneseSong(_ lines: [String]) -> Bool {
        lines.contains(where: containsKana)
    }

    static func align(surface: String, reading: String) -> [FuriganaSpan] {
        guard containsHan(surface) else { return [] }
        let normalizedReading = normalizedKana(reading)
        guard !normalizedReading.isEmpty else { return [] }

        struct Group {
            let range: Range<Int>
            let text: String
            let isHan: Bool
        }

        var groups: [Group] = []
        var currentText = ""
        var currentIsHan: Bool?
        var currentStart = 0
        for (offset, character) in surface.enumerated() {
            let isHan = containsHan(String(character))
            if let previous = currentIsHan, previous != isHan {
                groups.append(
                    Group(
                        range: currentStart..<offset,
                        text: currentText,
                        isHan: previous
                    )
                )
                currentText = ""
                currentStart = offset
            }
            currentIsHan = isHan
            currentText.append(character)
        }
        if let currentIsHan {
            groups.append(
                Group(
                    range: currentStart..<surface.count,
                    text: currentText,
                    isHan: currentIsHan
                )
            )
        }

        var result: [FuriganaSpan] = []
        var readingCursor = normalizedReading.startIndex
        for (index, group) in groups.enumerated() {
            if !group.isHan {
                let anchor = kanaOnly(normalizedKana(group.text))
                guard !anchor.isEmpty else { continue }
                if normalizedReading[readingCursor...].hasPrefix(anchor) {
                    readingCursor = normalizedReading.index(
                        readingCursor,
                        offsetBy: anchor.count
                    )
                } else if let match = normalizedReading.range(
                    of: anchor,
                    range: readingCursor..<normalizedReading.endIndex
                ) {
                    readingCursor = match.upperBound
                }
                continue
            }

            let nextAnchor = groups[(index + 1)...]
                .lazy
                .filter { !$0.isHan }
                .map { kanaOnly(normalizedKana($0.text)) }
                .first { !$0.isEmpty }

            let readingEnd: String.Index
            if let nextAnchor {
                var searchStart = readingCursor
                if searchStart < normalizedReading.endIndex {
                    searchStart = normalizedReading.index(after: searchStart)
                }
                readingEnd = normalizedReading.range(
                    of: nextAnchor,
                    range: searchStart..<normalizedReading.endIndex
                )?.lowerBound ?? normalizedReading.endIndex
            } else {
                readingEnd = normalizedReading.endIndex
            }

            guard readingEnd > readingCursor else { continue }
            let alignedReading = String(normalizedReading[readingCursor..<readingEnd])
            if !alignedReading.isEmpty,
               normalizedKana(group.text) != alignedReading {
                result.append(FuriganaSpan(range: group.range, reading: alignedReading))
            }
            readingCursor = readingEnd
        }
        return result
    }

    private func makeBridgeIfNeeded() -> AMLLMeCabBridge? {
        if didAttemptBridgeInitialization { return bridge }
        didAttemptBridgeInitialization = true
        guard let dictionaryURL = Bundle.main.resourceURL?
            .appendingPathComponent("MeCab/ipadic", isDirectory: true)
        else {
            NSLog("[SirinIsland] MeCab dictionary resource URL is unavailable")
            return nil
        }
        do {
            bridge = try AMLLMeCabBridge(dictionaryPath: dictionaryURL.path)
        } catch {
            NSLog(
                "[SirinIsland] MeCab initialization failed at %@: %@",
                dictionaryURL.path,
                error.localizedDescription
            )
        }
        return bridge
    }

    private static func characterRange(
        in text: String,
        utf8Location: Int,
        utf8Length: Int
    ) -> Range<Int>? {
        guard utf8Location >= 0,
              utf8Length >= 0,
              utf8Location + utf8Length <= text.utf8.count
        else { return nil }
        let utf8 = text.utf8
        let byteStart = utf8.index(utf8.startIndex, offsetBy: utf8Location)
        let byteEnd = utf8.index(byteStart, offsetBy: utf8Length)
        guard let start = String.Index(byteStart, within: text),
              let end = String.Index(byteEnd, within: text)
        else { return nil }
        return (
            text.distance(from: text.startIndex, to: start)
        )..<(
            text.distance(from: text.startIndex, to: end)
        )
    }

    private static func normalizedKana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    private static func kanaOnly(_ value: String) -> String {
        String(value.unicodeScalars.filter(isKana))
    }

    private static func containsKana(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isKana)
    }

    private static func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3005, 0x3006, 0x303B,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,
             0xFF65...0xFF9F:
            return true
        default:
            return false
        }
    }
}

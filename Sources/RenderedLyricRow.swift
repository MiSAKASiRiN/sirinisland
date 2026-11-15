import Foundation

struct RenderedLyricWord {
    var text: String
    let startTime, endTime: Int
    var reading: String?
    var webValue: [String: Any] {
        var value: [String: Any] = ["word": text, "startTime": startTime, "endTime": endTime]
        if let reading { value["ruby"] = [["word": reading, "startTime": startTime, "endTime": endTime]] }
        return value
    }
}

struct RenderedLyricRow {
    let words: [RenderedLyricWord]
    let startTime, endTime: Int
    let translatedLyric: String
    let timed: Bool
    var webValue: [String: Any] {
        [
            "words": words.map(\.webValue), "startTime": startTime, "endTime": endTime,
            "translatedLyric": translatedLyric,
        ]
    }
}

extension LyricCue {
    // AMLL takes UTF-16 text slices paired with absolute millisecond timestamps.
    var renderRow: RenderedLyricRow {
        let content = text as NSString
        var previousIndex = 0
        var previousTime = start
        var words = [RenderedLyricWord]()
        func append(until index: Int, at time: Double) {
            let i = min(content.length, max(previousIndex, index))
            let t = min(end, max(previousTime, time))
            if i > previousIndex {
                words.append(
                    .init(
                        text: content.substring(with: NSRange(location: previousIndex, length: i - previousIndex)),
                        startTime: Int((previousTime * 1000).rounded()), endTime: Int((t * 1000).rounded())))
            }
            previousIndex = i
            previousTime = t
        }
        for mark in marks { append(until: mark.index, at: mark.time) }
        append(until: content.length, at: end)
        if !readings.isEmpty {
            // Preserve timing outside the base characters of each Japanese reading.
            let original = words
            words.removeAll(keepingCapacity: true)
            var offset = 0
            var intervals: [(range: NSRange, start: Int, end: Int)] = []
            for word in original {
                let range = NSRange(location: offset, length: word.text.utf16.count)
                intervals.append((range, word.startTime, word.endTime))
                offset = NSMaxRange(range)
            }
            func add(_ range: NSRange, reading: String? = nil) {
                guard range.length > 0,
                    let first = intervals.first(where: { NSLocationInRange(range.location, $0.range) }),
                    let last = intervals.first(where: { NSLocationInRange(NSMaxRange(range) - 1, $0.range) })
                else { return }
                func time(_ index: Int, _ interval: (range: NSRange, start: Int, end: Int)) -> Int {
                    interval.start + (interval.end - interval.start) * (index - interval.range.location)
                        / interval.range.length
                }
                let from = time(range.location, first)
                let to = time(NSMaxRange(range), last)
                words.append(
                    .init(text: content.substring(with: range), startTime: from, endTime: to, reading: reading))
            }
            func addPlain(_ range: NSRange) {
                for interval in intervals { add(NSIntersectionRange(range, interval.range)) }
            }
            var cursor = 0
            for reading in readings.sorted(by: { $0.range.location < $1.range.location }) {
                guard reading.range.location >= cursor, NSMaxRange(reading.range) <= content.length else { continue }
                addPlain(NSRange(location: cursor, length: reading.range.location - cursor))
                add(reading.range, reading: reading.kana)
                cursor = NSMaxRange(reading.range)
            }
            addPlain(NSRange(location: cursor, length: content.length - cursor))
        }
        // Normalize embedded newlines after resolving the source UTF-16 ranges.
        for i in words.indices {
            words[i].text = words[i].text.components(separatedBy: .newlines).joined(separator: " ")
        }
        return RenderedLyricRow(
            words: words, startTime: Int((start * 1000).rounded()),
            endTime: Int((end * 1000).rounded()),
            translatedLyric: translation.trimmingCharacters(in: .whitespacesAndNewlines),
            timed: !marks.isEmpty)
    }
}

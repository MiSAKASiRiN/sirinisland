import Foundation

extension TimedLyrics {
    static func ttml(_ data: Data) -> [LyricCue] {
        guard data.count <= 2_000_000,
              let doc = try? XMLDocument(data:data,options:[.nodeLoadExternalEntitiesNever,.nodePreserveWhitespace]),
              let rows = try? doc.nodes(forXPath:"//*[local-name()='body']//*[local-name()='p']") else { return [] }
        func seconds(_ value: String?) -> Double? {
            guard var s = value else { return nil }
            if s.hasSuffix("ms") { return Double(s.dropLast(2)).map { $0/1000 } }
            if s.hasSuffix("s") { s.removeLast() }
            var result = 0.0
            for part in s.split(separator:":") {
                guard let n = Double(part), n.isFinite, n >= 0 else { return nil }
                result = result*60+n
            }
            return result
        }
        return rows.compactMap { row in
            guard let p = row as? XMLElement,
                  let start = seconds(p.attribute(forName:"begin")?.stringValue),
                  let end = seconds(p.attribute(forName:"end")?.stringValue), end > start else { return nil }
            var text = "", marks = [LyricCue.Mark]()
            var readings = [LyricCue.Reading](), translation = ""
            func append(_ node: XMLNode) {
                if node.kind == .text {
                    let s = node.stringValue ?? ""
                    if !s.contains("\n") || !s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { text += s }
                    return
                }
                guard let e = node as? XMLElement else { return }
                let role = e.attributes?.first { $0.localName == "role" }?.stringValue ?? ""
                if role == "x-translation" {
                    let value = e.stringValue ?? ""
                    if isChineseTranslation(value, language:e.attribute(forName:"xml:lang")?.stringValue) { translation = value }
                    return
                }
                if e.localName == "br" { text += " "; return }
                let ruby = e.attributes?.first { $0.localName == "ruby" }?.stringValue
                if ruby == "container" || e.localName == "ruby" {
                    let lo = text.utf16.count
                    var kana = ""
                    for case let child as XMLElement in e.children ?? [] {
                        let kind = child.attributes?.first { $0.localName == "ruby" }?.stringValue ?? child.localName
                        if kind == "base" || kind == "rb" { append(child) }
                        if ["text","textContainer","rt"].contains(kind ?? "") {
                            kana += (child.stringValue ?? "").components(separatedBy:.whitespacesAndNewlines).joined()
                        }
                    }
                    if text.utf16.count > lo, !kana.isEmpty {
                        readings.append(.init(range:NSRange(location:lo,length:text.utf16.count-lo),kana:kana))
                    }
                    return
                }
                guard !["x-bg","x-translation","x-roman","x-romanization"].contains(role) else { return }
                let lo = text.utf16.count
                for child in e.children ?? [] { append(child) }
                if text.utf16.count > lo, let begin = seconds(e.attribute(forName:"begin")?.stringValue),
                   let stop = seconds(e.attribute(forName:"end")?.stringValue) {
                    marks.append(.init(time:begin,index:lo))
                    marks.append(.init(time:stop,index:text.utf16.count))
                }
            }
            for child in p.children ?? [] { append(child) }
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
            marks.sort { $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time }
            return LyricCue(start:start,end:end,text:text,marks:marks,readings:readings,translation:translation)
        }.sorted { $0.start < $1.start }
    }
}

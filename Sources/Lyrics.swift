import Foundation
import SwiftUI

struct LyricCue: Equatable {
    let start: Double
    let end: Double
    let text: String
    // Word marks use UTF-16 positions in the original lyric.
    let marks: [Mark]
    struct Reading: Equatable {
        let range: NSRange
        let kana: String
    }
    var readings: [Reading] = []
    var translation = ""
    struct Mark: Equatable { let time: Double; let index: Int }

}

enum TimedLyrics {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.,]\d+)?)\]"#)
    private static let tag = try! NSRegularExpression(pattern: #"<(\d+)(?:,(\d+))?>"#)
    private static let yLine = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let yWord = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^\(]*)"#)

    private static let readingTag = try! NSRegularExpression(pattern: #"<([^,<>]+),(\d+),(\d+)>"#)

    static func isChineseTranslation(_ text: String, language: String? = nil) -> Bool {
        if let language, !language.isEmpty { return language.lowercased().hasPrefix("zh") }
        return text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
            && text.range(of: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) == nil
    }

    static func lrc(_ content: String, duration: Double) -> [LyricCue] {
        var texts = [Int:String](), timing = [Int:String](), offset = 0
        var translations = [Int:String](), readings = [Int:String]()
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in:.whitespaces)
            if line.lowercased().hasPrefix("[offset:"), line.hasSuffix("]") { offset = Int(line.dropFirst(8).dropLast()) ?? 0 }
            let ns = line as NSString
            let matches = stamp.matches(in:line,range:NSRange(location:0,length:ns.length))
            guard matches.first?.range.location == 0, let last = matches.last else { continue }
            let suffix = ns.substring(from:NSMaxRange(last.range))
            for m in matches {
                let minute = Int(ns.substring(with:m.range(at:1))) ?? 0
                let seconds = Double(ns.substring(with:m.range(at:2)).replacingOccurrences(of:",",with:".")) ?? 0
                let ms = minute*60000 + Int((seconds*1000).rounded())
                if suffix.hasPrefix("[tt]") { timing[ms] = suffix }
                else if suffix.hasPrefix("[tr]") {
                    let value = String(suffix.dropFirst(4))
                    if isChineseTranslation(value) { translations[ms] = value }
                }
                else if suffix.hasPrefix("[fu]") { readings[ms] = suffix }
                else if !suffix.hasPrefix("[ro]") && texts[ms] == nil { texts[ms] = suffix }
            }
        }
        let keys = texts.keys.sorted()
        return keys.enumerated().compactMap { i, ms in
            guard let text = texts[ms], !text.trimmingCharacters(in:.whitespaces).isEmpty else { return nil }
            let start = Double(ms-offset)/1000
            var end = i+1 < keys.count ? Double(keys[i+1]-offset)/1000 : (duration > start ? duration : start+6)
            var marks = [LyricCue.Mark]()
            var indices = [0]
            for ch in text { indices.append(indices.last! + String(ch).utf16.count) }
            if let tags = timing[ms] {
                let ns = tags as NSString
                for m in tag.matches(in:tags,range:NSRange(location:0,length:ns.length)) {
                    let time = start + (Double(ns.substring(with:m.range(at:1))) ?? 0)/1000
                    let range = m.range(at:2)
                    if range.location == NSNotFound { end = min(end,time); continue }
                    if let n = Int(ns.substring(with:range)), indices.indices.contains(n) {
                        marks.append(.init(time:time,index:indices[n]))
                    }
                }
            }
            var cue = LyricCue(start:start,end:max(start+0.02,end),text:text,marks:marks)
            cue.translation = translations[ms] ?? ""
            if let tags = readings[ms] {
                let ns = tags as NSString
                for m in readingTag.matches(in:tags,range:NSRange(location:0,length:ns.length)) {
                    guard let lo = Int(ns.substring(with:m.range(at:2))), let hi = Int(ns.substring(with:m.range(at:3))),
                          indices.indices.contains(lo), indices.indices.contains(hi), hi > lo else { continue }
                    cue.readings.append(.init(range:NSRange(location:indices[lo],length:indices[hi]-indices[lo]),kana:ns.substring(with:m.range(at:1))))
                }
            }
            return cue
        }
    }

    static func yrc(_ content: String) -> [LyricCue] {
        content.components(separatedBy:.newlines).compactMap { line in
            let ns = line as NSString, range = NSRange(location:0,length:(line as NSString).length)
            guard let head = yLine.firstMatch(in:line,range:range) else { return nil }
            let start = (Double(ns.substring(with:head.range(at:1))) ?? 0)/1000
            let end = start + (Double(ns.substring(with:head.range(at:2))) ?? 0)/1000
            var text = "", marks = [LyricCue.Mark]()
            for m in yWord.matches(in:line,range:range) {
                let time = (Double(ns.substring(with:m.range(at:1))) ?? 0)/1000
                let length = (Double(ns.substring(with:m.range(at:2))) ?? 0)/1000
                marks.append(.init(time:time,index:text.utf16.count))
                text += ns.substring(with:m.range(at:3))
                marks.append(.init(time:time+length,index:text.utf16.count))
            }
            guard !text.isEmpty, end > start else { return nil }
            return LyricCue(start:start,end:end,text:text,marks:marks)
        }.sorted { $0.start < $1.start }
    }
}

struct LyricTrack: Hashable {
    let title: String, artist: String, album: String
    let duration: Int
    init(_ song: IslandSong) {
        title = song.title; artist = song.artist; album = song.album
        duration = Int(max(0,song.duration).rounded())
    }
    static func norm(_ s: String) -> String {
        s.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            .components(separatedBy:.whitespacesAndNewlines).joined()
    }
    func matchesArtist(_ other: String) -> Bool {
        let separators = CharacterSet(charactersIn: ",，;/、&")
        let left = Set(artist.components(separatedBy:separators).map(Self.norm).filter { !$0.isEmpty })
        let right = Set(other.components(separatedBy:separators).map(Self.norm).filter { !$0.isEmpty })
        return !left.isDisjoint(with:right) || Self.norm(artist) == Self.norm(other)
    }
}

private actor LyricLibrary {
    private let furigana = JapaneseFuriganaService()
    struct FileEntry {
        let artist: String, album: String, duration: Double?, url: URL
    }
    var files = [String:[FileEntry]]()
    var indexed: Date?
    var memory = [LyricTrack:[LyricCue]]()

    private func local(_ track: LyricTrack) -> [LyricCue] {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("AMLL Now Playing/Lyrics",isDirectory:true)
        guard let modified = try? root.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate else { return [] }
        if indexed != modified {
            var next = [String:[FileEntry]]()
            let urls = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
            for url in urls where url.pathExtension == "lrcx" {
                if Task.isCancelled { return [] }
                guard let handle = try? FileHandle(forReadingFrom:url) else { continue }
                let bytes = try? handle.read(upToCount:3072)
                try? handle.close()
                guard let bytes else { continue }
                var metadata = [String:String]()
                for row in String(decoding:bytes,as:UTF8.self).split(whereSeparator: \.isNewline) {
                    guard row.first == "[", row.last == "]", let colon = row.firstIndex(of:":") else { continue }
                    metadata[String(row[row.index(after:row.startIndex)..<colon])] = String(row[row.index(after:colon)..<row.index(before:row.endIndex)])
                }
                if let name = metadata["ti"], let artist = metadata["ar"] {
                    next[LyricTrack.norm(name),default:[]].append(.init(artist:artist,album:metadata["al"] ?? "",duration:metadata["length"].flatMap(Double.init),url:url))
                }
            }
            files = next; indexed = modified
        }
        let candidates = (files[LyricTrack.norm(track.title)] ?? []).filter { e in
            track.matchesArtist(e.artist) && (track.duration == 0 || e.duration == nil || e.duration! <= 0 || abs(e.duration! - Double(track.duration)) < 5)
        }.sorted { a,b in
            func score(_ e: FileEntry) -> Double {
                (LyricTrack.norm(track.album) == LyricTrack.norm(e.album) ? 10 : 0) - abs((e.duration ?? Double(track.duration))-Double(track.duration))
            }
            return score(a) > score(b)
        }
        for e in candidates {
            if let content = try? String(contentsOf:e.url,encoding:.utf8) {
                let lines = TimedLyrics.lrc(content,duration:Double(track.duration))
                if !lines.isEmpty { return lines }
            }
        }
        return []
    }

    private func json(_ base: String, _ query: [String:String]) async throws -> [String:Any] {
        var c = URLComponents(string:base)!
        c.queryItems = query.map { URLQueryItem(name:$0.key,value:$0.value) }
        var r = URLRequest(url:c.url!)
        r.timeoutInterval = 6
        r.setValue("SirinIsland/1.4",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await URLSession.shared.data(for:r)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 2_000_000 else { return [:] }
        return try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
    }

    private func netease(_ t: LyricTrack, provisional: ([LyricCue]) async -> Void) async throws -> [LyricCue] {
        let search = try await json("https://music.163.com/api/search/get",["s":t.title+" "+t.artist,"type":"1","limit":"8"])
        let result = search["result"] as? [String:Any]
        let songs = result?["songs"] as? [[String:Any]] ?? []
        let match = songs.filter { s in
            let names = (s["artists"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator:",")
            let length = (s["duration"] as? Double ?? 0)/1000
            return LyricTrack.norm(s["name"] as? String ?? "") == LyricTrack.norm(t.title) && t.matchesArtist(names)
                && (t.duration == 0 || length == 0 || abs(length-Double(t.duration)) < 5)
        }.min { a,b in
            abs((a["duration"] as? Double ?? 0)/1000-Double(t.duration)) < abs((b["duration"] as? Double ?? 0)/1000-Double(t.duration))
        }
        guard let id = match?["id"] as? Int else { return [] }
        let data = try await json("https://music.163.com/api/song/lyric/v1",["id":String(id),"lv":"-1","yv":"-1","kv":"-1","tv":"-1","ytv":"-1"])
        func annotated(_ lines: [LyricCue], keys: [String]) -> [LyricCue] {
            var translations = [Int:String]()
            for key in keys {
                guard let lrc = (data[key] as? [String:Any])?["lyric"] as? String else { continue }
                for cue in TimedLyrics.lrc(lrc,duration:Double(t.duration)) where TimedLyrics.isChineseTranslation(cue.text) {
                    let time = Int((cue.start*1000).rounded())
                    if translations[time] == nil { translations[time] = cue.text }
                }
            }
            return lines.map { line in
                var cue = line
                if cue.translation.isEmpty { cue.translation = translations[Int((cue.start*1000).rounded())] ?? "" }
                return cue
            }
        }
        if let yrc = (data["yrc"] as? [String:Any])?["lyric"] as? String {
            let lines = TimedLyrics.yrc(yrc)
            if !lines.isEmpty { return annotated(lines,keys:["ytlrc","tlyric"]) }
        }
        let plain = annotated(TimedLyrics.lrc((data["lrc"] as? [String:Any])?["lyric"] as? String ?? "",duration:Double(t.duration)),keys:["tlyric"])
        if !plain.isEmpty { await provisional(plain) }
        let url = URL(string:"https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/ncm-lyrics/\(id).ttml")!
        if !Task.isCancelled, let (bytes,response) = try? await URLSession.shared.data(for:URLRequest(url:url,timeoutInterval:6)),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            let timed = TimedLyrics.ttml(bytes)
            if !timed.isEmpty { return annotated(timed,keys:["tlyric"]) }
        }
        return plain
    }

    func load(_ track: LyricTrack, provisional: @escaping @Sendable ([LyricCue]) async -> Void) async -> [LyricCue] {
        if let hit = memory[track] { return hit }
        var lines = local(track)
        if !lines.isEmpty { await provisional(furigana.supplement(lines)) }
        if !lines.contains(where: { !$0.marks.isEmpty }), !Task.isCancelled {
            let hasLocal = !lines.isEmpty
            let fetched = try? await netease(track) { draft in
                if !hasLocal { await provisional(furigana.supplement(draft)) }
            }
            if let fetched, !fetched.isEmpty, (!hasLocal || fetched.contains(where: { !$0.marks.isEmpty })) {
                let localAnnotations = Dictionary(grouping:lines.filter { !$0.readings.isEmpty || !$0.translation.isEmpty },by: \.text)
                lines = fetched.map { line in
                    guard let local = localAnnotations[line.text]?.min(by: { abs($0.start-line.start) < abs($1.start-line.start) }),
                          abs(local.start-line.start) <= 1 else { return line }
                    var merged = line
                    if !local.translation.isEmpty { merged.translation = local.translation }
                    if !local.readings.isEmpty { merged.readings = local.readings }
                    return merged
                }
            }
        }
        if lines.isEmpty, !Task.isCancelled {
            var q = ["track_name":track.title,"artist_name":track.artist]
            if !track.album.isEmpty { q["album_name"] = track.album }
            if track.duration > 0 { q["duration"] = String(track.duration) }
            if let data = try? await json("https://lrclib.net/api/get",q), let text = data["syncedLyrics"] as? String {
                lines = TimedLyrics.lrc(text,duration:Double(track.duration))
            }
        }
        if !lines.isEmpty && !Task.isCancelled {
            lines = furigana.supplement(lines)
            if memory.count >= 100 { memory.removeAll(keepingCapacity:true) }
            memory[track] = lines
        }
        return lines
    }
}

final class IslandLyrics: ObservableObject {
    static let loadingMessage = "正在获取歌词…"
    private(set) var revision = 0
    @Published private(set) var footerHeight: CGFloat = 26
    @Published private(set) var lines = [LyricCue]()
    private func showLines(_ next: [LyricCue]) {
        guard next != lines else { return }
        revision += 1
        lines = next
    }
    private func showResult(_ next: [LyricCue]) {
        showLines(next)
        let height: CGFloat = 26 + (next.contains { !$0.readings.isEmpty } ? 8 : 0)
            + (next.contains { !$0.translation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ? 19 : 0)
        if height != footerHeight { footerHeight = height }
        let message = next.isEmpty ? "暂无同步歌词" : ""
        if status != message { status = message }
    }
    @Published private(set) var status = "暂无播放"
    private let library = LyricLibrary()
    private var songID: UUID?
    private var track: LyricTrack?
    private var request: Task<Void,Never>?

    func select(_ song: IslandSong?) {
        let key = song.map(LyricTrack.init)
        guard key != track || song?.trackID != songID else { return }
        let changedSong = song?.trackID != songID
        songID = song?.trackID
        request?.cancel()
        track = key
        if changedSong { showLines([]) }
        guard let key else {
            footerHeight = 26
            status = "暂无播放"
            return
        }
        if lines.isEmpty { status = Self.loadingMessage }
        request = Task { @MainActor [weak self, library] in
            let found = await library.load(key) { [weak self] draft in
                await MainActor.run { [weak self] in
                    guard let self, self.track == key, !Task.isCancelled else { return }
                    self.showResult(draft)
                }
            }
            guard !Task.isCancelled, let self, self.track == key else { return }
            self.showResult(found)
        }
    }
    func cue(at position: Double) -> LyricCue? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo+hi)/2
            if lines[mid].start <= position { lo = mid+1 } else { hi = mid }
        }
        guard lo > 0, position < lines[lo-1].end else { return nil }
        return lines[lo-1]
    }
}

import CoreImage
import CoreText
import SwiftUI

private final class Ink {
    let image: CGImage?
    let text: NSAttributedString
    let advance: Double
    let size: CGSize

    init(image: CGImage?, text: NSAttributedString, advance: Double, size: CGSize) {
        self.image = image
        self.text = text
        self.advance = advance
        self.size = size
    }
}

private final class GlyphCache {
    let scale: CGFloat
    private let cache = NSCache<NSString, Ink>()

    init(scale: CGFloat) {
        self.scale = scale
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func ink(_ string: String, size: CGFloat) -> Ink {
        let key = "\(size):\(string)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let font = NSFont.systemFont(ofSize: size, weight: size == 14 ? .bold : .semibold)
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(text)
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = max(1, Int(ceil((advance + 4) * scale)))
        let height = Int(ceil((font.ascender - font.descender + 4) * scale))
        var image: CGImage?
        if width <= 16384,
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: 2, y: 2 - font.descender)
            CTLineDraw(line, ctx)
            image = ctx.makeImage()
        }
        let result = Ink(
            image: image, text: text, advance: advance,
            size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        cache.setObject(result, forKey: key, cost: image.map { $0.bytesPerRow * $0.height } ?? text.length * 2)
        return result
    }

    func layer(_ ink: Ink, x: Double, y: Double) -> CALayer {
        let result: CALayer
        if let image = ink.image {
            result = CALayer()
            result.contents = image
        } else {
            let text = CATextLayer()
            text.string = ink.text
            text.isWrapped = false
            result = text
        }
        result.contentsScale = scale
        result.frame = CGRect(origin: CGPoint(x: x - 2, y: y - 2), size: ink.size)
        return result
    }
}

struct NativeLyricViewport: NSViewRepresentable {
    let song: IslandSong
    let lyrics: IslandLyrics
    let visible: Bool
    let reducedMotion: Bool

    func makeNSView(context: Context) -> NativeLyricView { NativeLyricView(frame: .zero) }
    func updateNSView(_ view: NativeLyricView, context: Context) {
        view.sync(
            song: song, lines: lyrics.lines, revision: lyrics.revision, visible: visible,
            loading: lyrics.status == IslandLyrics.loadingMessage, reduced: reducedMotion)
    }
    static func dismantleNSView(_ view: NativeLyricView, coordinator: ()) { view.stop() }
}

final class NativeLyricView: NSView {
    private struct Segment {
        let start, end: Double
        let cue: LyricCue?  // nil is a real interlude of at least four seconds.
    }
    private let scene = CALayer()
    private var segments = [Segment]()
    private var staged = [Int: CALayer]()
    private var rowPitch = 28.0
    private var timer: Timer?
    private var glyphs = GlyphCache(scale: NSScreen.main?.backingScaleFactor ?? 2)
    private var trackID: UUID?
    private var revision: Int?
    private var size = CGSize.zero
    private var visible = false
    private var reduced = false
    private var running = false
    private var holdingOutgoing = false
    private var latestSong: IslandSong?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(scene)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        guard visible, size != bounds.size, let song = latestSong else { return }
        let position = holdingOutgoing ? scene.timeOffset : song.position(at: Date())
        rebuild(at: position, running: !holdingOutgoing && song.playing)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        guard scale != glyphs.scale else { return }
        glyphs = GlyphCache(scale: scale)
        size = .zero
        needsLayout = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        staged.values.forEach { $0.removeFromSuperlayer() }
        staged.removeAll()
        scene.removeAllAnimations()
        running = false
    }

    private func index(at time: Double) -> Int {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    func sync(song: IslandSong, lines: [LyricCue], revision: Int, visible: Bool, loading: Bool, reduced: Bool) {
        let previousSong = latestSong
        latestSong = song
        let wasVisible = self.visible
        self.visible = visible
        guard visible else {
            if wasVisible { stop() }
            return
        }
        if lines.isEmpty, loading, !staged.isEmpty {
            // Keep the outgoing line in place until the new track has a measured replacement.
            holdingOutgoing = true
            if running {
                let time = scene.convertTime(CACurrentMediaTime(), from: nil)
                scene.speed = 0
                scene.timeOffset = time
                running = false
            }
            timer?.invalidate()
            return
        }
        holdingOutgoing = false
        let time = song.position(at: Date())
        let displayedTime = scene.convertTime(CACurrentMediaTime(), from: nil)
        let changedTrack = trackID != song.trackID
        let changedData = changedTrack || self.revision != revision
        let changedMotion = self.reduced != reduced
        self.reduced = reduced
        var fade = false
        if changedData {
            let previousIndex = index(at: displayedTime)
            let outgoing = segments.indices.contains(previousIndex) ? segments[previousIndex].cue : nil
            segments.removeAll(keepingCapacity: true)
            // AMLL reserves the same row pitch for missing annotations within a track.
            rowPitch =
                28 + (lines.contains { !$0.readings.isEmpty } ? 7 : 0)
                + (lines.contains { !$0.translation.isEmpty } ? 15 : 0)
            var end = 0.0
            for cue in lines {
                if cue.start - end >= 4 {
                    segments.append(Segment(start: end, end: cue.start, cue: nil))
                }
                segments.append(Segment(start: cue.start, end: cue.end, cue: cue))
                end = max(end, cue.end)
            }
            let nextIndex = index(at: time)
            let incoming = segments.indices.contains(nextIndex) ? segments[nextIndex].cue : nil
            fade =
                changedTrack && wasVisible && !staged.isEmpty && !segments.isEmpty
                && (outgoing?.text != incoming?.text || outgoing?.translation != incoming?.translation
                    || outgoing?.readings != incoming?.readings)
            if changedTrack { glyphs = GlyphCache(scale: glyphs.scale) }
            trackID = song.trackID
            self.revision = revision
        }
        guard
            changedData || !wasVisible || changedMotion || size != bounds.size || running != song.playing
                || (previousSong?.anchor != song.anchor || previousSong?.elapsed != song.elapsed)
                    && abs(time - displayedTime) > 0.08
        else { return }
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = reduced ? 0.12 : IslandMotion.lyricDuration
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.333, 0.06, 0.667, 1)
            layer?.add(transition, forKey: "track")
        }
        rebuild(at: time, running: song.playing)
    }

    private func rebuild(at time: Double, running: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stop()
        size = bounds.size
        scene.frame = bounds
        guard bounds.width >= 24, bounds.height > 0, !segments.isEmpty else {
            setAccessibilityLabel(nil)
            return
        }
        self.running = running
        scene.speed = running ? 1 : 0
        scene.timeOffset = running ? 0 : time
        scene.beginTime = running ? CACurrentMediaTime() - time : 0
        stage(at: time)
    }

    private func stage(at time: Double) {
        let current = index(at: time)
        let neighbors = running ? [current - 1, current, current + 1] : [current]
        let needed = Set(neighbors.filter { segments.indices.contains($0) })
        for i in Array(staged.keys) where !needed.contains(i) {
            staged.removeValue(forKey: i)?.removeFromSuperlayer()
        }
        for i in needed.sorted() where staged[i] == nil {
            let segment = segments[i]
            let node: CALayer
            if let cue = segment.cue {
                node = makeRow(cue.renderRow)
                let next = segments.indices.contains(i + 1) ? segments[i + 1] : nil
                let departure = next?.start ?? segment.end
                if !running && i == current && time < departure {
                    // A paused seek lands on a single sharp, centered lyric.
                    node.opacity = 1
                } else {
                    applyHandoff(
                        to: node, start: segment.start, sungEnd: segment.end, departure: departure,
                        pitch: rowPitch, previousStart: i > 0 ? segments[i - 1].start : nil,
                        reduced: reduced)
                }
            } else {
                node = dots(start: segment.start, duration: segment.end - segment.start)
            }
            scene.addSublayer(node)
            staged[i] = node
        }
        let currentCue = segments.indices.contains(current) ? segments[current].cue : nil
        setAccessibilityLabel(
            currentCue.map { [$0.text, $0.translation].filter { !$0.isEmpty }.joined(separator: " ") })
        guard running, segments.indices.contains(current + 1) else { return }
        let delay = max(0.001, segments[current + 1].start - time)
        let task = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.stage(at: self.scene.convertTime(CACurrentMediaTime(), from: nil))
            CATransaction.commit()
        }
        RunLoop.main.add(task, forMode: .common)
        timer = task
    }
    private func dots(start: Double, duration: Double) -> CALayer {
        let group = CALayer()
        group.frame = CGRect(x: 11, y: (bounds.height - 9) / 2, width: 43, height: 9)
        let steps = min(1800, max(2, Int(duration * 30)))
        frames(group, "transform.scale", start: start, duration: duration, samples: steps) { t in
            let s = t * duration
            let breath = duration / ceil(duration / 1.5)
            let intro = s >= 2 ? 1 : 1 - pow(2, -10 * s / 2)
            let u = clamp((0.75 - duration + s) / 0.75)
            let back = u * u * ((2.5949095 + 1) * u - 2.5949095) / 2
            if self.reduced { return 0.7 }
            return 0.7 * (1 + sin(1.5 * .pi - s / breath * 2) / 20) * intro * (1 - back)
        }
        for i in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: Double(i) * 16, y: 0, width: 9.1, height: 9.1)
            dot.cornerRadius = 4.55
            dot.backgroundColor = NSColor.white.cgColor
            group.addSublayer(dot)
            frames(dot, "opacity", start: start, duration: duration, samples: steps) { t in
                let s = t * duration
                let fill = max(0.05, duration - 0.75)
                return clamp((s - 0.5) / 0.5) * clamp((duration - s) / 0.375)
                    * max(0.25, clamp((s / fill * 3 - Double(i)) * 0.75))
            }
        }
        return group
    }
    private func makeRow(_ row: RenderedLyricRow) -> CALayer {
        let root = CALayer()
        root.frame = bounds
        let start = Double(row.startTime) / 1000
        let emphasisSpans = sustainedSpans(in: row)
        var widths = [0.0]
        let metrics = row.words.map { w -> (Ink, Ink?, Double) in
            let base = glyphs.ink(w.text, size: 14)
            let ruby = w.reading.map { glyphs.ink($0, size: 7) }
            let advance = max(base.advance, ruby?.advance ?? 0)
            widths.append(widths.last! + advance)
            return (base, ruby, advance)
        }
        let lane = motionLane(
            width: widths.last!, height: bounds.height, viewport: bounds.width, row: row,
            widths: row.timed ? widths : nil, start: start)
        root.addSublayer(lane.clip)
        let hasRuby = row.words.contains { $0.reading != nil }
        let hasSub = !row.translatedLyric.isEmpty
        let y = (bounds.height - 17) / 2 + (hasSub ? 7.5 : 0) - (hasRuby ? 3.5 : 0)
        for (i, w) in row.words.enumerated() {
            let (base, ruby, advance) = metrics[i]
            let token = CALayer()
            token.frame = CGRect(x: widths[i], y: 0, width: advance, height: bounds.height)
            lane.content.addSublayer(token)
            let t = Double(w.startTime) / 1000
            let d = Double(w.endTime - w.startTime) / 1000
            if !row.timed {
                token.addSublayer(glyphs.layer(base, x: (advance - base.advance) / 2, y: y))
                if let ruby { token.addSublayer(glyphs.layer(ruby, x: (advance - ruby.advance) / 2, y: y + 17)) }
                continue
            }
            if !reduced {
                frames(token, "transform.translation.y", start: t, duration: max(1, d), samples: 24) {
                    0.7 * (1 - pow(1 - $0, 2))
                }
            }
            let muted = CALayer()
            let bright = CALayer()
            for l in [muted, bright] {
                l.frame = token.bounds
                token.addSublayer(l)
                if let ruby { l.addSublayer(glyphs.layer(ruby, x: (advance - ruby.advance) / 2, y: y + 17)) }
                guard !reduced, let span = emphasisSpans[i] else {
                    l.addSublayer(glyphs.layer(base, x: (advance - base.advance) / 2, y: y))
                    continue
                }
                let d = span.duration
                var x = (advance - base.advance) / 2
                let amount = min(
                    1.2, (d > 2 ? sqrt(d / 2) : pow(d / 2, 3)) * 0.6 * (span.final ? 1.6 : 1))
                let glow = min(
                    0.8, (d > 3 ? sqrt(d / 3) : pow(d / 3, 3)) * 0.5 * (span.final ? 1.5 : 1))
                let du = d * (span.final ? 1.2 : 1)
                for (j, ch) in w.text.enumerated() {
                    let ink = glyphs.ink(String(ch), size: 14)
                    let char = glyphs.layer(ink, x: x, y: y)
                    l.addSublayer(char)
                    x += ink.advance
                    let onset = span.start + du / 2.5 * Double(span.offset + j) / Double(span.characters)
                    let wave: (Double) -> Double = emphasis
                    frames(char, "transform.scale", start: onset, duration: du, samples: 32) {
                        1 + 0.1 * amount * wave($0)
                    }
                    frames(char, "transform.translation.x", start: onset, duration: du, samples: 32) {
                        -0.42 * amount * (Double(w.text.count) / 2 - Double(j)) * wave($0)
                    }
                    frames(char, "transform.translation.y", start: onset - 0.4, duration: du * 1.4, samples: 32) {
                        0.7 * sin($0 * .pi)
                    }
                    if !ch.isWhitespace {
                        char.shadowColor = NSColor.white.cgColor
                        char.shadowOffset = .zero
                        char.shadowRadius = max(1, min(4.2, glow * 4.2))
                        frames(char, "shadowOpacity", start: onset, duration: du, samples: 32) {
                            max(0.14, glow) * wave($0)
                        }
                    }
                }
            }
            muted.opacity = 0.55
            let feather = 14.0
            let mask = CAGradientLayer()
            let width = 2 * advance + feather
            mask.frame = CGRect(x: -advance - feather, y: 0, width: width, height: bounds.height)
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: advance / width), NSNumber(value: (advance + feather) / width), 1]
            bright.mask = mask
            frames(mask, "transform.translation.x", start: t, duration: d, samples: 1) { (advance + feather) * $0 }
        }
        if hasSub {
            let translation = glyphs.ink(row.translatedLyric, size: 10)
            let sub = motionLane(
                width: translation.advance, height: bounds.height, viewport: bounds.width, row: row, widths: nil,
                start: start)
            root.addSublayer(sub.clip)
            let subtitle = glyphs.layer(translation, x: 0, y: (bounds.height - 35) / 2)
            subtitle.opacity = 0.78
            sub.content.addSublayer(subtitle)
        }
        return root
    }
}

private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

// AMLL uses separate cubic Beziers for the rise and release of sustained syllables.
private func emphasis(_ t: Double) -> Double {
    let rise = t < 0.5
    let x = rise ? t * 2 : (t - 0.5) * 2
    let x1 = rise ? 0.2 : 0.3
    let y1 = rise ? 0.4 : 0.0
    func cubic(_ u: Double, _ a: Double, _ b: Double) -> Double {
        3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
    }
    var low = 0.0
    var high = 1.0
    for _ in 0..<12 {
        let mid = (low + high) / 2
        if cubic(mid, x1, 0.58) < x { low = mid } else { high = mid }
    }
    let y = cubic((low + high) / 2, y1, 1)
    return rise ? y : 1 - y
}

// Matches the cubic acceleration and damped landing in SirinIsland horizontal-scroll.ts.
private func scrollCurve(_ t: Double, _ duration: Double) -> Double {
    if t <= 0 || t >= 1 { return clamp(t) }
    let residual = 7 * exp(-6.0)
    func landing(_ x: Double) -> Double { ((2 - (6 * x + 2) * exp(-6 * x)) / 6 - residual * x) / (1 - residual) }
    let edge = min(0.22, 480 / max(1, duration))
    let dist = 1 - 1.5 * edge + edge * landing(1)
    if t < edge {
        let u = t / edge
        return edge * u * u * u * (1 - 0.5 * u) / dist
    }
    if t <= 1 - edge { return (t - 0.5 * edge) / dist }
    return (1 - 1.5 * edge + edge * landing((t - 1 + edge) / edge)) / dist
}

private func frames(
    _ layer: CALayer, _ key: String, start: Double, duration: Double, samples: Int,
    _ value: (Double) -> Double
) {
    let animation = CAKeyframeAnimation(keyPath: key)
    animation.values = (0...samples).map { value(Double($0) / Double(samples)) }
    animation.beginTime = start == 0 ? 0.000001 : start
    animation.duration = max(0.001, duration)
    animation.fillMode = .both
    animation.isRemovedOnCompletion = false
    layer.add(animation, forKey: key)
}

private func motionLane(
    width: CGFloat, height: CGFloat, viewport: CGFloat, row: RenderedLyricRow, widths: [Double]?,
    start: Double
) -> (clip: CALayer, content: CALayer) {
    let clip = CALayer()
    clip.frame = CGRect(x: 0, y: 0, width: viewport, height: height)
    clip.masksToBounds = true
    let content = CALayer()
    content.frame = CGRect(x: 4, y: 0, width: width, height: height)
    clip.addSublayer(content)
    let room = viewport - 8
    let excess = width - room
    guard excess > 0 else { return (clip, content) }
    let ms = Double(row.endTime - row.startTime)
    let hold = min(300, ms * 0.1)
    func head(_ t: Double, _ widths: [Double]) -> Double {
        let absolute = t + Double(row.startTime)
        let i = row.words.firstIndex { Double($0.endTime) > absolute } ?? row.words.count - 1
        let word = row.words[i]
        let f = clamp((absolute - Double(word.startTime)) / Double(max(1, word.endTime - word.startTime)))
        return widths[i] + (widths[i + 1] - widths[i]) * f
    }
    func offset(_ t: Double) -> Double {
        let line = clamp((t - hold) / (ms - 2 * hold))
        guard let widths else { return (excess + 8) * scrollCurve(line, ms - 2 * hold) }
        let r = min(82, ms * 0.06)
        let x =
            (head(t - r, widths) + 2 * head(t - r / 2, widths) + 3 * head(t, widths) + 2 * head(t + r / 2, widths)
                + head(t + r, widths)) / 9
        let target = clamp(max((x - room * 0.6) / (excess + 8), (line - 0.8) / 0.2))
        return (excess + 8) * scrollCurve(target, ms)
    }
    let n = max(2, min(300, Int(ceil(ms / 25))))
    frames(content, "transform.translation.x", start: start, duration: ms / 1000, samples: n) { -offset($0 * ms) }
    let mask = CAGradientLayer()
    mask.frame = clip.bounds
    mask.startPoint = CGPoint(x: 0, y: 0.5)
    mask.endPoint = CGPoint(x: 1, y: 0.5)
    mask.locations = [0, NSNumber(value: 11 / viewport), NSNumber(value: 1 - 11 / viewport), 1]
    let black = NSColor.black.cgColor
    let clear = NSColor.clear.cgColor
    mask.colors = [black, black, black, clear]
    let colors = CAKeyframeAnimation(keyPath: "colors")
    colors.calculationMode = .discrete
    colors.values = (0...n).map { i -> [CGColor] in
        let x = offset(ms * Double(i) / Double(n))
        return [x > 1 ? clear : black, black, black, x < excess - 1 ? clear : black]
    }
    colors.beginTime = start == 0 ? 0.000001 : start
    colors.duration = ms / 1000
    colors.fillMode = .both
    colors.isRemovedOnCompletion = false
    mask.add(colors, forKey: "edges")
    clip.mask = mask
    return (clip, content)
}

// A karaoke source may timestamp the syllables of a single written word separately.
// Share only the emphasis envelope; each syllable keeps its own highlight mask.
private struct SustainedSpan {
    let start, duration: Double
    let offset, characters: Int
    let final: Bool
}

private func sustainedSpans(in row: RenderedLyricRow) -> [Int: SustainedSpan] {
    guard row.timed else { return [:] }
    let words = row.words
    func joins(_ a: RenderedLyricWord, _ b: RenderedLyricWord) -> Bool {
        guard a.reading == nil, b.reading == nil, let last = a.text.last, let first = b.text.first else { return false }
        return last.isLetter && first.isLetter
            && String([last, first]).range(of: #"^\p{Latin}{2}$"#, options: .regularExpression) != nil
    }
    var spans: [Int: SustainedSpan] = [:]
    var i = 0
    while i < words.count {
        var end = i + 1
        while end < words.count && joins(words[end - 1], words[end]) { end += 1 }
        let group = words[i..<end]
        let text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(words[end - 1].endTime - words[i].startTime) / 1000
        if duration >= 1 && !text.isEmpty && !text.contains(where: \.isWhitespace) {
            let count = max(1, words[i].reading?.count ?? group.reduce(0) { $0 + $1.text.count })
            var offset = 0
            for j in group.indices {
                spans[j] = SustainedSpan(
                    start: Double(words[i].startTime) / 1000, duration: duration,
                    offset: offset, characters: count, final: end == words.count)
                offset += words[j].text.count
            }
        }
        i = end
    }
    return spans
}

// The singing clock and the focus clock differ across a short rest. The word
// stops glowing at its musical time, but the row moves only when its successor arrives.
private func applyHandoff(
    to layer: CALayer, start: Double, sungEnd: Double, departure: Double,
    pitch: Double, previousStart: Double?, reduced: Bool
) {
    let hold = max(0, departure - start)
    let defocus = min(hold, max(0, sungEnd - start))
    let fadeDuration = reduced ? 0.14 : 0.4
    let total = hold + fadeDuration
    // Sample only transition edges, even for a lyric which remains focused for a minute.
    var moments: Set<Double> = [0, hold, total]
    for edge in [0.0, defocus, hold] {
        for i in 0...60 { moments.insert(min(total, edge + Double(i) / 60)) }
    }
    let times = moments.sorted()
    let keyTimes = times.map { NSNumber(value: $0 / total) }
    func track(_ key: String, _ id: String, _ sample: (Double) -> Double) {
        let anim = CAKeyframeAnimation(keyPath: key)
        anim.values = times.map(sample)
        anim.keyTimes = keyTimes
        anim.beginTime = start == 0 ? 0.000001 : start
        anim.duration = total
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: id)
    }
    func ease(_ time: Double) -> Double {
        let x = clamp(time / fadeDuration)
        if x == 0 || x == 1 { return x }
        // CSS 'ease', cubic-bezier(.25,.1,.25,1).
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<12 {
            let u = (lo + hi) / 2
            let v = 1 - u
            if 0.75 * v * u + u * u * u < x { lo = u } else { hi = u }
        }
        let u = (lo + hi) / 2
        let v = 1 - u
        return 0.3 * v * v * u + 3 * v * u * u + u * u * u
    }
    track("opacity", "rowFade") { ease($0) * (1 - ease($0 - hold)) }
    guard !reduced else { return }

    // Position uses AMLL's critically damped branch, with a 50 ms stagger on entry.
    func position(_ t: Double, interval: Double) -> Double {
        let ratio = pow(1 - clamp((interval - 0.1) / 0.7), 0.2)
        let u = sqrt((170 + 50 * ratio) / 0.9) * max(0, t)
        return 1 - (1 + u) * exp(-u)
    }
    func scale(_ t: Double) -> Double {
        let t = max(0, t)
        let decay = 6.25
        let frequency = sqrt(50 - decay * decay)
        return 1 - exp(-decay * t) * (cos(frequency * t) + decay / frequency * sin(frequency * t))
    }
    layer.anchorPoint = CGPoint(x: 0, y: 0.5)
    layer.position.x = 0
    let center = layer.position.y
    track("position.y", "rowTravel") {
        center + pitch
            * (position($0 - (previousStart == nil ? 0 : 0.05), interval: start - (previousStart ?? start - 0.8))
                - 1 + position($0 - hold, interval: hold))
    }
    track("transform.scale", "rowScale") { 0.97 + 0.03 * (scale($0) - scale($0 - defocus)) }
    if let blur = CIFilter(name: "CIGaussianBlur") {
        blur.name = "rowFocus"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        layer.filters = [blur]
        // A waiting line is one step out of focus, a passed line is two steps back.
        track("filters.rowFocus.inputRadius", "rowBlur") { t in
            let incoming = 1.6 * (1 - ease(t))
            let rest = 0.8 * ease(t - defocus)
            return incoming + rest + 1.6 * ease(t - hold)
        }
    }
}

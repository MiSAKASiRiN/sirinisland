import AppKit
import MediaRemoteAdapter
import ImageIO

struct AudioSource: Equatable {
    let pid: Int32?
    let bundles: Set<String>
}

struct IslandSong {
    var title: String
    var artist: String
    var album: String
    var sourceName: String
    var source: AudioSource
    var artwork: NSImage?
    var playing: Bool
    var elapsed: Double
    var duration: Double
    var anchor: Date

    var trackID = UUID()
    var textTransitionID = UUID()
    var mediaID: Int?


    var artistAndAlbum: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator:" · ")
    }

    func position(at time: Date) -> Double {
        let current = max(0, elapsed + (playing ? time.timeIntervalSince(anchor) : 0))
        return duration > 0 ? min(duration, current) : current
    }
}

final class NowPlaying {
    let controller = MediaController(bundleIdentifiers: [])
    private let model: IslandModel
    private var clear: DispatchWorkItem?
    private var restart: DispatchWorkItem?
    private var lastArtwork: String?
    private var lastThumbnail: NSImage?
    private var reportedPlaying = false
    private var pendingPause: DispatchWorkItem?
    private var pausedPosition: Double?
    private static let pauseGrace: TimeInterval = 0.65
    private var listening = false
    private let audio = SourceAudioMonitor()

    init(_ model: IslandModel) {
        self.model = model
        audio.output = { [weak model] source, levels, status in
            guard let model, model.song?.source == source, model.song?.playing == true else { return }
            model.meter.update(levels, status: status)
        }
    }
    func start() {
        listening = true
        controller.onTrackInfoReceived = { [weak self] info, _ in self?.receive(info) }
        controller.onPlaybackStateReceived = { [weak self] state in self?.playback(state) }
        controller.onListenerTerminated = { [weak self] in
            guard let self, self.listening else { return }
            self.scheduleClear()
            let work = DispatchWorkItem { [weak self] in self?.start() }
            self.restart = work
            DispatchQueue.main.asyncAfter(deadline: .now()+2, execute: work)
        }
        controller.startListening()
    }
    func stop() {
        listening = false
        clear?.cancel()
        clear = nil
        cancelPause()
        restart?.cancel()
        controller.stopListening()
        audio.select(nil)
    }
    func retryAudio() {
        guard let song = model.song, song.playing else { return }
        audio.select(song.source)
    }
    private func scheduleClear() {
        guard clear == nil else { return }
        cancelPause()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clear = nil
            self.lastArtwork = nil
            self.lastThumbnail = nil
            self.reportedPlaying = false
            self.setSong(nil)
        }
        clear = work
        DispatchQueue.main.asyncAfter(deadline: .now()+2, execute: work)
    }
    func receive(_ info: TrackInfo?) {
        guard let info, let name = info.title?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            scheduleClear()
            return
        }
        clear?.cancel()
        clear = nil
        let old = model.song
        var title = name
        var artist = info.artist ?? ""
        // Some iOS music players publish “title — artist” in a single field on Mac.
        if let pid = info.processIdentifier.flatMap(Int32.init(exactly:)),
           let combined = [name, artist].first(where: { $0.contains(" — ") }),
           MediaController.isiOSAppOnMac(runningApp: NSRunningApplication(processIdentifier: pid)),
           let separator = combined.range(of: " — ") {
            let first = combined[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let second = combined[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            if !first.isEmpty && !second.isEmpty { title = first; artist = second }
        }
        let source = AudioSource(pid: info.processIdentifier.flatMap(Int32.init(exactly:)),
                                 bundles: Set([info.bundleIdentifier, info.parentApplicationBundleIdentifier].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }))
        let album = info.album?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let mediaID = info.uniqueIdentifier.flatMap { $0 == 0 || $0 == -1 ? nil : $0 }
        let same = old.map { previous in
            let sameSource = source == previous.source || !source.bundles.isDisjoint(with:previous.source.bundles)
                || (source.pid != nil && source.pid == previous.source.pid)
                || (source.pid == nil && source.bundles.isEmpty)
                || (previous.source.pid == nil && previous.source.bundles.isEmpty)
            guard sameSource else { return false }
            if let mediaID, let oldID = previous.mediaID { return mediaID == oldID }
            // Album and duration often arrive in later notifications.
            return LyricTrack.norm(title) == LyricTrack.norm(previous.title)
                && (artist.isEmpty || previous.artist.isEmpty || LyricTrack.norm(artist) == LyricTrack.norm(previous.artist))
        } ?? false
        let resolvedArtist = same && artist.isEmpty ? old?.artist ?? "" : artist
        let resolvedAlbum = same && album.isEmpty ? old?.album ?? "" : album
        var art = same ? old?.artwork : nil
        if let encoded = info.artworkDataBase64, !encoded.isEmpty {
            if encoded == lastArtwork {
                art = lastThumbnail
            } else if let data = Data(base64Encoded:encoded), let image = Self.thumbnail(data) {
                if !Self.samePixels(lastThumbnail,image) { lastThumbnail = image }
                lastArtwork = encoded
                art = lastThumbnail
            }
        }
        if art !== old?.artwork {
            model.meter.changeTint(to: art.map(AlbumTint.dominant) ?? AlbumTint.fallback)
        }
        let now = Date()
        if let playing = info.isPlaying { reportedPlaying = playing }
        let duration = info.durationMicros.map { $0 / 1e6 } ?? (same ? old?.duration ?? 0 : 0)
        var position = same ? pausedPosition ?? old?.position(at: now) ?? 0 : 0
        if let micros = info.elapsedTimeMicros {
            position = micros / 1e6
            if reportedPlaying, let stamp = info.timestampEpochMicros {
                position += max(0, now.timeIntervalSince1970 - stamp / 1e6)
            }
        }
        // A new track can arrive paused before its first playing notification.
        if !same { cancelPause() }
        let playing = displayPlaying(at: position)
        var next = IslandSong(title: title, artist: resolvedArtist, album: resolvedAlbum,
                           sourceName: info.applicationName ?? info.parentApplicationBundleIdentifier ?? info.bundleIdentifier ?? "",
                           source: source, artwork: art, playing: playing, elapsed: position, duration: duration, anchor: now)
        next.mediaID = mediaID ?? (same ? old?.mediaID : nil)
        if let old {
            if same { next.trackID = old.trackID }
            if same || (old.title == title && old.artist == resolvedArtist && old.album == resolvedAlbum) {
                next.textTransitionID = old.textTransitionID
            }
        }
        setSong(next)
    }
    func playback(_ raw: Int?) {
        guard let raw, (0...3).contains(raw) else { return }
        reportedPlaying = raw == 1
        guard var song = model.song else { return }
        let now = Date()
        let position = pausedPosition ?? song.position(at: now)
        let wasPending = pendingPause != nil
        let playing = displayPlaying(at: position)
        guard song.playing != playing || (wasPending && reportedPlaying) else { return }
        song.elapsed = position
        song.anchor = now
        song.playing = playing
        setSong(song)
    }

    private func cancelPause() {
        pendingPause?.cancel()
        pendingPause = nil
        pausedPosition = nil
    }

    // Both notification streams use the same deadline. Repeated pause packets
    // update the playhead without postponing a genuine pause.
    private func displayPlaying(at position: Double) -> Bool {
        if reportedPlaying {
            cancelPause()
            return true
        }
        guard model.song?.playing == true else { return false }
        guard clear == nil else { return true }
        pausedPosition = position
        if pendingPause == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, var song = self.model.song, let position = self.pausedPosition else { return }
                self.cancelPause()
                song.elapsed = position
                song.anchor = Date()
                song.playing = false
                self.setSong(song)
            }
            pendingPause = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseGrace, execute: work)
        }
        return true
    }
    private func setSong(_ song: IslandSong?) {
        let previous = model.song
        model.lyrics.select(song)
        if song == nil, previous != nil { model.meter.changeTint(to: AlbumTint.fallback) }
        model.song = song
        let source = song.flatMap { $0.playing ? $0.source : nil }
        if source != previous.flatMap({ $0.playing ? $0.source : nil }) {
            model.meter.update([], status: source == nil ? "已暂停" : "正在连接音频")
            audio.select(source)
        }
    }
    // Compare displayed pixels when a player republishes art with a different encoding.
    private static func samePixels(_ previous: NSImage?, _ next: NSImage) -> Bool {
        guard let previous, previous.size == next.size else { return false }
        func sample(_ image: NSImage) -> [UInt8]? {
            guard let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil),
                  let ctx = CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cg,in:CGRect(x:0,y:0,width:32,height:32))
            guard let data = ctx.data else { return nil }
            return Array(UnsafeBufferPointer(start:data.assumingMemoryBound(to:UInt8.self),count:4096))
        }
        guard let a = sample(previous), let b = sample(next) else { return false }
        return zip(a,b).allSatisfy { abs(Int($0)-Int($1)) <= 3 }
    }
    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 180,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

final class SpectrumMeter: ObservableObject {
    @Published private(set) var tint = AlbumTint.fallback
    private var fade: Timer?
    func changeTint(to target: NSColor) {
        fade?.invalidate()
        let origin = tint
        guard origin != target, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { tint = target; return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1/30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1,(ProcessInfo.processInfo.systemUptime-start)/0.65)
            let fraction = t*t*(3-2*t)
            self.tint = NSColor(srgbRed: origin.redComponent + (target.redComponent-origin.redComponent)*fraction,
                                green: origin.greenComponent + (target.greenComponent-origin.greenComponent)*fraction,
                                blue: origin.blueComponent + (target.blueComponent-origin.blueComponent)*fraction, alpha: 1)
            if t >= 1 { timer.invalidate() }
        }
        fade = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @Published private(set) var levels = [CGFloat](repeating: 0, count: SpectrumBands.count)
    @Published private(set) var status = ""
    func update(_ new: [CGFloat], status: String) {
        if self.status != status { self.status = status }
        let next = new.isEmpty ? Array(repeating: 0, count: SpectrumBands.count) : new
        if next != levels { levels = next }
    }
}

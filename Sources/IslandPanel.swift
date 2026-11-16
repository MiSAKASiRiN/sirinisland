import AppKit
import SwiftUI
import Combine

struct Placement {
    let screen: NSScreen
    let center: CGFloat
    let gap: CGFloat
    let crown: CGFloat
    var narrow: CGFloat { gap + 76 }
    let wide: CGFloat = 378
    var tall: CGFloat { crown + 154 }
    init(_ screen: NSScreen) {
        self.screen = screen
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            center = (left.maxX + right.minX) / 2
            gap = right.minX - left.maxX
            crown = screen.safeAreaInsets.top
        } else {
            center = screen.frame.midX
            gap = 28
            crown = 23
        }
    }
    func frame(_ t: CGFloat, music: Bool = false, footerExtra: CGFloat = 0) -> NSRect {
        // Both wings meet the physical camera gap, even when only the left wing widens.
        let extra: CGFloat = music ? 90 * (1-t) : 0
        let w = narrow + (max(wide, narrow) - narrow) * t + extra
        let h = crown + (tall + footerExtra - crown) * t
        return NSRect(x: round(center - (w+extra)/2), y: screen.frame.maxY - h, width: w, height: h)
    }
}

final class IslandCanvas: NSView {
    override var isFlipped: Bool { true }
    var onEnter: ((NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var progress: CGFloat = 0
    var compactMusic: CGFloat = 0
    var departingLevels: [CGFloat]?
    var departingTint: NSColor?
    var resumeFrom: CGFloat?
    var musicPhase: CGFloat = 0

    var presentedBands: [CGFloat] {
        let live = SpectrumBands.compact(model.meter.levels)
        guard let departingLevels else { return live }
        guard let resumeFrom else { return departingLevels }
        let mix = IslandMotion.fade((musicPhase-resumeFrom)/max(0.001,1-resumeFrom))
        return zip(departingLevels,live).map { $0+($1-$0)*mix }
    }
    var crown: CGFloat = 32
    let model: IslandModel
    private var hover: NSTrackingArea?
    init(model: IslandModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        hover = area
    }
    override func mouseEntered(with event: NSEvent) { onEnter?(window?.convertPoint(toScreen:event.locationInWindow) ?? NSEvent.mouseLocation) }
    override func mouseMoved(with event: NSEvent) { onMove?(window?.convertPoint(toScreen:event.locationInWindow) ?? NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    private func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil, !files(sender).isEmpty else { return [] }
        onDrag?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDrag?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        onDrop?(urls)
        onDrag?(false)
        return !urls.isEmpty
    }
    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height, lip: CGFloat = 7
        let r = min(h/2, 10 + 14*progress)
        let p = NSBezierPath()
        p.move(to: .zero)
        p.curve(to: CGPoint(x: lip,y: lip), controlPoint1: CGPoint(x: lip*0.65,y: 0), controlPoint2: CGPoint(x: lip,y: lip*0.3))
        p.line(to: CGPoint(x: lip,y: h-r))
        p.curve(to: CGPoint(x: lip+r,y:h), controlPoint1: CGPoint(x:lip,y:h-r*0.44), controlPoint2: CGPoint(x:lip+r*0.44,y:h))
        p.line(to: CGPoint(x:w-lip-r,y:h))
        p.curve(to: CGPoint(x:w-lip,y:h-r), controlPoint1: CGPoint(x:w-lip-r*0.44,y:h), controlPoint2: CGPoint(x:w-lip,y:h-r*0.44))
        p.line(to: CGPoint(x:w-lip,y:lip))
        p.curve(to: CGPoint(x:w,y:0), controlPoint1: CGPoint(x:w-lip,y:lip*0.3), controlPoint2: CGPoint(x:w-lip*0.65,y:0))
        p.close()
        NSColor.black.setFill()
        p.fill()

        let amber = NSColor(srgbRed: 1, green: 0.74, blue: 0.39, alpha: 1)
        let x = 23 + 2*progress, y = crown/2
        let music = compactMusic
        if music > 0 { drawSpectrum(y:y, width:w, presence:music) }
        guard music < 1 else { return }
        let idle = 1-music
        let header = IslandMotion.fade((progress-0.63)/0.32)
        IslandLogo.idleImage.draw(in: CGRect(x: x-8, y: y-8, width: 16, height: 16),
                                  from: .zero, operation: .sourceOver, fraction: idle, respectFlipped: true, hints: nil)

        if header > 0 {
            drawText("SirinIsland", at: CGPoint(x: x+13,y:y), color: NSColor.lightGray.withAlphaComponent(header), size: 10)
            let time = Self.formatter.string(from: model.now)
            drawText(time, at: CGPoint(x:w-24,y:y), color: NSColor.lightGray.withAlphaComponent(header), size: 10, right: true)
        }
        let accessory = idle*(1-header)
        guard accessory > 0 else { return }
        if model.clock.phase == .running || model.clock.phase == .paused {
            drawText("\(Int(ceil(Double(model.remaining)/60)))′", at: CGPoint(x:w-15,y:y), color: amber.withAlphaComponent(accessory), size: 10, right: true)
        } else {
            let symbol = model.clock.phase == .finished ? "checkmark" : (model.items.isEmpty ? "chevron.down" : "tray.fill")
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.lightGray]))
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                icon.draw(in: CGRect(x:w-23-icon.size.width/2,y:y-icon.size.height/2,width:icon.size.width,height:icon.size.height),
                          from: .zero, operation: .sourceOver, fraction: accessory, respectFlipped: true, hints: nil)
            }
        }
    }
    private func drawSpectrum(y: CGFloat, width: CGFloat, presence: CGFloat) {
        (departingTint ?? model.meter.tint).withAlphaComponent(presence).setFill()
        let values = presentedBands
        for (i, level) in values.enumerated() {
            let height = 2.5 + max(0, 18*level-2.5)*presence
            let bar = CGRect(x: width-34 + CGFloat(i)*3.7, y:y-height/2, width:2.4, height:height)
            NSBezierPath(roundedRect: bar, xRadius:1.2, yRadius:1.2).fill()
        }
    }
    private static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private func drawText(_ text: String, at pt: CGPoint, color: NSColor, size: CGFloat, right: Bool = false) {
        let str = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size,weight: .medium), .foregroundColor: color])
        let s = str.size()
        str.draw(at: CGPoint(x: pt.x-(right ? s.width : 0),y:pt.y-s.height/2))
    }
}

final class IslandWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CompactHost: NSHostingView<CompactTrack> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PanelLayout: Equatable {
    var frame: NSRect
    var expansion, music, crown, hostHeight: CGFloat
    var compactLyricHeight: CGFloat = 0

    func combining(_ other: PanelLayout, _ mix: (CGFloat,CGFloat) -> CGFloat) -> PanelLayout {
        // A layout also represents velocity here, so use signed size components.
        let rect = NSRect(x:mix(frame.origin.x, other.frame.origin.x), y:mix(frame.origin.y, other.frame.origin.y),
                          width:mix(frame.size.width, other.frame.size.width), height:mix(frame.size.height, other.frame.size.height))
        return PanelLayout(frame:rect, expansion:mix(expansion,other.expansion), music:mix(music,other.music),
                           crown:mix(crown,other.crown), hostHeight:mix(hostHeight,other.hostHeight),
                           compactLyricHeight:mix(compactLyricHeight,other.compactLyricHeight))
    }
}

final class IslandController {
    let panel: IslandWindow
    let canvas: IslandCanvas
    let host: NSHostingView<IslandContent>
    let model: IslandModel
    var placement: Placement
    private(set) var expanded = false
    private let compact: CompactHost
    private let lyricPanel: CompactLyricsPanel
    private var compactLyricsObservation: AnyCancellable?
    private var compactLyricHeight: CGFloat = 0
    private var footerPartCount: Int?
    private var compactStripHeight: CGFloat {
        let width = placement.frame(0, music: playing).width - 32 // child insets plus content padding
        let eventHeight = footerPartCount.map { BatteryReadout.contentHeight(parts: $0, width: width) + 5 } ?? 0
        return max(playing ? compactLyricHeight : 0, eventHeight)
    }
    private var pointerWatch: Timer?
    private var pointerOverLyrics = false
    private var retractedFootprint: NSRect?
    private var hoveringCompactBody = false
    private var playing = false
    private var wantsVisible = false
    private var visibilityRevision = 0
    private var displayed: PanelLayout
    private var destination: PanelLayout
    private var animation: Timer?
    private var stopDisplayLink: (() -> Void)?
    private var advanceLayout: (() -> Void)?
    private var velocity: PanelLayout?
    private var pending: DispatchWorkItem?
    private var observation: AnyCancellable?
    private var songObservation: AnyCancellable?
    private var lastTrack: UUID?
    private enum TrackPreview { case opening, showing(DispatchTime), event }
    private var preview: TrackPreview?
    private var previewSettings: AnyCancellable?
    private var previewEnd: DispatchWorkItem?
    private var eventEnd: DispatchWorkItem?
    private var pendingBattery: [BatteryNotice] = []
    private var previewPointer = NSPoint.zero
    private var footerLayout: AnyCancellable?
    private var footerExtra: CGFloat = 0
    private var waveObservation: AnyCancellable?

    init(model: IslandModel, screen: NSScreen) {
        self.model = model
        lyricPanel = CompactLyricsPanel(model:model)
        placement = Placement(screen)
        let initial = PanelLayout(frame:placement.frame(0), expansion:0, music:0, crown:placement.crown, hostHeight:154)
        displayed = initial
        destination = initial
        compact = CompactHost(rootView:CompactTrack(model:model,side:min(22,placement.crown-5)))
        canvas = IslandCanvas(model: model)
        host = NSHostingView(rootView: IslandContent(m: model, width: placement.wide-14))
        panel = IslandWindow(contentRect: placement.frame(0), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue+1)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.contentView = canvas
        canvas.addSubview(host)
        canvas.addSubview(compact)
        observation = model.objectWillChange.sink { [weak canvas] _ in canvas?.needsDisplay = true }
        songObservation = model.$song.sink { [weak self] song in self?.received(song) }
        previewSettings = model.$autoExpandsOnTrackChange.combineLatest(model.$previewSeconds)
            .sink { [weak self] enabled, seconds in
                guard let self, let preview = self.preview else { return }
                if case .event = preview { return }
                if !enabled { self.finishPreview() }
                else if case let .showing(start) = preview { self.schedulePreviewEnd(start:start,seconds:seconds) }
            }
        footerLayout = model.lyrics.$footerHeight.combineLatest(model.$showFooterMenu)
            .map { height, menu in menu ? 0 : height-26 }.removeDuplicates().sink { [weak self] extra in
                guard let self else { return }
                self.footerExtra = extra
                self.updateLayout()
            }
        compactLyricsObservation = model.$keepsCompactLyrics.combineLatest(
            model.lyrics.$lines.map { !$0.isEmpty }.removeDuplicates(), model.lyrics.$footerHeight,
            model.$footerEvent.map { event -> Int? in
                guard let event else { return nil }
                if case let .battery(notice) = event { return notice.parts.count }
                return 0
            }.removeDuplicates()
        ).sink { [weak self] enabled, hasLines, height, event in
            self?.footerPartCount = event
            self?.compactLyricHeight = (enabled || event != nil) && hasLines ? height+5 : 0
            self?.updateLayout()
        }
        waveObservation = model.meter.objectWillChange.sink { [weak self] _ in
            guard let self, !self.expanded, self.panel.isVisible else { return }
            self.canvas.needsDisplay = true
        }
        canvas.onEnter = { [weak self] point in
            guard let self else { return }
            // Resizing under a stationary cursor can also generate an enter event.
            if self.preview != nil && hypot(point.x-self.previewPointer.x, point.y-self.previewPointer.y) < 1 { return }
            self.cancelPreview()
            if self.expanded { self.schedule(true, after:0.15) }
            else { self.compactHover(at:point) }
        }
        canvas.onMove = { [weak self] point in
            guard let self else { return }
            if !self.expanded { self.compactHover(at:point) }
            else if self.preview != nil && hypot(point.x-self.previewPointer.x, point.y-self.previewPointer.y) >= 1 {
                self.cancelPreview()
            }
        }
        canvas.onExit = { [weak self] in self?.pointerLeft() }
        canvas.onClick = { [weak self] in
            guard let self else { return }
            self.show(!self.expanded)
        }
        canvas.onDrag = { [weak self] active in
            guard let self else { return }
            model.dragOver = active
            if active { model.tab = .shelf; self.show(true) }
            else if !self.panel.frame.contains(NSEvent.mouseLocation) { self.pointerLeft() }
        }
        model.exportEnded = { [weak self] in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.pointerLeft()
        }
        canvas.onDrop = { model.stash($0) }
        present(displayed)
        setVisible(true)
    }
    func setVisible(_ visible: Bool) {
        guard visible != wantsVisible || (visible && !panel.isVisible) else { return }
        wantsVisible = visible
        if !visible {
            eventEnd?.cancel()
            pendingBattery.removeAll()
            model.footerEvent = nil
        }
        visibilityRevision += 1
        let revision = visibilityRevision
        panel.ignoresMouseEvents = !visible
        if visible {
            if !panel.isVisible { panel.alphaValue = 0; lyricPanel.alphaValue = 0 }
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints:0.33,0.06,0.67,1)
            panel.animator().alphaValue = visible ? 1 : 0
            lyricPanel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard !visible, let self, self.visibilityRevision == revision else { return }
            self.lyricPanel.present(below:self.panel,crown:self.displayed.crown,height:0)
            self.panel.orderOut(nil)
        }
        updateLayout()
    }

    private func compactHover(at point: NSPoint) {
        let inside = placement.frame(0,music:playing).contains(point)
        guard inside != hoveringCompactBody else { return }
        hoveringCompactBody = inside
        if inside {
            if playing && !model.dragOver { model.tab = .music }
            schedule(true,after:0.15)
        } else {
            pending?.cancel()
        }
    }

    // Probe the full, un-retracted footprint. Hiding the strip must not synthesize
    // a leave/enter cycle, and a click must still reach the app underneath.
    private var lyricFootprint: NSRect {
        let body = placement.frame(0,music:playing)
        return NSRect(x:body.minX+7,y:body.minY-compactStripHeight,
                      width:body.width-14,height:compactStripHeight)
    }

    private func watchPointer(_ needed: Bool) {
        let point = NSEvent.mouseLocation
        if !needed {
            // Lyrics briefly clear before the new song is published. Keep the
            // avoided area through that handoff if the pointer is still there.
            if !playing || expanded || !model.keepsCompactLyrics || !panel.isVisible || retractedFootprint?.contains(point) != true {
                retractedFootprint = nil
            }
            pointerWatch?.invalidate()
            pointerWatch = nil
            pointerOverLyrics = false
            return
        }
        pointerOverLyrics = lyricFootprint.contains(point)
        retractedFootprint = pointerOverLyrics ? lyricFootprint : nil
        guard pointerWatch == nil else { return }
        let watch = Timer(timeInterval:1/30,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.lyricFootprint.contains(NSEvent.mouseLocation) != self.pointerOverLyrics { self.updateLayout() }
        }
        pointerWatch = watch
        RunLoop.main.add(watch,forMode:.common)
    }

    private func received(_ song: IslandSong?) {
        let wasPlaying = playing
        playing = song?.playing == true
        if wasPlaying != playing {
            model.departingCompactSong = playing ? nil : model.song
            if playing {
                // On a quick reversal the audio tap may still be reconnecting.
                canvas.resumeFrom = min(1,max(0,displayed.music))
            } else {
                canvas.departingLevels = canvas.presentedBands
                canvas.departingTint = model.meter.tint
                canvas.resumeFrom = nil
            }
            updateLayout()
        }
        let previous = lastTrack
        lastTrack = song?.trackID
        guard let song else {
            model.finishCoverHold(interrupted:true)
            if case .event = preview { return }
            if preview != nil { show(false) }
            return
        }
        guard previous != song.trackID, wantsVisible, panel.isVisible, !model.pinned, !model.dragOver, !model.exporting,
              !expanded || preview != nil else { return }
        // Mount the music card on first playback so its next cover can turn as the panel opens.
        model.tab = .music
        guard previous != nil, model.autoExpandsOnTrackChange else { return }
        if !expanded && model.keepsCompactLyrics && (lyricFootprint.contains(NSEvent.mouseLocation)
            || retractedFootprint?.contains(NSEvent.mouseLocation) == true) { return }
        // The song publisher delivers its new value before model.song is replaced.
        // Keep the original cover across further skips while this window is opening.
        if displayed.expansion < 1 && model.openingCover == nil {
            model.openingCover = model.song
        }
        let alreadyHovered = preview == nil && panel.frame.contains(NSEvent.mouseLocation)
        model.showFooterMenu = false
        show(true)
        guard !alreadyHovered else { return }
        previewPointer = NSEvent.mouseLocation
        preview = .opening
        if displayed.expansion == 1 { startPreviewCountdown() }
    }

    func presentEvent(_ event: FooterEvent) {
        guard wantsVisible else { return }
        if case let .battery(notice) = event, let current = model.footerEvent, current != event {
            if let index = pendingBattery.firstIndex(where: { $0.device.id == notice.device.id && $0.kind == notice.kind }) {
                let parts = notice.parts + pendingBattery[index].parts.filter { old in !notice.parts.contains { $0.id == old.id } }
                pendingBattery[index] = BatteryNotice(kind: notice.kind, device: notice.device, parts: parts.sorted { $0.order < $1.order })
            } else { pendingBattery.append(notice) }
            return
        }
        displayEvent(event)
    }

    private func displayEvent(_ event: FooterEvent) {
        model.footerEvent = event
        eventEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.pendingBattery.isEmpty {
                self.displayEvent(.battery(self.pendingBattery.removeFirst()))
                return
            }
            self.model.footerEvent = nil
            if case .event = self.preview { self.finishPreview() }
        }
        eventEnd = end
        DispatchQueue.main.asyncAfter(deadline:.now()+1.8,execute:end)
    }

    private func startPreviewCountdown() {
        guard case .opening = preview else { return }
        let start = DispatchTime.now()
        preview = .showing(start)
        schedulePreviewEnd(start:start,seconds:model.previewSeconds)
    }

    private func schedulePreviewEnd(start: DispatchTime, seconds: Int) {
        previewEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.finishPreview() }
        previewEnd = end
        DispatchQueue.main.asyncAfter(deadline:start + .seconds(seconds),execute:end)
    }

    private func finishPreview() {
        if model.footerEvent != nil {
            // A volume burst can outlast a track preview's original deadline.
            previewEnd?.cancel()
            previewEnd = nil
            preview = .event
            return
        }
        cancelPreview()
        if !model.pinned && !model.dragOver && !model.exporting { show(false) }
    }

    private func cancelPreview() {
        preview = nil
        previewEnd?.cancel()
        previewEnd = nil
    }

    func relocate(_ screen: NSScreen) {
        placement = Placement(screen)
        compact.rootView = CompactTrack(model:model,side:min(22,placement.crown-5))
        updateLayout()
    }
    func pointerLeft() {
        hoveringCompactBody = false
        guard preview == nil else { return }
        pending?.cancel()
        if !model.pinned && !model.dragOver && !model.exporting { schedule(false, after: 0.36) }
    }
    func schedule(_ open: Bool, after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(open) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
    }
    func show(_ open: Bool) {
        cancelPreview()
        pending?.cancel()
        if !open {
            model.finishCoverHold(interrupted:true)
            model.pinned = false
        }
        guard expanded != open else { return }
        hoveringCompactBody = false
        expanded = open
        model.panelExpanded = open
        if !open {
            model.showFooterMenu = false
            if model.song?.playing == true { model.tab = .music }
        }
        updateLayout()
    }

    // Every panel size change enters here, including a new target during an animation.
    private func updateLayout() {
        let eligible = !expanded && compactStripHeight > 0 && wantsVisible && panel.isVisible
        watchPointer(eligible && playing && compactLyricHeight > 0)
        let open: CGFloat = expanded ? 1 : 0
        let target = PanelLayout(frame:placement.frame(open,music:playing,footerExtra:footerExtra),
                                 expansion:open,music:playing ? 1 : 0,crown:placement.crown,hostHeight:154+footerExtra,
                                 compactLyricHeight:eligible && !pointerOverLyrics ? compactStripHeight : 0)
        guard target != destination else { return }
        let playbackChange = !expanded && (target.music != destination.music || abs(displayed.music-target.music) > 0.005)
        destination = target
        stopLayoutClock()
        let start = displayed, inherited = velocity
        let began = ProcessInfo.processInfo.systemUptime
        var last = began
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let stripChange = !expanded && target.compactLyricHeight != displayed.compactLyricHeight
        let spring = (playbackChange || stripChange) && !reduced
        let duration = reduced ? 0.14 : (spring ? 0.48 : IslandMotion.resizeDuration)
        advanceLayout = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now-began, t = min(1, elapsed/duration)
            if t >= 1 {
                self.stopLayoutClock()
                self.velocity = nil
                self.present(target)
                if target.music == 0 {
                    self.model.departingCompactSong = nil
                }
                self.canvas.departingLevels = nil
                self.canvas.departingTint = nil
                self.canvas.resumeFrom = nil
                if self.expanded {
                    self.model.finishCoverHold()
                    self.startPreviewCountdown()
                }
                return
            }
            // In the compact wing use the damped oscillator's position and velocity
            // responses. A redirected gesture inherits the velocity of the last frame.
            let decay = exp(-15*elapsed)
            let p = spring ? 1-decay*(cos(10*elapsed)+1.5*sin(10*elapsed)) : IslandMotion.progress(t)
            let carry = spring ? decay*sin(10*elapsed)/10 : elapsed*(1-t)*(1-t)
            var next = start.combining(target) { $0 + ($1-$0)*p }
            if let inherited, !reduced { next = next.combining(inherited) { $0+$1*carry } }
            let dt = max(0.001, now-last)
            self.velocity = self.displayed.combining(next) { ($1-$0)/dt }
            self.present(next)
            last = now
        }
        if #available(macOS 14.0, *) {
            let link = placement.screen.displayLink(target:self, selector:#selector(layoutFrame))
            let maximum = Float(placement.screen.maximumFramesPerSecond)
            if maximum >= 60 { link.preferredFrameRateRange = .init(minimum:60, maximum:maximum, preferred:maximum) }
            stopDisplayLink = { link.invalidate() }
            link.add(to:.main, forMode:.common)
        } else {
            let timer = Timer(timeInterval:1.0/Double(max(60,placement.screen.maximumFramesPerSecond)), repeats:true) { [weak self] _ in self?.layoutFrame() }
            animation = timer
            RunLoop.main.add(timer, forMode:.common)
        }
    }

    @objc private func layoutFrame() { advanceLayout?() }

    private func stopLayoutClock() {
        stopDisplayLink?()
        stopDisplayLink = nil
        animation?.invalidate()
        animation = nil
        advanceLayout = nil
    }

    private func present(_ layout: PanelLayout) {
        displayed = layout
        panel.setFrame(layout.frame, display: false)
        lyricPanel.present(below:panel,crown:layout.crown,height:layout.compactLyricHeight)
        canvas.crown = layout.crown
        canvas.progress = min(1,max(0,layout.expansion))
        let presence = IslandMotion.fade(layout.music) * (1-IslandMotion.fade((layout.expansion-0.04)/0.52))
        canvas.musicPhase = layout.music
        canvas.compactMusic = presence
        let width = placement.wide-14
        host.frame = CGRect(x:(layout.frame.width-width)/2, y:layout.crown, width:width, height:layout.hostHeight)
        host.alphaValue = IslandMotion.fade((layout.expansion-0.40)/0.60)
        host.isHidden = host.alphaValue < 0.001
        compact.frame = CGRect(x:14+5*(1-presence),y:0,width:min(22,layout.crown-5)+86,height:layout.crown)
        compact.alphaValue = presence
        compact.isHidden = compact.alphaValue < 0.001
        canvas.needsDisplay = true
    }
}

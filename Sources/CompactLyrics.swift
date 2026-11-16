import AppKit
import SwiftUI

private struct CompactLyricContent: View {
    @ObservedObject var model: IslandModel
    let running: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius:10).fill(.black)
            GeometryReader { bounds in
                LyricStrip(song:model.song, lyrics:model.lyrics, visible:running && model.keepsCompactLyrics && !model.panelExpanded && model.song?.playing == true, renderer:model.lyricRenderer, showsStatus:false)
                    .frame(height:stripHeight(width: bounds.size.width - 18))
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .opacity(model.keepsCompactLyrics && model.song?.playing == true ? 1 : 0)
                    .modifier(FooterOverlay(event:model.footerEvent))
                    .padding(.horizontal,9).padding(.bottom,3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .clipped()
    }

    private func stripHeight(width: CGFloat) -> CGFloat? {
        if case let .battery(notice) = model.footerEvent {
            return BatteryReadout.contentHeight(parts: notice.parts.count, width: width)
        }
        return model.song?.playing == true ? nil : 26
    }
}

// A separate, mouse-transparent surface keeps the original island's hit area intact.
// Its top few pixels sit behind the crown to join the two black shapes.
final class CompactLyricsPanel: NSPanel {
    private let model: IslandModel
    private var host: NSHostingView<CompactLyricContent>?
    private var rendering = false

    init(model: IslandModel) {
        self.model = model
        super.init(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(below body: NSPanel, crown: CGFloat, height: CGFloat) {
        guard height > 0.5, body.isVisible else {
            if rendering {
                rendering = false
                host?.rootView = CompactLyricContent(model:model,running:false)
                body.removeChildWindow(self)
                orderOut(nil)
            }
            if !model.keepsCompactLyrics && model.footerEvent == nil { contentView = nil; host = nil }
            return
        }
        let frame = body.frame
        let join: CGFloat = 10
        let bounds = NSRect(x:frame.minX+7,y:frame.maxY-crown-height,
                            width:frame.width-14,height:height+join)
        if self.frame != bounds { setFrame(bounds,display:false) }
        if !rendering {
            let view = CompactLyricContent(model:model,running:true)
            if let host { host.rootView = view } else {
                let hosting = NSHostingView(rootView:view)
                hosting.sizingOptions = []
                contentView = hosting
                host = hosting
            }
            rendering = true
            level = body.level
            body.addChildWindow(self,ordered:.below)
        }
    }
}

import SwiftUI
import WebKit

struct LyricStrip: View {
    let song: IslandSong?
    @ObservedObject var lyrics: IslandLyrics
    let visible: Bool
    var renderer: LyricRenderer = .native
    var showsStatus = true

    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var showLoading = false
    @State private var hasPreviousLyrics = false

    var body: some View {
        ZStack(alignment: .leading) {
            if let song {
                switch renderer {
                case .native:
                    NativeLyricViewport(song: song, lyrics: lyrics, visible: visible, reducedMotion: reduced)
                case .amll:
                    LyricViewport(song: song, lines: lyrics.lines, revision: lyrics.revision, visible: visible, loading: lyrics.status == IslandLyrics.loadingMessage)
                }
            }
            if showsStatus && lyrics.lines.isEmpty && (lyrics.status != IslandLyrics.loadingMessage || (showLoading && !hasPreviousLyrics)) {
                Text(lyrics.status).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)).lineLimit(1).padding(.leading, 4)
            }
        }
        .frame(height: lyrics.footerHeight)
        .animation(IslandMotion.settle(IslandMotion.resizeDuration, reduced:reduced), value: lyrics.footerHeight)
        .animation(IslandMotion.curve(0.16), value: showLoading)
        .clipped()
        .onAppear { hasPreviousLyrics = !lyrics.lines.isEmpty }
        .onChange(of: lyrics.lines.isEmpty) { empty in
            if !empty { hasPreviousLyrics = true }
        }
        .task(id: lyrics.status) {
            showLoading = false
            guard lyrics.status == IslandLyrics.loadingMessage else {
                if lyrics.lines.isEmpty { hasPreviousLyrics = false }
                return
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                showLoading = true
            } catch { /* Lyrics or playback changed while waiting. */ }
        }
    }
}

private final class LyricWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

private struct LyricViewport: NSViewRepresentable {
    let song: IslandSong
    let lines: [LyricCue]
    let revision: Int
    let visible: Bool

    let loading: Bool

    struct Clock: Equatable {
        let trackID: String
        let anchor: Double, elapsed: Double
        let playing: Bool, visible: Bool, loading: Bool
        var message: [String: Any] {
            ["trackID":trackID,"anchor":anchor,"elapsed":elapsed,"playing":playing,"visible":visible,"loading":loading,"fadeMS":IslandMotion.lyricDuration*1000]
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var ready = false
        var current: LyricViewport?
        var revision: Int?
        var clock: Clock?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            revision = nil
            clock = nil
            sync(webView)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.reload()
        }
        func sync(_ web: WKWebView) {
            guard ready, let current else { return }
            let s = current.song
            let next = Clock(trackID:s.trackID.uuidString, anchor:s.anchor.timeIntervalSince1970*1000, elapsed:s.elapsed*1000,
                             playing:s.playing, visible:current.visible, loading:current.loading)
            guard next != clock || revision != current.revision else { return }
            var args: [String: Any] = ["state":next.message]
            let replace = revision != current.revision
            if replace { args["rows"] = current.lines.map { $0.renderRow.webValue } }
            revision = current.revision
            clock = next
            web.callAsyncJavaScript(replace ? "window.islandLyrics.sync(state,rows)" : "window.islandLyrics.sync(state)",
                                    arguments:args, in:nil, in:.page) { result in
                if case .failure(let error) = result { NSLog("SirinIsland lyric renderer: %@",error.localizedDescription) }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let web = LyricWebView(frame:.zero, configuration:WKWebViewConfiguration())
        web.setValue(false, forKey:"drawsBackground")
        web.navigationDelegate = context.coordinator
        if let index = Bundle.main.url(forResource:"index",withExtension:"html",subdirectory:"LyricRenderer") {
            web.loadFileURL(index,allowingReadAccessTo:index.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.current = self
        context.coordinator.sync(web)
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.current = nil
        web.navigationDelegate = nil
        web.stopLoading()
    }
}

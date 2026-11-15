import AppKit
import SwiftUI

let honey = Color(red: 1, green: 0.74, blue: 0.39)
private let muted = Color(white: 0.63)

struct Orbit: View {
    var progress: Double
    var small = false
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width/2, y: size.height/2)
            let r = min(c.x, c.y)
            let count = small ? 12 : 36
            for i in 0..<count {
                let a = Double(i) * 2 * .pi / Double(count) - .pi/2
                let inner = r * (i % 3 == 0 ? 0.71 : 0.81)
                var ray = Path()
                ray.move(to: CGPoint(x: c.x + cos(a)*inner, y: c.y + sin(a)*inner))
                ray.addLine(to: CGPoint(x: c.x + cos(a)*(r-1), y: c.y + sin(a)*(r-1)))
                let lit = Double(i) / Double(count) < progress
                ctx.stroke(ray, with: .color(lit ? honey : .white.opacity(0.19)), style: StrokeStyle(lineWidth: small ? 1.5 : 2.1, lineCap: .round))
            }
            let core = small ? 2.2 : 5.0
            ctx.fill(Path(ellipseIn: CGRect(x: c.x-core, y: c.y-core, width: 2*core, height: 2*core)), with: .color(honey))
        }.accessibilityHidden(true)
    }
}

struct SmallButton: View {
    let icon: String
    let label: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            IslandSymbol(name:icon).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26).contentShape(Rectangle())
                .foregroundStyle(active ? honey : muted)
        }.buttonStyle(IslandButtonStyle()).accessibilityLabel(label).help(label)
    }
}

struct IslandContent: View {
    @ObservedObject var m: IslandModel
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Group {
                    switch m.tab {
                    case .music:
                        MusicCard(song:m.song, openingCover:m.openingCover, coverViewRevision:m.coverViewRevision,
                                  meter:m.meter, expanded:m.panelExpanded) { m.toggleMusic?() }
                    case .focus: focus
                    case .shelf: shelf
                    }
                }
                .id(m.tab)
                .transition(IslandMotion.reveal(reduced:reduced))
            }
            HStack(spacing: 3) {
                Group {
                    if m.showFooterMenu {
                        HStack(spacing:3) {
                            ForEach([IslandTab.focus, .shelf, .music], id: \.self) { tab in
                                Button {
                                    m.tab = tab
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: tab == .music ? "music.note" : (tab == .focus ? "timer" : "tray"))
                                        Text(tab == .music ? "音乐" : (tab == .focus ? "专注" : "暂存"))
                                        if tab == .shelf && !m.items.isEmpty {
                                            Text("\(m.items.count)").font(.system(size: 10).monospacedDigit())
                                        }
                                    }.font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 11).frame(height: 26)
                                    .background {
                                        if m.tab == tab {
                                            Capsule().fill(Color(white:0.16))
                                                .matchedGeometryEffect(id:"tab", in:selection, properties:reduced ? [] : .frame)
                                        }
                                    }
                                    .foregroundStyle(m.tab == tab ? Color.white : muted)
                                }.buttonStyle(IslandButtonStyle())
                            }
                            Spacer(minLength: 0)
                            SmallButton(icon: m.pinned ? "pin.fill" : "pin", label: m.pinned ? "取消固定" : "固定展开", active: m.pinned) {
                                m.pinned.toggle()
                            }
                        }.transition(IslandMotion.reveal(reduced:reduced))
                    } else {
                        LyricStrip(song: m.song, lyrics: m.lyrics, visible: m.panelExpanded, renderer: m.lyricRenderer)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(IslandMotion.reveal(reduced:reduced))
                    }
                }.modifier(FooterOverlay(event:m.footerEvent))
                SmallButton(icon: m.showFooterMenu ? "text.quote" : "line.3.horizontal",
                            label: m.showFooterMenu ? "显示歌词" : "显示功能菜单") {
                    m.showFooterMenu.toggle()
                }
            }.frame(minHeight: 26)
        }.padding(.horizontal, 16).padding(.bottom, 13)
        .animation(IslandMotion.settle(IslandMotion.resizeDuration, reduced:reduced), value: m.tab)
        .animation(IslandMotion.settle(IslandMotion.resizeDuration, reduced:reduced), value: m.showFooterMenu)
        .animation(IslandMotion.settle(IslandMotion.resizeDuration, reduced:reduced), value: m.items.count)
        .animation(IslandMotion.settle(IslandMotion.resizeDuration, reduced:reduced), value: m.clock.phase)
        .animation(IslandMotion.settle(0.28, reduced:reduced), value: m.clock.minutes)
        .animation(IslandMotion.curve(0.18), value: m.dragOver)
        .frame(width: width).environment(\.colorScheme, .dark)
    }

    private var focus: some View {
        VStack(spacing: 9) {
            HStack(spacing: 13) {
                Orbit(progress: max(0, Double(m.remaining)/Double(m.clock.minutes*60)))
                    .frame(width: 43, height: 43)
                VStack(alignment: .leading, spacing: 0) {
                    Text(phaseLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    Text(m.digits).font(.system(size: 37, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Spacer()
                if m.clock.phase != .ready {
                    SmallButton(icon: "arrow.counterclockwise", label: "重置计时") { m.reset(m.clock.minutes) }
                }
                Button { m.toggle() } label: {
                    IslandSymbol(name:m.clock.phase == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 37, height: 37).background(Circle().fill(honey))
                }.buttonStyle(IslandButtonStyle()).accessibilityLabel(playLabel).help(playLabel)
            }.padding(.horizontal, 14).frame(height: 74)
            .background(RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [Color(red: 0.13, green: 0.115, blue: 0.097), Color(white: 0.075)], startPoint: .leading, endPoint: .trailing)))
            HStack(spacing: 8) {
                Text("时长").font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                ForEach([5,25,45], id: \.self) { minute in
                    Button { m.reset(minute) } label: {
                        Text("\(minute) 分钟").font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 22)
                            .foregroundStyle(m.clock.minutes == minute ? honey : muted)
                            .background(Capsule().fill(m.clock.minutes == minute ? honey.opacity(0.12) : .clear))
                    }.buttonStyle(IslandButtonStyle()).disabled(m.clock.phase == .running || m.clock.phase == .paused)
                }
            }.padding(.horizontal, 4)
        }
    }
    private var phaseLabel: String {
        switch m.clock.phase { case .ready: return "准备专注"; case .running: return "专注中"; case .paused: return "已暂停"; case .finished: return "专注完成" }
    }
    private var playLabel: String {
        switch m.clock.phase { case .ready: return "开始专注"; case .running: return "暂停"; case .paused: return "继续"; case .finished: return "再来一轮" }
    }

    private var shelf: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(m.dragOver ? honey.opacity(0.11) : Color(white: 0.075))
            if m.items.isEmpty || m.dragOver {
                RoundedRectangle(cornerRadius: 14).strokeBorder(honey.opacity(m.dragOver ? 0.9 : 0.27), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 21, weight: .light)).foregroundStyle(honey)
                    Text(m.dragOver ? "松开以暂存" : "把文件拖到这里").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Text("暂存后可拖到其他 App").font(.system(size: 11)).foregroundStyle(muted)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(m.items) { item in
                            ShelfRow(item: item, model: m) { m.remove(item.id) }
                        }
                    }.padding(5)
                }
            }
        }.frame(height: 105)
    }
}

struct ShelfRow: View {
    let item: ShelfItem
    let model: IslandModel
    let remove: () -> Void
    @State private var copied = false
    var body: some View {
        let url = item.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        HStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24,height: 24)
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(exists ? .white : muted)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
            .overlay(FileDragHandle(url: url, model: model))
            .help(exists ? url.path : "原文件不可用")
            SmallButton(icon: copied ? "checkmark" : "doc.on.doc", label: copied ? "已复制" : "复制文件", active: copied) {
                copied = item.copyFileReference()
            }.disabled(!exists)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { copied = false }
            }
            SmallButton(icon: "magnifyingglass", label: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }.disabled(!exists)
            SmallButton(icon: "xmark", label: "从暂存架移除", action: remove)
        }.padding(.horizontal, 5).frame(height: 32)
    }
}

private struct FileDragHandle: NSViewRepresentable {
    let url: URL
    let model: IslandModel
    func makeNSView(context: Context) -> FileDragView { FileDragView() }
    func updateNSView(_ view: FileDragView, context: Context) {
        view.url = url
        view.model = model
    }
}

private final class FileDragView: NSView, NSDraggingSource {
    var url: URL?
    weak var model: IslandModel?
    private var origin: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, let url else { return }
        let point = event.locationInWindow
        guard hypot(point.x-origin.x, point.y-origin.y) >= 3 else { return }
        self.origin = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let mouse = convert(point, from: nil)
        item.setDraggingFrame(CGRect(x: mouse.x-12, y: mouse.y-12, width: 24, height: 24), contents: icon)
        model?.exporting = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model?.exporting = false
        model?.exportEnded?()
    }
}

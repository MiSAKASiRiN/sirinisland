import SwiftUI

enum IslandMotion {
    static let resizeDuration = 0.32
    static let trackDuration = 0.48
    static let lyricDuration = 0.34

    static func curve(_ duration: Double) -> Animation {
        .timingCurve(1.0/3, 0.06, 2.0/3, 1, duration: duration)
    }

    static func settle(_ duration: Double, reduced: Bool) -> Animation {
        reduced ? curve(0.14) : .spring(response:duration, dampingFraction:0.85, blendDuration:0.10)
    }

    static func reveal(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with:.offset(y:4)).combined(with:.scale(scale:0.985))
    }

    static func fade(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t*t*(3-2*t)
    }

    // The Bézier x control points are 1/3 and 2/3, so x(t) equals t.
    static func progress(_ t: CGFloat) -> CGFloat {
        3 * (1-t) * (1-t) * t * 0.06 + 3 * (1-t) * t * t + t*t*t
    }

    // Integrate a cubic Bézier velocity ramp at takeoff and a critically damped
    // spring's velocity decay at landing. The cruise speed matches both joins.
    static func scrollProgress(_ fraction: Double, duration: Double) -> Double {
        let t = min(1, max(0, fraction))
        guard t > 0 && t < 1 else { return t }
        let edge = min(0.22, 0.48 / max(0.001, duration))
        let residual = 7 * exp(-6.0)
        func landing(_ u: Double) -> Double {
            ((2 - (6*u + 2)*exp(-6*u))/6 - residual*u) / (1 - residual)
        }
        let distance = 1 - 1.5*edge + edge*landing(1)
        if t < edge {
            let u = t / edge
            return edge * u*u*u * (1 - 0.5*u) / distance
        }
        if t <= 1 - edge { return (t - 0.5*edge) / distance }
        return (1 - 1.5*edge + edge*landing((t - 1 + edge) / edge)) / distance
    }
}

struct IslandButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(configuration.isPressed ? IslandMotion.curve(0.10) : IslandMotion.settle(0.28, reduced:reduced),
                       value:configuration.isPressed)
    }
}

struct IslandSymbol: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack {
            Image(systemName:name).id(name)
                .transition(reduced ? .opacity : .opacity.combined(with:.scale(scale:0.82)))
        }.animation(IslandMotion.settle(0.26, reduced:reduced), value:name)
    }
}

// Signed distance from the front-facing position. The side facing the viewer
// stays tall while the far edge recedes, then the card leaves the aperture.
private struct CoverFlowPose: AnimatableModifier {
    var position: CGFloat
    let side: CGFloat
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }
    func body(content: Content) -> some View {
        let travel = abs(position)
        let tilt = min(1,travel/0.55)
        let direction: CGFloat = position < 0 ? -1 : 1
        let x = direction * side * (0.58*travel + 0.74*travel*travel)
        content
            .scaleEffect(1-0.19*tilt)
            .rotation3DEffect(.degrees(Double(-direction*64*tilt)), axis:(0,1,0), perspective:0.84)
            .brightness(-0.16*tilt)
            .offset(x:x)
    }
}

struct TrackSlide<Content: View>: View {
    let transitionID: UUID
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        GeometryReader { bounds in
            ZStack(alignment: .leading) {
                content().frame(width: bounds.size.width, height: bounds.size.height, alignment: .leading)
                    .id(transitionID)
                    .transition(reduced ? .opacity : .asymmetric(insertion:.move(edge:.trailing), removal:.move(edge:.leading)))
            }
            .animation(IslandMotion.settle(IslandMotion.trackDuration, reduced:reduced), value: transitionID)
        }.clipped()
    }
}

struct SongArtwork: View {
    let song: IslandSong
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced
    private struct Card {
        var track: UUID
        var image: NSImage?
        var slot = UUID()
    }
    private struct Request: Equatable {
        let track: UUID
        let image: ObjectIdentifier?
    }
    @State private var presented: Card?

    var body: some View {
        let card = presented ?? Card(track:song.trackID,image:song.artwork,slot:song.trackID)
        let front = CoverFlowPose(position:0,side:side)
        let flow = AnyTransition.asymmetric(
            insertion:.modifier(active:CoverFlowPose(position:0.30,side:side),identity:front).combined(with:.opacity),
            removal:.modifier(active:CoverFlowPose(position:-1,side:side),identity:front))
        ZStack {
            ZStack {
                Color(white:0.16)
                if let image = card.image {
                    Image(nsImage:image).resizable().aspectRatio(contentMode:.fill)
                } else {
                    Image(systemName:"music.note").font(.system(size:side*0.35)).foregroundStyle(honey)
                }
            }
            .frame(width:side,height:side)
            .clipShape(RoundedRectangle(cornerRadius:side*0.07))
            .id(card.slot)
            .transition(reduced ? .opacity : flow)
        }
        .frame(width:side >= 40 ? side+12 : side,height:side+2)
        .clipped()
        .task(id:Request(track:song.trackID,image:song.artwork.map(ObjectIdentifier.init))) {
            guard var shown = presented else {
                presented = Card(track:song.trackID,image:song.artwork,slot:song.trackID)
                return
            }
            let changedTrack = shown.track != song.trackID
            if changedTrack && song.artwork == nil && shown.image != nil {
                // Metadata frequently precedes artwork in the same track change.
                do { try await Task.sleep(nanoseconds:450_000_000) } catch { return }
            }
            let turns = changedTrack && shown.image != nil && song.artwork != nil && shown.image !== song.artwork
            shown.track = song.trackID
            shown.image = song.artwork
            if turns {
                shown.slot = UUID()
                withAnimation(IslandMotion.settle(IslandMotion.trackDuration, reduced:reduced)) { presented = shown }
            } else {
                presented = shown
            }
        }
    }
}

struct CompactTrack: View {
    @ObservedObject var model: IslandModel
    let side: CGFloat
    var body: some View {
        if let song = model.departingCompactSong ?? model.song {
            HStack(spacing: 6) {
                SongArtwork(song: model.openingCover ?? song, side: side)
                    .id(model.coverViewRevision)
                TrackSlide(transitionID:song.textTransitionID) {
                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(text:song.title, font:.system(size:10.5, weight:.medium), active:!model.panelExpanded && song.playing)
                        MarqueeText(text:song.artistAndAlbum.isEmpty ? "正在播放" : song.artistAndAlbum,
                                    font:.system(size:9), active:!model.panelExpanded && song.playing)
                            .foregroundStyle(.secondary)
                    }.lineLimit(1)
                }.frame(width: 80)
            }.foregroundStyle(.white).environment(\.colorScheme,.dark)
        }
    }
}

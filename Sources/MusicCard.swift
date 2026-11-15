import SwiftUI

struct MusicCard: View {
    let song: IslandSong?
    let openingCover: IslandSong?
    let coverViewRevision: Int
    let meter: SpectrumMeter
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        ZStack {
            if let song {
                HStack(spacing: 12) {
                    SongArtwork(song: openingCover ?? song, side: 67)
                        .id(coverViewRevision)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            ZStack(alignment:.leading) {
                                Text(song.playing ? "正在播放" : "已暂停").id(song.playing).transition(.opacity)
                            }.foregroundStyle(honey).animation(IslandMotion.curve(0.17), value:song.playing)
                            Spacer(minLength: 4)
                            if song.duration > 0 {
                                TimelineView(.periodic(from: song.anchor, by: song.playing ? 1 : 3600)) { tick in
                                    Text(Self.time(song.position(at: tick.date)) + " / " + Self.time(song.duration))
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }.font(.system(size: 9, weight: .medium))
                        TrackSlide(transitionID:song.textTransitionID) {
                            VStack(alignment: .leading, spacing: 3) {
                                MarqueeText(text:song.title, font:.system(size:15, weight:.semibold), active:expanded)
                                MarqueeText(text:song.artistAndAlbum, font:.system(size:11), active:expanded)
                                    .foregroundStyle(.secondary)
                            }.lineLimit(1)
                        }.frame(height: 35).help(song.title)
                        SpectrumStrip(meter: meter, playing: song.playing)
                    }.frame(maxWidth: .infinity, alignment: .leading).help(song.sourceName)
                    Button(action: toggle) {
                        IslandSymbol(name:song.playing ? "pause.fill" : "play.fill")
                            .frame(width: 31, height: 31).background(Circle().fill(.white.opacity(0.12)))
                    }.buttonStyle(IslandButtonStyle()).accessibilityLabel(song.playing ? "暂停音乐" : "继续播放")
                }.padding(.horizontal, 12).frame(height: 105)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 15).fill(Color(white: 0.08)))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").foregroundStyle(honey)
                    Text("暂无正在播放的媒体").font(.system(size: 13, weight: .medium))
                    Text("开始播放后，封面和频谱会出现在刘海两侧").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 105)
                .background(RoundedRectangle(cornerRadius: 15).fill(Color(white: 0.075)))
            }
        }.animation(IslandMotion.settle(0.30, reduced:reduced), value:song != nil)
    }
    private static func time(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds, 86400 * 365)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SpectrumStrip: View {
    @ObservedObject var meter: SpectrumMeter
    let playing: Bool
    var body: some View {
        ZStack {
            if playing && !meter.status.isEmpty {
                Text(meter.status).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).help(meter.status).frame(height: 16)
            } else {
                Canvas { ctx, size in
                    let pitch = size.width / CGFloat(meter.levels.count)
                    for (i, value) in meter.levels.enumerated() {
                        let height = max(1.8, size.height * value)
                        let rect = CGRect(x: CGFloat(i)*pitch, y: size.height-height,
                                          width: max(1, min(3, pitch-1)), height: height)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(playing ? Color(nsColor: meter.tint) : .gray))
                    }
                }.frame(height: 16).accessibilityLabel("实时频谱，从左到右为低频至高频").help("频率从左到右递增，柱高表示各频段的强度")
            }
        }.animation(IslandMotion.curve(0.18), value:playing && !meter.status.isEmpty)
    }
}

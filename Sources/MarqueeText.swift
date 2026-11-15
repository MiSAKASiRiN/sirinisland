import SwiftUI

private struct LabelWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Measure the same single-line glyphs that are drawn, including fallback fonts.
struct MarqueeText: View {
    let text: String
    let font: Font
    let active: Bool
    @State private var textWidth: CGFloat = 0

    private var label: some View {
        Text(verbatim: text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: true)
    }

    var body: some View {
        label.hidden()
            .background(GeometryReader { g in
                Color.clear.preference(key: LabelWidth.self, value: g.size.width)
            })
            .onPreferenceChange(LabelWidth.self) { textWidth = $0 }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .overlay {
                GeometryReader { g in
                    let overflow = textWidth - g.size.width
                    if active && g.size.width > 0 && overflow > 0.5 {
                        ScrollingLabel(textWidth: textWidth) { label }.id(text)
                    } else {
                        label
                    }
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore).accessibilityLabel(text).help(text)
    }
}

private struct ScrollingLabel<Label: View>: View {
    let textWidth: CGFloat
    @ViewBuilder let label: () -> Label
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60)) { tick in
            let speed: CGFloat = 29
            let gap: CGFloat = 32
            let hold = 1.0
            let pitch = textWidth + gap
            let duration = pitch/speed
            let phase = max(0, tick.date.timeIntervalSince(start))
                .truncatingRemainder(dividingBy: hold + duration)
            let time = max(0, phase - hold) / duration
            let travel = reducedMotion ? time : IslandMotion.scrollProgress(time, duration:duration)
            HStack(spacing:gap) { label(); label() }
                .fixedSize(horizontal:true, vertical:false)
                .offset(x:-pitch*travel)
        }
    }
}

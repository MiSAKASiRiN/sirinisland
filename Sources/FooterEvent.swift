import SwiftUI

enum FooterEvent: Equatable {
    case volume(OutputVolume)
    case brightness(Float)

    var level: CGFloat {
        switch self {
        case let .volume(volume): return volume.muted ? 0 : CGFloat(volume.level)
        case let .brightness(value): return CGFloat(value)
        }
    }

    var label: String {
        switch self {
        case .volume: return "系统音量"
        case .brightness: return "屏幕亮度"
        }
    }

    var percentage: Int? {
        if case let .volume(volume) = self, volume.muted { return nil }
        return Int((level*100).rounded())
    }

    var valueText: String {
        percentage.map { "\($0)%" } ?? "静音"
    }

    var icon: String {
        switch self {
        case let .volume(volume):
            if volume.muted { return "speaker.slash.fill" }
            if volume.level == 0 { return "speaker.fill" }
            return "speaker.wave." + String(min(3,max(1,Int(ceil(volume.level*3))))) + ".fill"
        case .brightness: return "sun.max.fill"
        }
    }
}

struct FooterOverlay: ViewModifier {
    let event: FooterEvent?
    func body(content: Content) -> some View {
        content.opacity(event == nil ? 1 : 0)
            .allowsHitTesting(event == nil)
            .accessibilityHidden(event != nil)
            .overlay {
                if let event { AdjustmentReadout(event:event).transition(.opacity) }
            }
            .animation(IslandMotion.curve(0.19),value:event != nil)
    }
}

private struct AdjustmentReadout: View {
    let event: FooterEvent
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        GeometryReader { bounds in
            let narrow = bounds.size.width < 130
            HStack(spacing:narrow ? 3 : 7) {
                IslandSymbol(name:event.icon).font(.system(size:12,weight:.semibold)).frame(width:narrow ? 14 : 19)
                GeometryReader { track in
                    ZStack(alignment:.leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white).frame(width:track.size.width*(revealed ? event.level : 0))
                            .animation(IslandMotion.settle(0.30,reduced:reduced),value:event.level)
                            .animation(IslandMotion.curve(reduced ? 0.12 : 0.24),value:revealed)
                    }.clipShape(Capsule())
                }.frame(height:4)
                PercentageLabel(value:event.percentage)
            }
            .padding(.horizontal,narrow ? 1 : 4)
            .frame(maxHeight:.infinity)
        }
        .foregroundStyle(.white)
        .onAppear { revealed = true }
        .accessibilityElement(children:.ignore).accessibilityLabel(event.label)
        .accessibilityValue(event.valueText)
    }
}

private struct PercentageLabel: View {
    let value: Int?
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        ZStack(alignment:.trailing) {
            HStack(spacing:0) {
                // Reserve three actual digit advances so the suffix and track stay put at 100%.
                Text(verbatim:"100").hidden().overlay(alignment:.trailing) {
                    if let value { RollingNumber(value:value) }
                }.clipped()
                Text(verbatim:"%").opacity(value == nil ? 0 : 1)
            }
            if value == nil { Text("静音").transition(.opacity) }
        }
        .font(.system(size:11,weight:.semibold)).monospacedDigit()
        .lineLimit(1).fixedSize()
        .animation(IslandMotion.curve(reduced ? 0.12 : 0.18),value:value == nil)
    }
}

private struct RollingNumber: View {
    let value: Int
    @State private var shown: Int
    @State private var descending = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(value: Int) {
        self.value = value
        _shown = State(initialValue:value)
    }

    var body: some View {
        Text(verbatim:String(shown))
            .contentTransition(reduced ? .opacity : .numericText(countsDown:descending))
            .onChange(of:value) { next in
                withAnimation(IslandMotion.settle(0.32,reduced:reduced)) {
                    descending = next < shown
                    shown = next
                }
            }
    }
}

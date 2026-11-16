import SwiftUI

struct BatteryReadout: View {
    let notice: BatteryNotice

    private static func columns(for width: CGFloat) -> Int {
        max(1, Int((max(0, width) + 5) / 58))
    }

    static func contentHeight(parts: Int, width: CGFloat) -> CGFloat {
        guard parts > 1, width < 265 else { return 26 }
        let columns = columns(for: width)
        let rows = (parts + columns - 1) / columns
        return 14 + 18 * CGFloat(rows)
    }

    var body: some View {
        GeometryReader { bounds in
            if notice.parts.count <= 1 {
                single
            } else if bounds.size.width >= 265 {
                HStack(spacing: 8) {
                    identity
                    Spacer(minLength: 0)
                    ForEach(notice.parts, id: \.id) { part in
                        HStack(spacing: 3) {
                            ring(for: part, diameter: 23)
                            VStack(alignment: .leading, spacing: 0) {
                                percent(part)
                                Text(verbatim: part.label).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }.fixedSize()
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                let columns = Self.columns(for: bounds.size.width)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) { name; status }.frame(height: 13)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .leading),
                                             count: min(columns, notice.parts.count)),
                              alignment: .leading, spacing: 1) {
                        ForEach(notice.parts, id: \.id) { part in
                            HStack(spacing: 2) {
                                ring(for: part, diameter: 16)
                                Text(verbatim: part.label).font(.system(size: 9)).foregroundStyle(.secondary)
                                percent(part)
                            }.fixedSize().frame(height: 17)
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.device.name + " " + notice.kind.rawValue)
        .accessibilityValue(notice.parts.map { $0.label + percentage($0) }.joined(separator: "，"))
    }

    private var name: some View {
        Text(verbatim: notice.device.name)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1).truncationMode(.middle)
    }

    private var status: some View {
        Text(verbatim: notice.kind.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary).fixedSize()
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) { name; status }
    }

    private var single: some View {
        let part = notice.parts.first
        return HStack(spacing: 5) {
            ring(for: part, diameter: 24)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    name
                    if let part, !part.label.isEmpty {
                        Text(verbatim: part.label).font(.system(size: 10)).fixedSize()
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        if let part { percent(part) }
                        status
                    }.fixedSize()
                    if let part { percent(part) } else { status }
                }
            }
        }.frame(maxHeight: .infinity)
    }

    private func percentage(_ part: BatteryPart) -> String {
        part.percent.map { String($0) + "%" } ?? "—"
    }

    private func percent(_ part: BatteryPart) -> some View {
        Text(verbatim: percentage(part)).font(.system(size: 10, weight: .semibold)).monospacedDigit().fixedSize()
    }

    private func ring(for part: BatteryPart?, diameter: CGFloat) -> some View {
        BatteryRing(symbol: notice.device.symbol(for: part), percent: part?.percent, diameter: diameter)
    }
}

private struct BatteryRing: View {
    let symbol: String
    let percent: Int?
    let diameter: CGFloat
    @State private var displayed: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduced

    private var tint: Color {
        guard let percent else { return .gray }
        switch percent {
        case 0...10: return Color(red: 1, green: 0.27, blue: 0.27)
        case 11...20: return Color(red: 1, green: 0.72, blue: 0.19)
        default: return Color(red: 0.32, green: 0.89, blue: 0.47)
        }
    }

    var body: some View {
        let weight = diameter < 20 ? 1.6 : 2.2
        ZStack {
            Circle().strokeBorder(percent == nil ? Color.white.opacity(0.28) : tint.opacity(0.26), lineWidth: weight)
            if percent != nil {
                Circle().inset(by: weight / 2)
                    .trim(from: 0, to: displayed)
                    .stroke(tint, style: StrokeStyle(lineWidth: weight, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol)
                .resizable().scaledToFit()
                .frame(width: diameter * 0.53, height: diameter * 0.53)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .onAppear { draw() }
        .onChange(of: percent) { _ in draw() }
    }

    private func draw() {
        let target = CGFloat(percent ?? 0) / 100
        withAnimation(reduced ? nil : .timingCurve(0.22, 0.68, 0.30, 1, duration: 0.62)) {
            displayed = target
        }
    }
}

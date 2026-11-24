import SwiftUI

/// The project's loudness over time, with the parts that will be cut shaded.
struct WaveformView: View {
    let levels: [Float]
    let removed: [ClosedRange<Double>]
    let thresholdDB: Double?

    private let floorDB: Double = -60

    /// Bar height for a level: 0 at -60 dB, 1 at 0 dB, curved so room tone stays small and
    /// speech stands out.
    private func height(_ dB: Double) -> Double { pow(min(1, max(0, (dB - floorDB) / -floorDB)), 1.5) }

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let barWidth = size.width / CGFloat(levels.count)

            for range in removed {
                let x0 = CGFloat(range.lowerBound) * size.width
                let x1 = CGFloat(range.upperBound) * size.width
                let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                context.fill(Path(rect), with: .color(.red.opacity(0.22)))
            }

            var kept = Path(), cut = Path()
            for (index, level) in levels.enumerated() {
                let h = max(1, CGFloat(height(Double(level))) * (size.height - 2))
                let rect = CGRect(x: CGFloat(index) * barWidth, y: (size.height - h) / 2, width: max(0.5, barWidth), height: h)
                let position = (Double(index) + 0.5) / Double(levels.count)
                if removed.contains(where: { $0.contains(position) }) { cut.addRect(rect) } else { kept.addRect(rect) }
            }
            context.fill(kept, with: .color(.accentColor))
            context.fill(cut, with: .color(.red.opacity(0.75)))

            if let thresholdDB {
                let h = CGFloat(height(thresholdDB)) * (size.height - 2)
                var line = Path()
                for y in [(size.height - h) / 2, (size.height + h) / 2] {
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(line, with: .color(.primary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Audio waveform. Red areas will be removed.")
    }
}

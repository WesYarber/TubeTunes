import SwiftUI

enum SegmentEdge { case start, end }

/// Waveform of the whole video with draggable track boundaries.
struct WaveformTimeline: View {
    let envelope: [Float]
    /// Loudness range to draw, from quiet floor to near-peak (dB).
    let range: ClosedRange<Float>
    let duration: Double
    /// The part of the video currently on screen (zoom/scroll).
    let visible: ClosedRange<Double>
    let segments: [Segment]
    let chapters: [Chapter]
    let selection: UUID?
    let playhead: Double
    var onSeek: (Double) -> Void
    var onSelect: (UUID?) -> Void
    var onMoveEdge: (UUID, SegmentEdge, Double) -> Void

    @State private var hoveringHandle = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let span = max(0.001, visible.upperBound - visible.lowerBound)
            let pps = w / span
            let x = { (t: Double) in (t - visible.lowerBound) * pps }

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(nsColor: .controlBackgroundColor))

                ForEach(segments) { seg in
                    segmentBox(seg, x0: x(seg.start), pps: pps, height: h)
                }

                waveform.frame(width: w, height: h).allowsHitTesting(false)

                ForEach(chapters, id: \.start) { ch in
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: x(ch.start))
                        .help(ch.title)
                }

                Rectangle().fill(Color.red)
                    .frame(width: 1.5, height: h)
                    .offset(x: x(playhead))
                    .allowsHitTesting(false)

                ForEach(segments) { seg in
                    if visible.contains(seg.start) {
                        handle(seg, edge: .start, x: x(seg.start), pps: pps, height: h)
                    }
                    if visible.contains(seg.end) {
                        handle(seg, edge: .end, x: x(seg.end), pps: pps, height: h)
                    }
                }
            }
            .clipped()
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .onTapGesture { location in
                let t = visible.lowerBound + location.x / pps
                onSeek(t)
                onSelect(segments.first { $0.start <= t && t <= $0.end }?.id)
            }
        }
    }

    private var waveform: some View {
        Canvas { ctx, size in
            // `visible` and `duration` are read inside so the canvas redraws on zoom/scroll.
            guard !envelope.isEmpty else { return }
            let columns = max(1, Int(size.width / 2))
            let mid = size.height / 2
            let rate = Double(envelope.count) / max(1, duration)
            let first = visible.lowerBound * rate
            let perColumn = (visible.upperBound - visible.lowerBound) * rate / Double(columns)
            var path = Path()
            for c in 0..<columns {
                let a = max(0, Int(first + Double(c) * perColumn))
                let b = max(a + 1, Int(first + Double(c + 1) * perColumn))
                guard a < envelope.count else { break }
                var peak: Float = -90
                for i in a..<min(b, envelope.count) { peak = max(peak, envelope[i]) }
                let span = max(6, range.upperBound - range.lowerBound)
                let v = CGFloat(max(0, min(1, (peak - range.lowerBound) / span)))
                let bar = max(1, v * size.height * 0.92)
                path.addRect(CGRect(x: CGFloat(c) * 2, y: mid - bar / 2, width: 1.3, height: bar))
            }
            ctx.fill(path, with: .color(.secondary.opacity(0.85)))
        }
    }

    @ViewBuilder
    private func segmentBox(_ seg: Segment, x0: Double, pps: Double, height: CGFloat) -> some View {
        let width = max(1, seg.duration * pps)
        let selected = seg.id == selection
        let tint: Color = seg.included ? .accentColor : .gray
        ZStack(alignment: .topLeading) {
            Rectangle().fill(tint.opacity(selected ? 0.30 : 0.13))
            // Fade ramps: the shaded corner is the attenuated part.
            Path { p in
                let fi = min(seg.fadeIn, seg.duration / 2) * pps
                let fo = min(seg.fadeOut, seg.duration / 2) * pps
                if fi > 0 {
                    p.move(to: .zero); p.addLine(to: CGPoint(x: fi, y: 0)); p.addLine(to: CGPoint(x: 0, y: height)); p.closeSubpath()
                }
                if fo > 0 {
                    p.move(to: CGPoint(x: width, y: 0)); p.addLine(to: CGPoint(x: width - fo, y: 0))
                    p.addLine(to: CGPoint(x: width, y: height)); p.closeSubpath()
                }
            }
            .fill(Color.black.opacity(0.22))
            Text(seg.title)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.top, 3)
                .frame(maxWidth: max(0, width), alignment: .leading)
                .opacity(width > 30 ? 1 : 0)
        }
        .frame(width: width, height: height)
        .offset(x: x0)
        .allowsHitTesting(false)
    }

    private func handle(_ seg: Segment, edge: SegmentEdge, x: Double, pps: Double, height: CGFloat) -> some View {
        let selected = seg.id == selection
        return Rectangle()
            .fill(seg.included ? Color.accentColor.opacity(selected ? 1 : 0.55) : Color.gray)
            .frame(width: selected ? 3 : 2, height: height)
            .frame(width: 13)
            .contentShape(Rectangle())
            .offset(x: x - 6.5)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        guard pps > 0 else { return }
                        onSelect(seg.id)
                        onMoveEdge(seg.id, edge, visible.lowerBound + v.location.x / pps)
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

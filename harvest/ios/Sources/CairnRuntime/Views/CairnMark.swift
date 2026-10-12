import SwiftUI

/// The Cairn logo: a dashboard gauge arc with a navigation-arrow needle. Drawn in SwiftUI so it
/// stays sharp at any size; matches the app icon.
struct CairnMark: View {
    /// Icon background, for placing the mark on a tile.
    static let tile = RadialGradient(
        colors: [Color(red: 0.18, green: 0.18, blue: 0.10), Color(red: 0.035, green: 0.04, blue: 0.016)],
        center: .center, startRadius: 0, endRadius: 40
    )

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }

            // Gauge arc, open at the bottom.
            var ring = Path()
            ring.addArc(center: point(0.5, 0.527), radius: 0.332 * s, startAngle: .degrees(140), endAngle: .degrees(400), clockwise: false)
            context.stroke(
                ring,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.765, blue: 1.0), Color(red: 0, green: 0.678, blue: 1.0)]),
                    startPoint: point(0.1, 0.5), endPoint: point(0.9, 0.5)
                ),
                style: StrokeStyle(lineWidth: 0.102 * s, lineCap: .round)
            )

            // Needle: navigation arrowhead tilted 38 degrees, two facets.
            let tilt = 38.0 * .pi / 180
            func arrow(_ x: Double, _ y: Double) -> CGPoint {
                let k = 0.21
                let xr = x * cos(tilt) - y * sin(tilt)
                let yr = x * sin(tilt) + y * cos(tilt)
                return point(0.5 + xr * k, 0.508 + yr * k)
            }
            let tip = arrow(0, -1), right = arrow(0.72, 0.92), notch = arrow(0, 0.46), left = arrow(-0.72, 0.92)
            let joinStyle = StrokeStyle(lineWidth: 0.018 * s, lineCap: .round, lineJoin: .round)
            for (corner, color) in [(left, Color(red: 0.98, green: 0.98, blue: 0.88)), (right, Color.white)] {
                var facet = Path()
                facet.move(to: tip)
                facet.addLine(to: corner)
                facet.addLine(to: notch)
                facet.closeSubpath()
                context.fill(facet, with: .color(color))
                context.stroke(facet, with: .color(color), style: joinStyle) // rounds the corners slightly
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview {
    CairnMark().frame(width: 160, height: 160).padding().background(CairnMark.tile)
}

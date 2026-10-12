import CairnCore
import MapKit
import os
import SwiftUI

/// A small map of where a trip went. Until the map is drawn (it needs the network for tiles), and where it
/// cannot be, the route sketch stands in, so a card is never blank.
struct TripMapThumbnail: View {
    let summary: TripSummary
    static let side: CGFloat = 92

    #if os(iOS)
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    #endif

    var body: some View {
        ZStack {
            RouteSketch(summary: summary, side: Self.side)
            #if os(iOS)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
            #endif
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityHidden(true)
        #if os(iOS)
        .task(id: "\(summary.id)|\(summary.routeRuns.count)|\(colorScheme == .dark)") {
            let drawn = await TripMapSnapshots.shared.image(for: summary, side: Self.side, scale: displayScale, dark: colorScheme == .dark)
            withAnimation(.easeIn(duration: 0.2)) { image = drawn }
        }
        #endif
    }
}

#if os(iOS)
/// Draws and remembers the thumbnails. One snapshot per trip and appearance, however often a row scrolls into view.
@MainActor
final class TripMapSnapshots {
    static let shared = TripMapSnapshots()
    private nonisolated static var log: Logger { Logger(subsystem: "app.cairn.companion", category: "trip-map") }
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for summary: TripSummary, side: CGFloat, scale: CGFloat, dark: Bool) async -> UIImage? {
        let points = summary.routeRuns.flatMap { $0 }
        guard points.count >= 2 else { return nil }
        let key = "\(summary.id)|\(points.count)|\(dark)|\(side)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let task = Task { [runs = summary.routeRuns] () -> UIImage? in
            let drawn = await Self.render(runs: runs, side: side, scale: scale, dark: dark)
            return drawn
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { cache.setObject(result, forKey: key as NSString) }
        return result
    }

    private static func render(runs: [[RoutePoint]], side: CGFloat, scale: CGFloat, dark: Bool) async -> UIImage? {
        let all = runs.flatMap { $0 }
        guard let minLat = all.map(\.latitude).min(), let maxLat = all.map(\.latitude).max(),
              let minLon = all.map(\.longitude).min(), let maxLon = all.map(\.longitude).max() else { return nil }

        let options = MKMapSnapshotter.Options()
        // pad the route so its ends are not cut by the corner, with a floor so a short trip is not a close-up of a driveway
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.5, 0.004), longitudeDelta: max((maxLon - minLon) * 1.5, 0.004))
        )
        options.size = CGSize(width: side, height: side)
        options.scale = scale
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            // offline, or no tiles for the area: the card keeps its sketch
            Self.log.notice("map snapshot failed: \(error.localizedDescription)")
            return nil
        }
        return UIGraphicsImageRenderer(size: snapshot.image.size).image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            let path = UIBezierPath()
            for run in runs where run.count >= 2 {
                for (i, p) in run.enumerated() {
                    let point = snapshot.point(for: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            // a pale edge first, so the route reads over roads of any colour
            UIColor.white.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            UIColor.systemBlue.setStroke()
            path.lineWidth = 3
            path.stroke()

            func dot(_ p: RoutePoint, _ color: UIColor) {
                let c = snapshot.point(for: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
                let r: CGFloat = 4.5
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: c.x - r - 1.5, y: c.y - r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2)).fill()
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            }
            if let first = runs.first?.first { dot(first, .systemGreen) }
            if let last = runs.last?.last { dot(last, .systemRed) }
        }
    }
}
#endif

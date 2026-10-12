import CairnCore
import SwiftUI

// MARK: - Tone

enum Tone {
    case neutral, good, warn, bad

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: .green
        case .warn: .orange
        case .bad: .red
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var symbol: String?
    var badge: Badge?
    var accentBorder: Bool = false
    @ViewBuilder var content: Content

    init(
        title: String? = nil, subtitle: String? = nil, symbol: String? = nil,
        badge: Badge? = nil, accentBorder: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.badge = badge
        self.accentBorder = accentBorder
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let badge { badge }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accentBorder ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06))
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

// MARK: - Badge

struct Badge: View {
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tone.color.opacity(0.14), in: Capsule())
        .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
        .accessibilityElement(children: .combine)
    }

    static func heard(_ lastHeard: Date?, connected: Bool, now: Date) -> Badge? {
        guard let lastHeard else { return nil }
        let age = LinkHealth.ageLabel(now.timeIntervalSince(lastHeard))
        if !connected { return Badge(text: "As of \(age) ago", tone: .bad) }
        switch LinkHealth.freshness(lastHeard: lastHeard, now: now) {
        case .live: return Badge(text: "Live", tone: .good)
        case .stale: return Badge(text: "Heard \(age) ago", tone: .warn)
        case .silent: return Badge(text: "Silent \(age)", tone: .bad)
        case .never: return nil
        }
    }
}

struct BadgePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

// MARK: - MetricGrid & Metric

struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            content
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    var unit: String?
    var tone: Tone = .neutral

    init(_ label: String, _ value: String, unit: String? = nil, tone: Tone = .neutral) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tone = tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let unit {
                    Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.tileSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Placeholder

struct Placeholder: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
    }
}

// MARK: - Backdrop

struct Backdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.pageSurface
            RadialGradient(
                colors: [Color.accentColor.opacity(0.18), .clear],
                center: .top, startRadius: 0, endRadius: 360
            )
        }
    }
}

// MARK: - Surface colors

extension Color {
    #if canImport(UIKit)
    static let pageSurface = Color(.systemGroupedBackground)
    static let cardSurface = Color(.secondarySystemGroupedBackground)
    static let tileSurface = Color(.tertiarySystemGroupedBackground)
    #else
    static let pageSurface = Color(nsColor: .windowBackgroundColor)
    static let cardSurface = Color(nsColor: .controlBackgroundColor)
    static let tileSurface = Color(nsColor: .underPageBackgroundColor)
    #endif
}

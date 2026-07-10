//
//  TideItWidget.swift
//  TideItWidget
//
//  Widget marées — Home Screen (Small & Medium) + Lock Screen / Watch complications
//

import WidgetKit
import SwiftUI

// MARK: - Design System

private enum WT {
    static let bg          = Color("WidgetBackground")
    static let surface     = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.04)
    })
    static let text1       = Color.primary
    static let text2       = Color.secondary
    static let text3       = Color(UIColor.tertiaryLabel)
    static let high        = Color.cyan
    static let low         = Color.purple
    static let mid         = Color.blue
    static let separator   = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)
    })
}

// MARK: - Timeline Entry

struct TideEntry: TimelineEntry {
    let date: Date
    let data: WidgetSharedData?
}

// MARK: - Timeline Provider

struct TideProvider: TimelineProvider {

    func placeholder(in context: Context) -> TideEntry {
        TideEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TideEntry) -> Void) {
        completion(TideEntry(date: Date(), data: loadSharedData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TideEntry>) -> Void) {
        let rawData = loadSharedData()
        let now = Date()
        var entries: [TideEntry] = []

        // 48 entrées × 10min = 8h de couverture, refresh toutes les 3h
        let intervalMinutes = 10
        let totalEntries = 48
        for i in 0..<totalEntries {
            let entryDate = Calendar.current.date(byAdding: .minute, value: i * intervalMinutes, to: now)
                ?? now.addingTimeInterval(Double(i * intervalMinutes * 60))
            // Résolution autonome : chaque entrée résout sa propre paire de marées
            let resolved: WidgetSharedData?
            if let d = rawData {
                resolved = resolvedSharedData(from: d, at: entryDate)
            } else {
                resolved = nil
            }
            entries.append(TideEntry(date: entryDate, data: resolved))
        }

        let refreshDate = Calendar.current.date(byAdding: .hour, value: 3, to: now)
            ?? now.addingTimeInterval(3 * 3600)
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    private func loadSharedData() -> WidgetSharedData? {
        guard let defaults = WidgetSharedKeys.sharedDefaults,
              let encoded = defaults.data(forKey: WidgetSharedKeys.dataKey),
              let data = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded)
        else { return nil }
        return data
    }
}

// MARK: - Shared Helpers

private func tideColor(isHigh: Bool) -> Color {
    isHigh ? WT.high : WT.low
}

private func coeffColor(_ coef: Int) -> Color {
    switch coef {
    case ..<45:   return .green
    case 45..<70: return .yellow
    case 70..<95: return .orange
    default:      return .red
    }
}

/// Best available coefficient: todayCoef > nextTideCoef > secondTideCoef
private func bestCoef(from data: WidgetSharedData) -> Int? {
    data.todayCoef ?? data.nextTideCoef ?? data.secondTideCoef
}

/// Interpolation cosinus de la hauteur à un instant donné (Rule of Twelfths)
/// Permet au widget de recalculer la hauteur sans dépendre de l'app
private func interpolatedHeight(from data: WidgetSharedData, at date: Date) -> Double {
    guard let prevDate = data.previousTideDate,
          let prevHeight = data.previousTideHeight else {
        return data.currentHeight // fallback: dernière valeur connue
    }

    let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
    guard totalDuration > 0 else { return data.currentHeight }

    let elapsed = date.timeIntervalSince(prevDate)
    let fraction = min(max(elapsed / totalDuration, 0), 1)

    // Interpolation cosinus
    let cosineProgress = (1 - cos(fraction * .pi)) / 2
    return prevHeight + (data.nextTideHeight - prevHeight) * cosineProgress
}

/// Phrase lisible par VoiceOver — évite que le lecteur d'écran lise des fragments
/// décousus ("Arcachon", "PM", "14:32", "3,5 m") en construisant une vraie phrase.
private func accessibilityDescription(for data: WidgetSharedData, liveHeight: Double) -> String {
    let trend = data.nextTideIsHigh ? String(localized: "marée montante") : String(localized: "marée descendante")
    let nextType = data.nextTideIsHigh ? String(localized: "pleine mer") : String(localized: "basse mer")
    let nextTime = formatTideTime(data.nextTideDate, in: data.timeZone)
    var parts = [
        "\(data.portName).",
        "\(SharedUnitFormatter.height(liveHeight)), \(trend).",
        String(localized: "Prochaine \(nextType) à \(nextTime).")
    ]
    if let c = bestCoef(from: data) {
        parts.append("Coefficient \(c).")
    }
    return parts.joined(separator: " ")
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - iOS ONLY — Home Screen Widgets (Small & Medium)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#if os(iOS)

// MARK: Entry View (Home Screen dispatch)

struct TideItWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TideProvider.Entry

    var body: some View {
        Group {
            if let data = entry.data, !data.portName.isEmpty {
                let liveHeight = interpolatedHeight(from: data, at: entry.date)
                switch family {
                case .systemMedium:
                    MediumTideView(data: data, liveHeight: liveHeight, entryDate: entry.date)
                default:
                    SmallTideView(data: data, liveHeight: liveHeight, entryDate: entry.date)
                }
            } else {
                EmptyWidgetView()
            }
        }
    }
}

// MARK: - SMALL WIDGET

struct SmallTideView: View {
    let data: WidgetSharedData
    var liveHeight: Double = 0
    var entryDate: Date = Date()

    private var isRising: Bool { data.nextTideIsHigh }
    private var trendColor: Color { isRising ? WT.high : WT.low }
    private var nextColor: Color { tideColor(isHigh: data.nextTideIsHigh) }

    private var tideProgress: Double {
        guard let prevDate = data.previousTideDate else {
            let cycleDuration: TimeInterval = 6 * 3600 + 12 * 60
            let timeToNext = data.nextTideDate.timeIntervalSince(entryDate)
            let elapsed = cycleDuration - timeToNext
            return min(max(elapsed / cycleDuration, 0), 1)
        }
        let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
        guard totalDuration > 0 else { return 0 }
        let elapsed = entryDate.timeIntervalSince(prevDate)
        return min(max(elapsed / totalDuration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "water.waves")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(WT.text3)
                Text(data.portName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WT.text3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 4)

            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(trendColor.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: isRising ? "arrow.up" : "arrow.down")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(trendColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(SharedUnitFormatter.height(liveHeight))
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(WT.text1)
                    Text(isRising ? "Montante" : "Descendante")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(trendColor)
                }

                Spacer(minLength: 0)

                if let c = bestCoef(from: data) {
                    VStack(spacing: 1) {
                        Text("\(c)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(coeffColor(c))
                        Text("coef")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(WT.text3)
                    }
                }
            }

            Spacer(minLength: 6)

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(WT.surface).frame(height: 4)
                        Capsule()
                            .fill(LinearGradient(
                                colors: isRising ? [WT.low, WT.high] : [WT.high, WT.low],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: geo.size.width * tideProgress, height: 4)
                    }
                }
                .frame(height: 4)

                HStack(spacing: 0) {
                    Image(systemName: data.nextTideIsHigh ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(nextColor)
                    Text(data.nextTideIsHigh ? " PM " : " BM ")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(nextColor)
                    Text(data.nextTideDate, style: .relative)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(WT.text1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text(formatTideTime(data.nextTideDate, in: data.timeZone))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(WT.text2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .containerBackground(for: .widget) {
            ContainerRelativeShape().fill(Color("WidgetBackground"))
        }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(for: data, liveHeight: liveHeight))
    }
}

// MARK: - MEDIUM WIDGET

struct MediumTideView: View {
    let data: WidgetSharedData
    var liveHeight: Double = 0
    var entryDate: Date = Date()

    private var isRising: Bool { data.nextTideIsHigh }
    private var trendColor: Color { isRising ? WT.high : WT.low }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "water.waves")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WT.text3)
                    Text(data.portName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(WT.text3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 4)

                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(trendColor.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: isRising ? "arrow.up" : "arrow.down")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(trendColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(SharedUnitFormatter.height(liveHeight))
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(WT.text1)
                        Text(isRising ? "Montante" : "Descendante")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(trendColor)
                    }
                }

                Spacer(minLength: 4)

                if let c = bestCoef(from: data) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(coeffColor(c))
                        Text("Coef")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(WT.text2)
                        Text("\(c)")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(coeffColor(c))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(coeffColor(c).opacity(0.12))
                            .overlay(Capsule().stroke(coeffColor(c).opacity(0.3), lineWidth: 0.5))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(WT.separator).frame(width: 1).padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 0) {
                TideRow(label: "PROCHAINE", date: data.nextTideDate,
                        height: data.nextTideHeight, isHigh: data.nextTideIsHigh, isPrimary: true,
                        timeZone: data.timeZone)

                Spacer(minLength: 4)

                GeometryReader { geo in
                    let progress = nextTideProgress()
                    ZStack(alignment: .leading) {
                        Capsule().fill(WT.surface).frame(height: 3)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [trendColor, tideColor(isHigh: data.nextTideIsHigh)],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                }
                .frame(height: 3)

                Spacer(minLength: 4)

                if let d2 = data.secondTideDate,
                   let h2 = data.secondTideHeight,
                   let high2 = data.secondTideIsHigh {
                    TideRow(label: "SUIVANTE", date: d2, height: h2, isHigh: high2, isPrimary: false,
                            timeZone: data.timeZone)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .containerBackground(for: .widget) {
            ContainerRelativeShape().fill(Color("WidgetBackground"))
        }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(for: data, liveHeight: liveHeight))
    }

    private func nextTideProgress() -> Double {
        guard let prevDate = data.previousTideDate else {
            let cycleDuration: TimeInterval = 6 * 3600 + 12 * 60
            let timeToNext = data.nextTideDate.timeIntervalSince(entryDate)
            let elapsed = cycleDuration - timeToNext
            return min(max(elapsed / cycleDuration, 0), 1)
        }
        let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
        guard totalDuration > 0 else { return 0 }
        let elapsed = entryDate.timeIntervalSince(prevDate)
        return min(max(elapsed / totalDuration, 0), 1)
    }
}

// MARK: - Tide Row (medium widget)

private struct TideRow: View {
    let label: String
    let date: Date
    let height: Double
    let isHigh: Bool
    let isPrimary: Bool
    var timeZone: TimeZone = .current

    private var accent: Color { tideColor(isHigh: isHigh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(WT.text3)
                .tracking(0.5)

            HStack(spacing: 4) {
                Image(systemName: isHigh ? "arrow.up" : "arrow.down")
                    .font(.system(size: isPrimary ? 14 : 10, weight: .heavy))
                    .foregroundStyle(accent)
                Text(isHigh ? "PM" : "BM")
                    .font(.system(size: isPrimary ? 13 : 10, weight: .heavy))
                    .foregroundStyle(accent)
                Text(date, style: .relative)
                    .font(.system(size: isPrimary ? 15 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isPrimary ? WT.text1 : WT.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(spacing: 6) {
                Text(formatTideTime(date, in: timeZone))
                    .font(.system(size: isPrimary ? 12 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(WT.text2)
                Text("•").foregroundStyle(WT.text3)
                Text(SharedUnitFormatter.height(height, decimals: 2))
                    .font(.system(size: isPrimary ? 12 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(WT.text2)
            }
        }
    }
}

// MARK: - Empty Widget View (iOS only)

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "water.waves")
                .font(.system(size: 26))
                .foregroundStyle(
                    LinearGradient(
                        colors: [WT.high.opacity(0.7), WT.low.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("Ouvrez Tide It")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(WT.text2)
            Text("Pour voir vos marées")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(WT.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            ContainerRelativeShape().fill(Color("WidgetBackground"))
        }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ouvrez Tide It sur votre iPhone pour voir vos marées")
    }
}

// MARK: - Home Screen Widget Configuration (iOS only)

struct TideItWidget: Widget {
    let kind = "TideItWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TideProvider()) { entry in
            TideItWidgetEntryView(entry: entry)
                .unredacted()
        }
        .configurationDisplayName("Marées")
        .description("Marée en cours, prochaine et suivante")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - WIND WIDGET (vent observé temps réel — balise la plus proche)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private let windAccent = Color.teal

/// Force Beaufort (0-12) à partir d'une vitesse moyenne en km/h.
private func beaufort(fromKmh kmh: Double) -> Int {
    switch kmh {
    case ..<1: return 0; case ..<6: return 1; case ..<12: return 2; case ..<20: return 3
    case ..<29: return 4; case ..<39: return 5; case ..<50: return 6; case ..<62: return 7
    case ..<75: return 8; case ..<89: return 9; case ..<103: return 10; case ..<118: return 11
    default: return 12
    }
}

private func windAgeLabel(_ date: Date?, now: Date) -> String? {
    guard let date else { return nil }
    let mins = max(0, Int(now.timeIntervalSince(date) / 60))
    if mins < 1 { return "à l'instant" }
    if mins < 60 { return "il y a \(mins) min" }
    return "il y a \(mins / 60)h\(String(format: "%02d", mins % 60))"
}

struct WindWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TideProvider.Entry

    var body: some View {
        Group {
            if let data = entry.data, data.realtimeWindLocked == true {
                WindLockedView()
            } else if let data = entry.data,
                      (data.observedWindKmh != nil && data.observedWindStation != nil) || data.forecastWindKmh != nil {
                // Balise réelle si dispo, sinon repli sur le vent prévu (jamais « aveugle »).
                switch family {
                case .systemMedium: MediumWindView(data: data, entryDate: entry.date)
                default:            SmallWindView(data: data, entryDate: entry.date)
                }
            } else {
                WindNoStationView(port: entry.data?.portName)
            }
        }
    }
}

// MARK: Small Wind+Tide (hybride)

struct SmallWindView: View {
    let data: WidgetSharedData
    var entryDate: Date = Date()

    var body: some View {
        // Repli sur le vent PRÉVU si pas de balise observée → le widget n'est jamais « aveugle ».
        let isForecast = data.observedWindKmh == nil
        let speed = data.observedWindKmh ?? data.forecastWindKmh ?? 0
        let dir = data.observedWindDirDeg ?? data.forecastWindDirDeg ?? 0
        let liveHeight = interpolatedHeight(from: data, at: entryDate)
        let isRising = data.nextTideIsHigh
        VStack(alignment: .leading, spacing: 0) {
            // En-tête : balise (réel) ou « Vent prévu »
            HStack(spacing: 4) {
                Image(systemName: isForecast ? "cloud.sun" : "wind").font(.system(size: 8, weight: .bold)).foregroundStyle(windAccent)
                Text(isForecast ? "Vent prévu" : (data.observedWindStation ?? data.portName))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(WT.text3).lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 3)
            // Vent
            HStack(spacing: 6) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(windAccent)
                    .rotationEffect(.degrees(dir + 180))
                Text(SharedUnitFormatter.windSpeed(speed))
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(WT.text1).lineLimit(1).minimumScaleFactor(0.7)
                Text(SharedUnitFormatter.windCardinal(dir))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(windAccent)
                Spacer(minLength: 0)
            }
            if let gust = data.observedWindGustKmh ?? data.forecastWindGustKmh {
                Text("rafales \(SharedUnitFormatter.windSpeed(gust))")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(WT.text2)
            }
            // Âge de la mesure balise (déjà affiché en Medium) : une mesure reportée
            // d'une écriture précédente doit dire son âge — jamais passer pour du direct.
            if let age = windAgeLabel(data.observedWindDate, now: entryDate) {
                Text(age).font(.system(size: 8, weight: .medium)).foregroundStyle(WT.text3)
            }
            Spacer(minLength: 5)
            Rectangle().fill(WT.separator).frame(height: 1)
            Spacer(minLength: 5)
            // Marée (prochaine)
            HStack(spacing: 5) {
                Image(systemName: isRising ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(tideColor(isHigh: isRising))
                Text(data.nextTideIsHigh ? "PM" : "BM")
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(tideColor(isHigh: isRising))
                Text(formatTideTime(data.nextTideDate, in: data.timeZone))
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(WT.text1)
                Spacer(minLength: 0)
                Text(SharedUnitFormatter.height(liveHeight))
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(WT.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
    }
}

// MARK: Medium Wind+Tide (hybride)

struct MediumWindView: View {
    let data: WidgetSharedData
    var entryDate: Date = Date()

    var body: some View {
        // Repli sur le vent PRÉVU si pas de balise observée → jamais « aveugle ».
        let isForecast = data.observedWindKmh == nil
        let speed = data.observedWindKmh ?? data.forecastWindKmh ?? 0
        let dir = data.observedWindDirDeg ?? data.forecastWindDirDeg ?? 0
        let liveHeight = interpolatedHeight(from: data, at: entryDate)
        let isRising = data.nextTideIsHigh
        HStack(spacing: 0) {
            // ─── Vent (gauche) ───
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: isForecast ? "cloud.sun" : "wind").font(.system(size: 8, weight: .bold)).foregroundStyle(windAccent)
                    Text(isForecast ? "Vent prévu" : (data.observedWindStation ?? "Vent observé"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(WT.text3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 4)
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle().fill(windAccent.opacity(0.15)).frame(width: 46, height: 46)
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(windAccent)
                            .rotationEffect(.degrees(dir + 180))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SharedUnitFormatter.windSpeed(speed))
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(WT.text1).lineLimit(1).minimumScaleFactor(0.7)
                        Text(SharedUnitFormatter.windCardinal(dir) + " · \(Int(dir.rounded()))°")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(windAccent)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if let gust = data.observedWindGustKmh ?? data.forecastWindGustKmh {
                        Label(SharedUnitFormatter.windSpeed(gust), systemImage: "wind")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(WT.text2)
                    }
                    Text("F\(beaufort(fromKmh: speed)) Bft")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(windAccent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(windAccent.opacity(0.15)))
                }
                if let age = windAgeLabel(data.observedWindDate, now: entryDate) {
                    Text(age).font(.system(size: 9, weight: .medium)).foregroundStyle(WT.text3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(WT.separator).frame(width: 1).padding(.vertical, 4)

            // ─── Marée (droite) ───
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "water.waves").font(.system(size: 8, weight: .bold)).foregroundStyle(WT.high)
                    Text("Marée").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(WT.text3)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 4)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: isRising ? "arrow.up" : "arrow.down")
                        .font(.system(size: 18, weight: .heavy)).foregroundStyle(tideColor(isHigh: isRising))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SharedUnitFormatter.height(liveHeight))
                            .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(WT.text1)
                        Text(isRising ? "Montante" : "Descendante")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(tideColor(isHigh: isRising))
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: data.nextTideIsHigh ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(tideColor(isHigh: data.nextTideIsHigh))
                    Text(data.nextTideIsHigh ? "PM" : "BM")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(tideColor(isHigh: data.nextTideIsHigh))
                    Text(formatTideTime(data.nextTideDate, in: data.timeZone))
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(WT.text1)
                    Spacer(minLength: 0)
                    if let c = bestCoef(from: data) {
                        Text("\(c)").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(coeffColor(c))
                    }
                }
                // Marée suivante (« puis … »)
                if let d2 = data.secondTideDate, let high2 = data.secondTideIsHigh {
                    HStack(spacing: 4) {
                        Text("puis").font(.system(size: 9, weight: .medium)).foregroundStyle(WT.text3)
                        Image(systemName: high2 ? "arrow.up" : "arrow.down")
                            .font(.system(size: 8, weight: .heavy)).foregroundStyle(tideColor(isHigh: high2))
                        Text(high2 ? "PM" : "BM").font(.system(size: 9, weight: .heavy)).foregroundStyle(tideColor(isHigh: high2))
                        Text(formatTideTime(d2, in: data.timeZone))
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(WT.text2)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                // Lever / coucher du soleil
                if let sr = data.sunrise, let ss = data.sunset {
                    HStack(spacing: 8) {
                        Label(formatTideTime(sr, in: data.timeZone), systemImage: "sunrise.fill")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                        Label(formatTideTime(ss, in: data.timeZone), systemImage: "sunset.fill")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.indigo)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
    }
}

// MARK: Locked (non-premium) + No station

struct WindLockedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wind").font(.system(size: 24)).foregroundStyle(windAccent)
            Text("Vent en temps réel")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(WT.text1)
            HStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                Text("Premium").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(WT.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetURL(URL(string: "tideit://paywall"))
    }
}

struct WindNoStationView: View {
    var port: String? = nil
    var body: some View {
        // État CALME (pas le message alarmant « Aucune balise à proximité ») : ce cas n'arrive que
        // transitoirement, le temps que la donnée vent (balise OU prévision) se charge dans le store
        // partagé. On montre un placeholder neutre — l'utilisateur ne voit plus de message d'erreur.
        VStack(spacing: 6) {
            Image(systemName: "wind").font(.system(size: 24)).foregroundStyle(windAccent.opacity(0.6))
            if let port, !port.isEmpty {
                Text(port)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(WT.text1).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text("—")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(WT.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetURL(URL(string: "tideit://open"))
    }
}

struct WindWidget: Widget {
    let kind = "TideWindWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TideProvider()) { entry in
            WindWidgetEntryView(entry: entry).unredacted()
        }
        .configurationDisplayName("Vent")
        .description("Vent observé en temps réel par la balise la plus proche du port suivi")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

#endif // os(iOS)

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LOCK SCREEN / WATCH COMPLICATIONS (all platforms)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// MARK: Entry View for Lock Screen / Watch

struct LockScreenEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TideProvider.Entry

    var body: some View {
        Group {
            if let rawData = entry.data, !rawData.portName.isEmpty {
                // Résolution autonome depuis allTides
                let data = resolvedSharedData(from: rawData, at: entry.date)
                let liveHeight = interpolatedHeight(from: data, at: entry.date)
                switch family {
                case .accessoryCircular:
                    CircularTideView(data: data, entryDate: entry.date)
                case .accessoryRectangular:
                    RectangularTideView(data: data, liveHeight: liveHeight, entryDate: entry.date)
                case .accessoryInline:
                    InlineTideView(data: data, liveHeight: liveHeight)
                default:
                    Text("—")
                }
            } else {
                switch family {
                case .accessoryCircular:
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: "water.waves")
                            .font(.system(size: 20))
                    }
                case .accessoryInline:
                    Text("Ouvrir Tide It")
                default:
                    VStack {
                        Image(systemName: "water.waves")
                        Text("Ouvrir Tide It")
                            .font(.caption2)
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "tideit://open"))
    }
}

// MARK: - Accessory Circular

private struct CircularTideView: View {
    let data: WidgetSharedData
    var entryDate: Date = Date()

    private var isRising: Bool { data.nextTideIsHigh }

    private var progress: Double {
        guard let prevDate = data.previousTideDate else {
            let cycleDuration: TimeInterval = 6 * 3600 + 12 * 60
            let timeToNext = data.nextTideDate.timeIntervalSince(entryDate)
            let elapsed = cycleDuration - timeToNext
            return min(max(elapsed / cycleDuration, 0), 1)
        }
        let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
        guard totalDuration > 0 else { return 0 }
        let elapsed = entryDate.timeIntervalSince(prevDate)
        return min(max(elapsed / totalDuration, 0), 1)
    }

    var body: some View {
        Gauge(value: progress) {
            Image(systemName: "water.waves")
        } currentValueLabel: {
            VStack(spacing: 0) {
                Image(systemName: isRising ? "arrow.up" : "arrow.down")
                    .font(.system(size: 14, weight: .heavy))

                if let c = bestCoef(from: data) {
                    Text("\(c)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                }
            }
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(for: data, liveHeight: data.currentHeight))
    }
}

// MARK: - Accessory Rectangular

private struct RectangularTideView: View {
    let data: WidgetSharedData
    var liveHeight: Double = 0
    var entryDate: Date = Date()

    private var isRising: Bool { data.nextTideIsHigh }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: isRising ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .heavy))

                Text(SharedUnitFormatter.height(liveHeight))
                    .font(.system(size: 14, weight: .heavy, design: .rounded))

                Spacer(minLength: 0)

                if let c = bestCoef(from: data) {
                    Text("C\(c)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                }
            }

            HStack(spacing: 3) {
                Image(systemName: data.nextTideIsHigh ? "arrow.up" : "arrow.down")
                    .font(.system(size: 8, weight: .bold))

                Text(data.nextTideIsHigh ? "PM" : "BM")
                    .font(.system(size: 10, weight: .bold))

                Text(data.nextTideDate, style: .relative)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(formatTideTime(data.nextTideDate, in: data.timeZone))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let progress = tideProgress()
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                        .frame(height: 3)
                    Capsule()
                        .fill(.primary)
                        .frame(width: geo.size.width * progress, height: 3)
                }
            }
            .frame(height: 3)
        }
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(for: data, liveHeight: liveHeight))
    }

    private func tideProgress() -> Double {
        guard let prevDate = data.previousTideDate else {
            let cycleDuration: TimeInterval = 6 * 3600 + 12 * 60
            let timeToNext = data.nextTideDate.timeIntervalSince(entryDate)
            let elapsed = cycleDuration - timeToNext
            return min(max(elapsed / cycleDuration, 0), 1)
        }
        let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
        guard totalDuration > 0 else { return 0 }
        let elapsed = entryDate.timeIntervalSince(prevDate)
        return min(max(elapsed / totalDuration, 0), 1)
    }
}

// MARK: - Accessory Inline

private struct InlineTideView: View {
    let data: WidgetSharedData
    var liveHeight: Double = 0

    private var isRising: Bool { data.nextTideIsHigh }

    var body: some View {
        let arrow = isRising ? "↑" : "↓"
        let height = SharedUnitFormatter.height(liveHeight)
        let tide = data.nextTideIsHigh ? String(localized: "PM") : String(localized: "BM")
        let time = formatTideTime(data.nextTideDate, in: data.timeZone)

        Group {
            if let c = bestCoef(from: data) {
                ViewThatFits {
                    Text("\(arrow)\(height) • C\(c) • \(tide) \(time)")
                    Text("\(arrow)\(height) C\(c) \(tide) \(time)")
                    Text("\(arrow)\(height) C\(c)")
                }
            } else {
                Text("\(arrow)\(height) • \(tide) \(time)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(for: data, liveHeight: liveHeight))
    }
}

// MARK: - Lock Screen / Watch Widget Configuration (all platforms)

struct TideLockScreenWidget: Widget {
    let kind = "TideLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TideProvider()) { entry in
            LockScreenEntryView(entry: entry)
        }
        .configurationDisplayName("Marées – Écran")
        .description("Complication marée pour l'écran de verrouillage, StandBy et Apple Watch")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Previews
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private let previewData: WidgetSharedData = {
    let prevDate = Date().addingTimeInterval(-2 * 3600)
    let nextDate = Date().addingTimeInterval(4 * 3600 + 31 * 60)
    let secondDate = Date().addingTimeInterval(10 * 3600 + 45 * 60)
    let tides = [
        SimpleTide(date: prevDate, height: 0.45, isHigh: false, coefficient: nil),
        SimpleTide(date: nextDate, height: 3.50, isHigh: true, coefficient: 52),
        SimpleTide(date: secondDate, height: 0.82, isHigh: false, coefficient: 48),
    ]
    return WidgetSharedData(
        portName: "Arcachon Eyrac",
        nextTideDate: nextDate,
        nextTideHeight: 3.50,
        nextTideIsHigh: true,
        nextTideCoef: 52,
        currentHeight: 1.72,
        trend: "Montante",
        updatedAt: Date(),
        todayCoef: 52,
        previousTideDate: prevDate,
        previousTideHeight: 0.45,
        secondTideDate: secondDate,
        secondTideHeight: 0.82,
        secondTideIsHigh: false,
        secondTideCoef: 48,
        allTides: tides
    )
}()

private let previewDataBM: WidgetSharedData = {
    let prevDate = Date().addingTimeInterval(-4 * 3600)
    let nextDate = Date().addingTimeInterval(2 * 3600 + 15 * 60)
    let secondDate = Date().addingTimeInterval(8 * 3600 + 30 * 60)
    let tides = [
        SimpleTide(date: prevDate, height: 10.20, isHigh: true, coefficient: 87),
        SimpleTide(date: nextDate, height: 1.10, isHigh: false, coefficient: nil),
        SimpleTide(date: secondDate, height: 10.20, isHigh: true, coefficient: 87),
    ]
    return WidgetSharedData(
        portName: "Saint-Malo",
        nextTideDate: nextDate,
        nextTideHeight: 1.10,
        nextTideIsHigh: false,
        nextTideCoef: nil,
        currentHeight: 5.40,
        trend: "Descendante",
        updatedAt: Date(),
        todayCoef: 87,
        previousTideDate: prevDate,
        previousTideHeight: 10.20,
        secondTideDate: secondDate,
        secondTideHeight: 10.20,
        secondTideIsHigh: true,
        secondTideCoef: 87,
        allTides: tides
    )
}()

// Home Screen (iOS only)
#if os(iOS)
#Preview("Small", as: .systemSmall) {
    TideItWidget()
} timeline: {
    TideEntry(date: Date(), data: previewData)
}

#Preview("Medium", as: .systemMedium) {
    TideItWidget()
} timeline: {
    TideEntry(date: Date(), data: previewData)
}

#Preview("Small BM", as: .systemSmall) {
    TideItWidget()
} timeline: {
    TideEntry(date: Date(), data: previewDataBM)
}

#Preview("Empty", as: .systemSmall) {
    TideItWidget()
} timeline: {
    TideEntry(date: Date(), data: nil)
}
#endif

// Lock Screen / Watch (all platforms)
#Preview("Circular", as: .accessoryCircular) {
    TideLockScreenWidget()
} timeline: {
    TideEntry(date: Date(), data: previewData)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    TideLockScreenWidget()
} timeline: {
    TideEntry(date: Date(), data: previewData)
}

#Preview("Inline", as: .accessoryInline) {
    TideLockScreenWidget()
} timeline: {
    TideEntry(date: Date(), data: previewData)
}

#Preview("Circular BM", as: .accessoryCircular) {
    TideLockScreenWidget()
} timeline: {
    TideEntry(date: Date(), data: previewDataBM)
}

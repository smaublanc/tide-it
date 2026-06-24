//
//  TideWatchComplication.swift
//  TideWatchWidget
//
//  Complications Apple Watch — Corner, Circular, Rectangular, Inline
//  Résolution autonome via allTides pour fonctionner sans iPhone
//

import WidgetKit
import SwiftUI

// MARK: - Design Tokens

private enum WC {
    static let high     = Color.cyan
    static let low      = Color.purple
    static let mid      = Color.blue
}

// MARK: - Timeline

struct WatchTideEntry: TimelineEntry {
    let date: Date
    let data: WidgetSharedData?
    /// Pertinence Smart Stack : élevée à l'approche d'une pleine/basse mer pour que
    /// la complication remonte automatiquement dans la pile au bon moment.
    var relevance: TimelineEntryRelevance?
}

struct WatchTideProvider: TimelineProvider {

    func placeholder(in context: Context) -> WatchTideEntry {
        WatchTideEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchTideEntry) -> Void) {
        completion(WatchTideEntry(date: Date(), data: loadSharedData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchTideEntry>) -> Void) {
        let rawData = loadSharedData()
        let now = Date()
        var entries: [WatchTideEntry] = []

        // 10-min intervals × 48 entries = 8 hours of coverage
        let intervalMinutes = 10
        let totalEntries = 48
        for i in 0..<totalEntries {
            let entryDate = Calendar.current.date(byAdding: .minute, value: i * intervalMinutes, to: now)
                ?? now.addingTimeInterval(Double(i * intervalMinutes * 60))
            let resolved: WidgetSharedData?
            if let d = rawData {
                resolved = resolvedSharedData(from: d, at: entryDate)
            } else {
                resolved = nil
            }
            entries.append(WatchTideEntry(date: entryDate, data: resolved,
                                          relevance: Self.relevance(for: resolved, at: entryDate)))
        }

        // Refresh after 2 hours (was 6h — too long, complication looked stale)
        let refreshDate = Calendar.current.date(byAdding: .hour, value: 2, to: now)
            ?? now.addingTimeInterval(2 * 3600)
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    /// Pertinence Smart Stack : maximale à l'approche d'une marée (≤45 min), décroissante ensuite.
    static func relevance(for data: WidgetSharedData?, at date: Date) -> TimelineEntryRelevance? {
        guard let data else { return nil }
        let minutesToNext = data.nextTideDate.timeIntervalSince(date) / 60
        let score: Float
        switch minutesToNext {
        case ..<45:  score = 1.0
        case ..<90:  score = 0.6
        default:     score = 0.2
        }
        return TimelineEntryRelevance(score: score,
                                      duration: max(0, data.nextTideDate.timeIntervalSince(date)))
    }

    private func loadSharedData() -> WidgetSharedData? {
        // Essayer d'abord l'App Group partagé, puis fallback UserDefaults.standard
        let key = "watch_tide_data"
        let sources: [UserDefaults] = [
            UserDefaults(suiteName: WidgetSharedKeys.appGroupId),
            UserDefaults.standard
        ].compactMap { $0 }

        for defaults in sources {
            if let encoded = defaults.data(forKey: key),
               let data = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded) {
                return data
            }
        }
        return nil
    }
}

// MARK: - Shared Helpers

/// Vent observé encore « frais » (mesure < 90 min avant l'instant de l'entrée). Au-delà,
/// la balise n'a pas été réinterrogée (l'ingestion Watch exige l'ouverture de l'app) → on
/// n'affiche pas une vieille mesure comme « en direct » (mesure de 9 h vue à 18 h).
func freshObservedWind(_ data: WidgetSharedData) -> (speed: Double, dir: Double)? {
    guard let speed = data.observedWindKmh, let dir = data.observedWindDirDeg else { return nil }
    if let wd = data.observedWindDate, data.updatedAt.timeIntervalSince(wd) > 90 * 60 { return nil }
    return (speed, dir)
}

private func coeffColor(_ coef: Int) -> Color {
    switch coef {
    case ..<45:   return .green
    case 45..<70: return .yellow
    case 70..<95: return .orange
    default:      return .red
    }
}

private func bestCoef(from data: WidgetSharedData) -> Int? {
    data.todayCoef ?? data.nextTideCoef ?? data.secondTideCoef
}

private func interpolatedHeight(from data: WidgetSharedData, at date: Date) -> Double {
    guard let prevDate = data.previousTideDate,
          let prevHeight = data.previousTideHeight else {
        return data.currentHeight
    }
    let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
    guard totalDuration > 0 else { return data.currentHeight }
    let elapsed = date.timeIntervalSince(prevDate)
    let fraction = min(max(elapsed / totalDuration, 0), 1)
    let cosineProgress = (1 - cos(fraction * .pi)) / 2
    return prevHeight + (data.nextTideHeight - prevHeight) * cosineProgress
}

private func tideProgress(from data: WidgetSharedData, at date: Date) -> Double {
    guard let prevDate = data.previousTideDate else {
        let cycleDuration: TimeInterval = 6 * 3600 + 12 * 60
        let timeToNext = data.nextTideDate.timeIntervalSince(date)
        let elapsed = cycleDuration - timeToNext
        return min(max(elapsed / cycleDuration, 0), 1)
    }
    let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
    guard totalDuration > 0 else { return 0 }
    let elapsed = date.timeIntervalSince(prevDate)
    return min(max(elapsed / totalDuration, 0), 1)
}

// MARK: - Widget Configuration

struct TideWatchComplication: Widget {
    let kind = "TideWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTideProvider()) { entry in
            WatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Marées")
        .description("Hauteur, tendance et prochaine marée sur votre cadran")
        .supportedFamilies([
            .accessoryCorner,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Entry View Dispatch

struct WatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WatchTideProvider.Entry

    var body: some View {
        Group {
            if let rawData = entry.data, !rawData.portName.isEmpty {
                let data = resolvedSharedData(from: rawData, at: entry.date)
                let liveHeight = interpolatedHeight(from: data, at: entry.date)
                switch family {
                case .accessoryCorner:
                    CornerTideView(data: data, liveHeight: liveHeight, entryDate: entry.date)
                case .accessoryCircular:
                    CircularTideView(data: data, liveHeight: liveHeight, entryDate: entry.date)
                case .accessoryRectangular:
                    RectangularTideView(data: data, liveHeight: liveHeight, entryDate: entry.date)
                case .accessoryInline:
                    InlineTideView(data: data, liveHeight: liveHeight)
                default:
                    Text("—")
                }
            } else {
                emptyView
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "tideit://open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Phrase VoiceOver cohérente (au lieu de fragments illisibles type "↑3,5 m • C95").
    private var accessibilityLabel: String {
        guard let raw = entry.data, !raw.portName.isEmpty else { return String(localized: "Ouvrez Tide It") }
        let data = resolvedSharedData(from: raw, at: entry.date)
        let liveHeight = interpolatedHeight(from: data, at: entry.date)
        let trend = data.nextTideIsHigh ? String(localized: "marée montante") : String(localized: "marée descendante")
        let nextType = data.nextTideIsHigh ? String(localized: "pleine mer") : String(localized: "basse mer")
        var parts = [
            "\(SharedUnitFormatter.height(liveHeight)), \(trend).",
            String(localized: "Prochaine \(nextType) à \(formatTideTime(data.nextTideDate, in: data.timeZone)).")
        ]
        if let c = bestCoef(from: data) { parts.append("Coefficient \(c).") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var emptyView: some View {
        switch family {
        case .accessoryCorner:
            Text("—")
                .widgetCurvesContent()
                .widgetLabel {
                    Text("Tide It")
                }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "water.waves")
                    .font(.system(size: 18))
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ACCESSORY CORNER (watchOS exclusif)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private struct CornerTideView: View {
    let data: WidgetSharedData
    let liveHeight: Double
    let entryDate: Date

    private var isRising: Bool { data.nextTideIsHigh }
    private var progress: Double { tideProgress(from: data, at: entryDate) }

    var body: some View {
        // Texte principal dans le coin
        Text(SharedUnitFormatter.height(liveHeight))
            .font(.system(size: 20, weight: .heavy, design: .rounded))
            .foregroundStyle(isRising ? WC.high : WC.low)
            .widgetCurvesContent()
            .widgetLabel {
                // Gauge arc le long du bord du cadran
                Gauge(value: progress) {
                    Text("")
                } currentValueLabel: {
                    Text("")
                } minimumValueLabel: {
                    Text(isRising ? "↑" : "↓")
                } maximumValueLabel: {
                    Text(bestCoef(from: data).map { "\($0)" } ?? "")
                }
                .gaugeStyle(.accessoryLinear)
                .tint(Gradient(colors: isRising
                    ? [WC.low, WC.mid, WC.high]
                    : [WC.high, WC.mid, WC.low]))
            }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ACCESSORY CIRCULAR
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private struct CircularTideView: View {
    let data: WidgetSharedData
    let liveHeight: Double
    let entryDate: Date

    private var isRising: Bool { data.nextTideIsHigh }
    private var progress: Double { tideProgress(from: data, at: entryDate) }

    var body: some View {
        Gauge(value: progress) {
            Image(systemName: "water.waves")
        } currentValueLabel: {
            VStack(spacing: 0) {
                Image(systemName: isRising ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .heavy))

                if let c = bestCoef(from: data) {
                    Text("\(c)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(Gradient(colors: isRising
            ? [WC.low, WC.mid, WC.high]
            : [WC.high, WC.mid, WC.low]))
        .widgetAccentable()
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ACCESSORY RECTANGULAR (avec mini courbe)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private struct RectangularTideView: View {
    let data: WidgetSharedData
    let liveHeight: Double
    let entryDate: Date

    private var isRising: Bool { data.nextTideIsHigh }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Row 1: Height + trend + coef
            HStack(spacing: 3) {
                Image(systemName: isRising ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(isRising ? WC.high : WC.low)

                Text(SharedUnitFormatter.height(liveHeight))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))

                Spacer(minLength: 0)

                if let c = bestCoef(from: data) {
                    Text("C\(c)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(coeffColor(c))
                }
            }

            // Row 2: Mini tide curve — more visible, colored, taller
            Canvas { context, size in
                drawMiniCurve(context: &context, size: size)
            }
            .frame(height: 28)

            // Row 3: Next tide info
            HStack(spacing: 3) {
                Image(systemName: data.nextTideIsHigh ? "arrow.up" : "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(data.nextTideIsHigh ? WC.high : WC.low)

                Text(data.nextTideIsHigh ? "PM" : "BM")
                    .font(.system(size: 9, weight: .bold))

                Text(data.nextTideDate, style: .relative)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Vent observé si dispo ET frais (sinon hauteur de la prochaine marée).
                if let wind = freshObservedWind(data) {
                    HStack(spacing: 2) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.teal)
                            .rotationEffect(.degrees(wind.dir + 180))
                        Text(SharedUnitFormatter.windSpeed(wind.speed))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.teal)
                    }
                } else {
                    Text(SharedUnitFormatter.height(data.nextTideHeight))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .widgetAccentable()
    }

    // MARK: Mini Curve Drawing

    private func drawMiniCurve(context: inout GraphicsContext, size: CGSize) {
        var anchors: [(date: Date, height: Double, isHigh: Bool)] = []

        if !data.allTides.isEmpty {
            let nowTs = entryDate.timeIntervalSince1970
            var lo = 0, hi = data.allTides.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if data.allTides[mid].date.timeIntervalSince1970 <= nowTs { lo = mid + 1 } else { hi = mid }
            }
            let futureIdx = lo
            // Fenêtre RESSERRÉE (≈1,5 cycle centré sur maintenant) : moins de fréquence,
            // chaque vague est large → on voit où on en est d'un coup d'œil (codes de l'app).
            let startIdx = max(0, futureIdx - 2)
            let endIdx = min(data.allTides.count, futureIdx + 2)
            for i in startIdx..<endIdx {
                let t = data.allTides[i]
                anchors.append((t.date, t.height, t.isHigh))
            }
        } else {
            if let pDate = data.previousTideDate, let pH = data.previousTideHeight {
                anchors.append((pDate, pH, !data.nextTideIsHigh))
            }
            anchors.append((data.nextTideDate, data.nextTideHeight, data.nextTideIsHigh))
            if let sDate = data.secondTideDate, let sH = data.secondTideHeight, let sHigh = data.secondTideIsHigh {
                anchors.append((sDate, sH, sHigh))
            }
        }

        guard anchors.count >= 2 else { return }

        let anchorTimes = anchors.map { $0.date.timeIntervalSince1970 }
        guard let minTime = anchorTimes.first, let maxTime = anchorTimes.last else { return }

        let timeRange = maxTime - minTime
        guard timeRange > 0 else { return }

        var minH = Double.infinity, maxH = -Double.infinity
        for a in anchors { if a.height < minH { minH = a.height }; if a.height > maxH { maxH = a.height } }
        let padding = (maxH - minH) * 0.15
        minH -= padding; maxH += padding
        let hRange = maxH - minH
        guard hRange > 0 else { return }

        let pad: CGFloat = 1
        let drawW = size.width - pad * 2
        let drawH = size.height - pad * 2

        func mapPoint(time: Double, height: Double) -> CGPoint {
            let x = pad + CGFloat((time - minTime) / timeRange) * drawW
            let y = pad + CGFloat(1 - (height - minH) / hRange) * drawH
            return CGPoint(x: x, y: y)
        }

        // Generate curve points
        var curvePoints: [CGPoint] = []
        // Also track which segment each point is in (for coloring)
        var curveHeights: [Double] = []
        let steps = max(Int(drawW), 40)
        var segIdx = 0

        for step in 0...steps {
            let t = minTime + (Double(step) / Double(steps)) * timeRange
            while segIdx < anchors.count - 2 && anchorTimes[segIdx + 1] <= t {
                segIdx += 1
            }
            let nextIdx = min(segIdx + 1, anchors.count - 1)
            let segDur = anchorTimes[nextIdx] - anchorTimes[segIdx]
            let frac: Double = segDur > 0 ? min(max((t - anchorTimes[segIdx]) / segDur, 0), 1) : 0
            let cosP = (1 - cos(frac * .pi)) / 2
            let h = anchors[segIdx].height + (anchors[nextIdx].height - anchors[segIdx].height) * cosP
            curvePoints.append(mapPoint(time: t, height: h))
            curveHeights.append(h)
        }

        guard let firstCPt = curvePoints.first, let lastCPt = curvePoints.last else { return }

        let nowT = entryDate.timeIntervalSince1970

        // Remplissage qui descend et se FOND à transparent en bas (codes de l'app).
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: firstCPt.x, y: size.height))
        for pt in curvePoints { fillPath.addLine(to: pt) }
        fillPath.addLine(to: CGPoint(x: lastCPt.x, y: size.height))
        fillPath.closeSubpath()

        context.fill(fillPath, with: .linearGradient(
            Gradient(stops: [
                .init(color: WC.high.opacity(0.30), location: 0.0),
                .init(color: WC.mid.opacity(0.16), location: 0.5),
                .init(color: WC.low.opacity(0.0), location: 1.0)
            ]),
            startPoint: CGPoint(x: size.width / 2, y: 0),
            endPoint: CGPoint(x: size.width / 2, y: size.height)
        ))

        // Trait BICOLORE split à « maintenant » : passé = cyan · futur = violet (codes app).
        var strokePath = Path()
        strokePath.move(to: curvePoints.first!)
        for pt in curvePoints.dropFirst() { strokePath.addLine(to: pt) }

        let lineStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        if nowT > minTime && nowT < maxTime {
            let nowX = pad + CGFloat((nowT - minTime) / timeRange) * drawW
            var past = context
            past.clip(to: Path(CGRect(x: 0, y: 0, width: nowX, height: size.height)))
            past.stroke(strokePath, with: .color(WC.high), style: lineStyle)
            var future = context
            future.clip(to: Path(CGRect(x: nowX, y: 0, width: size.width - nowX, height: size.height)))
            future.stroke(strokePath, with: .color(WC.low), style: lineStyle)
        } else {
            context.stroke(strokePath, with: .color(WC.high), style: lineStyle)
        }

        // Point « maintenant » : anneau cyan + cœur blanc (mêmes codes que l'app).
        if nowT >= minTime && nowT <= maxTime {
            let nowPt = mapPoint(time: nowT, height: liveHeight)
            context.fill(
                Path(ellipseIn: CGRect(x: nowPt.x - 5.5, y: nowPt.y - 5.5, width: 11, height: 11)),
                with: .color(WC.high.opacity(0.35))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: nowPt.x - 3, y: nowPt.y - 3, width: 6, height: 6)),
                with: .color(.white)
            )
        }

        // Pleines/basses mers : petits points pleins (sobres, lisibles).
        for (i, anchor) in anchors.enumerated() {
            let pt = mapPoint(time: anchorTimes[i], height: anchor.height)
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)),
                with: .color(anchor.isHigh ? WC.high : WC.low)
            )
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ACCESSORY INLINE
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private struct InlineTideView: View {
    let data: WidgetSharedData
    let liveHeight: Double

    private var isRising: Bool { data.nextTideIsHigh }

    var body: some View {
        let arrow = isRising ? "↑" : "↓"
        let height = SharedUnitFormatter.height(liveHeight)
        let tide = data.nextTideIsHigh ? String(localized: "PM") : String(localized: "BM")
        let time = formatTideTime(data.nextTideDate, in: data.timeZone)

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
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - COMPLICATION VENT (small : vent direct si balise)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Complication dédiée au VENT observé (balise la plus proche). Familles small
/// (circular + corner). Sans balise/mesure → état neutre (icône barrée).
struct TideWatchWindComplication: Widget {
    let kind = "TideWatchWindComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTideProvider()) { entry in
            WindComplicationEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Vent observé")
        .description("Vitesse et direction du vent en direct (balise la plus proche).")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct WindComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchTideEntry

    var body: some View {
        if let data = entry.data, let wind = freshObservedWind(data) {
            switch family {
            case .accessoryCorner:
                WindCornerView(speedKmh: wind.speed, dirDeg: wind.dir)
            default:
                WindCircularView(speedKmh: wind.speed, dirDeg: wind.dir)
            }
        } else {
            // Pas de balise / donnée absente OU périmée (> 90 min) : état neutre plutôt
            // qu'une vieille mesure affichée « en direct ».
            Image(systemName: "wind.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Circular : flèche orientée + vitesse + cardinal — lisible d'un coup d'œil.
private struct WindCircularView: View {
    let speedKmh: Double
    let dirDeg: Double

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.teal)
                .rotationEffect(.degrees(dirDeg + 180))
            Text(SharedUnitFormatter.windSpeed(speedKmh))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(SharedUnitFormatter.windCardinal(dirDeg))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.teal)
        }
        .widgetAccentable()
    }
}

/// Corner : vitesse en gros, flèche en label incurvé.
private struct WindCornerView: View {
    let speedKmh: Double
    let dirDeg: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 18, weight: .heavy))
            .foregroundStyle(.teal)
            .rotationEffect(.degrees(dirDeg + 180))
            .widgetLabel {
                Text("\(SharedUnitFormatter.windSpeed(speedKmh)) \(SharedUnitFormatter.windCardinal(dirDeg))")
            }
            .widgetAccentable()
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

#Preview("Corner", as: .accessoryCorner) {
    TideWatchComplication()
} timeline: {
    WatchTideEntry(date: Date(), data: previewData)
}

#Preview("Circular", as: .accessoryCircular) {
    TideWatchComplication()
} timeline: {
    WatchTideEntry(date: Date(), data: previewData)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    TideWatchComplication()
} timeline: {
    WatchTideEntry(date: Date(), data: previewData)
}

#Preview("Inline", as: .accessoryInline) {
    TideWatchComplication()
} timeline: {
    WatchTideEntry(date: Date(), data: previewData)
}

//
//  TideCardView.swift
//  Tide It
//
//  Carte de marée partageable au format Stories (360×640 pt → 1080×1920 px @3x)
//

import SwiftUI

// MARK: - Data Model

struct TideCardData {
    let portName: String
    let date: Date
    let tideData: [TideData]        // marées du jour (triées)
    let currentHeight: Double
    let trend: TideCalculator.TideState.TideTrend
    let coefficient: Int?
    let weather: WeatherInfo?
    let marine: MarineInfo?
    let activityScores: [ActivityScore]
    let sunrise: Date?
    let sunset: Date?
    let portTimeZone: TimeZone

    struct WeatherInfo {
        let temp: Double
        let windSpeed: Double
        let windDir: String
        let symbol: String
    }

    struct MarineInfo {
        let waveHeight: Double
        let wavePeriod: Double
    }
}

// MARK: - Card View (360×640 logique)

struct TideCardView: View {
    let data: TideCardData
    @EnvironmentObject private var themeManager: ThemeManager
    private var calendar: Calendar { Calendar.inTimeZone(data.portTimeZone) }

    private var dateFmt: DateFormatter {
        CachedDateFormatter.make("EEEE d MMMM", timeZone: data.portTimeZone)
    }

    private var timeFmt: DateFormatter {
        CachedDateFormatter.make("HH:mm", timeZone: data.portTimeZone)
    }

    private var isRising: Bool {
        data.trend == .rising || data.trend == .highSlack
    }

    private var trendColor: Color {
        isRising ? .tideHigh : .tideLow
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            headerSection
                .padding(.top, 24)
                .padding(.bottom, 12)

            // ── Port name ──
            portNameSection
                .padding(.bottom, 16)

            // ── Tide curve ──
            curveSection
                .frame(height: 160)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // ── Hero: current height ──
            heroSection
                .padding(.bottom, 16)

            // ── Divider ──
            cardDivider

            // ── Tide schedule ──
            tideScheduleSection
                .padding(.vertical, 14)

            // ── Divider ──
            cardDivider

            // ── Weather & Marine ──
            if data.weather != nil || data.marine != nil {
                conditionsSection
                    .padding(.vertical, 14)
                cardDivider
            }

            // ── Activities ──
            if !data.activityScores.isEmpty {
                activitiesSection
                    .padding(.vertical, 14)
                cardDivider
            }

            Spacer(minLength: 8)

            // ── Footer ──
            footerSection
                .padding(.bottom, 20)
        }
        .frame(width: 360, height: 640)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.08),
                    Color(red: 0.05, green: 0.05, blue: 0.15),
                    Color(red: 0.03, green: 0.03, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "water.waves")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.tideHigh, .tideLow],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text("Tide It")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            Text(dateFmt.string(from: data.date).capitalized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Port Name

    private var portNameSection: some View {
        Text(data.portName)
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white, .tideHigh.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 24)
    }

    // MARK: - Tide Curve (Canvas)

    private var curveSection: some View {
        Canvas { context, size in
            drawCardCurve(context: &context, size: size)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.glassHighlight.opacity(0.03))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Courbe de marée du \(SharedFormatters.frenchFullDate.copy(timeZone: data.portTimeZone).string(from: data.date))")
        .accessibilityValue(curveAccessibilityValue)
    }

    private var curveAccessibilityValue: String {
        let timeFmt = SharedFormatters.time.copy(timeZone: data.portTimeZone)
        let sys = themeManager.measureSystem
        let unitWord = sys == .imperial ? "pieds" : "mètres"
        let lines: [String] = data.tideData.map { tide in
            let type = tide.isHighTide ? "pleine mer" : "basse mer"
            return "\(type) à \(timeFmt.string(from: tide.date)), \(String(format: "%.1f", locale: Locale.current, UnitFormatter.heightValue(tide.height, system: sys))) \(unitWord)"
        }
        return lines.isEmpty ? "aucune donnée" : lines.joined(separator: ", ")
    }

    private func drawCardCurve(context: inout GraphicsContext, size: CGSize) {
        let dayStart = calendar.startOfDay(for: data.date)
        let dayDuration: TimeInterval = 86400

        // Build extended tides for smooth curve
        var tides = data.tideData.sorted { $0.date < $1.date }
        guard tides.count >= 2 else { return }

        let avgTideDuration: TimeInterval = 6 * 3600 + 12 * 60

        if let first = tides.first, first.date > dayStart {
            let virtualDate = first.date.addingTimeInterval(-avgTideDuration)
            let avgOpp = tides.filter { $0.isHighTide != first.isHighTide }.map(\.height)
            let oppH = avgOpp.isEmpty ? (first.isHighTide ? first.height * 0.15 : first.height * 3) : avgOpp.reduce(0, +) / Double(avgOpp.count)
            tides.insert(TideData(date: virtualDate, height: oppH, isHighTide: !first.isHighTide, coefficient: nil), at: 0)
        }
        if let last = tides.last {
            let dayEnd = dayStart.addingTimeInterval(dayDuration)
            if last.date < dayEnd {
                let virtualDate = last.date.addingTimeInterval(avgTideDuration)
                let avgOpp = tides.filter { $0.isHighTide != last.isHighTide }.map(\.height)
                let oppH = avgOpp.isEmpty ? (last.isHighTide ? last.height * 0.15 : last.height * 3) : avgOpp.reduce(0, +) / Double(avgOpp.count)
                tides.append(TideData(date: virtualDate, height: oppH, isHighTide: !last.isHighTide, coefficient: nil))
            }
        }

        // Height normalization
        let heights = tides.map(\.height)
        let minH = (heights.min() ?? 0)
        let maxH = (heights.max() ?? 10)
        let pad = (maxH - minH) * 0.25
        let adjMin = minH - pad
        let adjMax = maxH + pad
        let hSpan = adjMax - adjMin
        guard hSpan > 0 else { return }

        let topM: CGFloat = size.height * 0.15
        let botM: CGFloat = size.height * 0.20
        let drawH = size.height - topM - botM

        // Generate curve points
        let steps = 200
        var points: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let pointDate = dayStart.addingTimeInterval(Double(t) * dayDuration)

            var prevTide: TideData?
            var nextTide: TideData?
            for tide in tides {
                if tide.date <= pointDate { prevTide = tide }
                if tide.date > pointDate && nextTide == nil { nextTide = tide }
            }

            let height: Double
            if let prev = prevTide, let next = nextTide {
                let segDur = next.date.timeIntervalSince(prev.date)
                guard segDur > 0 else { continue }
                let prog = pointDate.timeIntervalSince(prev.date) / segDur
                let cosProg = (1 - cos(prog * .pi)) / 2
                height = prev.height + (next.height - prev.height) * cosProg
            } else if let prev = prevTide {
                height = prev.height
            } else if let next = nextTide {
                height = next.height
            } else {
                height = adjMin + hSpan / 2
            }

            let normH = (height - adjMin) / hSpan
            let x = t * size.width
            let y = topM + drawH * (1 - CGFloat(normH))
            points.append(CGPoint(x: x, y: y))
        }

        guard let firstPt = points.first, let lastPt = points.last else { return }

        // Fill gradient under curve
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: firstPt.x, y: size.height))
        for pt in points { fillPath.addLine(to: pt) }
        fillPath.addLine(to: CGPoint(x: lastPt.x, y: size.height))
        fillPath.closeSubpath()

        context.fill(fillPath, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color.cyan.opacity(0.4), location: 0),
                .init(color: Color.blue.opacity(0.25), location: 0.4),
                .init(color: Color.purple.opacity(0.15), location: 0.7),
                .init(color: Color.purple.opacity(0.05), location: 1)
            ]),
            startPoint: CGPoint(x: size.width / 2, y: 0),
            endPoint: CGPoint(x: size.width / 2, y: size.height)
        ))

        // Stroke curve
        var strokePath = Path()
        strokePath.move(to: firstPt)
        for pt in points.dropFirst() { strokePath.addLine(to: pt) }

        context.stroke(strokePath, with: .linearGradient(
            Gradient(colors: [.cyan, .blue, .purple]),
            startPoint: CGPoint(x: 0, y: size.height / 2),
            endPoint: CGPoint(x: size.width, y: size.height / 2)
        ), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

        // Tide point dots + labels
        let dayTides = data.tideData.filter {
            $0.date >= dayStart && $0.date < dayStart.addingTimeInterval(dayDuration)
        }.sorted { $0.date < $1.date }

        for tide in dayTides {
            let tOff = tide.date.timeIntervalSince(dayStart) / dayDuration
            let normH = (tide.height - adjMin) / hSpan
            let x = CGFloat(tOff) * size.width
            let y = topM + drawH * (1 - CGFloat(normH))

            let dotColor: Color = tide.isHighTide ? .cyan : .purple

            // Glow
            context.fill(
                Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)),
                with: .color(dotColor.opacity(0.3))
            )
            // Dot
            context.fill(
                Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                with: .color(dotColor)
            )
            // White center
            context.fill(
                Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                with: .color(.white.opacity(0.9))
            )

            // Label
            let typeStr = tide.isHighTide ? "PM" : "BM"
            let timeStr = timeFmt.string(from: tide.date)
            let heightStr = UnitFormatter.height(tide.height, system: themeManager.measureSystem)
            let label = "\(typeStr) \(timeStr) \(heightStr)"

            let labelY = tide.isHighTide ? y - 16 : y + 16

            context.draw(
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(dotColor),
                at: CGPoint(x: x, y: labelY),
                anchor: .center
            )
        }

        // "Now" indicator (vertical line)
        let now = Date()
        if calendar.isDate(data.date, inSameDayAs: now) {
            let nowOff = now.timeIntervalSince(dayStart) / dayDuration
            if nowOff >= 0 && nowOff <= 1 {
                let nowX = CGFloat(nowOff) * size.width
                var linePath = Path()
                linePath.move(to: CGPoint(x: nowX, y: topM * 0.5))
                linePath.addLine(to: CGPoint(x: nowX, y: size.height - botM * 0.5))
                context.stroke(linePath, with: .color(.white.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        HStack(spacing: 16) {
            // Trend arrow
            ZStack {
                Circle()
                    .fill(trendColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: data.trend.icon)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(trendColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(UnitFormatter.height(data.currentHeight, system: themeManager.measureSystem))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(data.trend.localizedDescription)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(trendColor)
            }

            Spacer()

            // Coefficient badge
            if let coef = data.coefficient {
                VStack(spacing: 2) {
                    Text("\(coef)")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.coefficientColor(coef))
                    Text("coef")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.coefficientColor(coef).opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.coefficientColor(coef).opacity(0.3), lineWidth: 0.5)
                        )
                )
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Tide Schedule

    private var tideScheduleSection: some View {
        let dayStart = calendar.startOfDay(for: data.date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let dayTides = data.tideData.filter {
            $0.date >= dayStart && $0.date < dayEnd
        }.sorted { $0.date < $1.date }

        return VStack(spacing: 10) {
            ForEach(dayTides) { tide in
                HStack(spacing: 10) {
                    Image(systemName: tide.isHighTide ? "arrow.up" : "arrow.down")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(tide.isHighTide ? .cyan : .purple)
                        .frame(width: 18)

                    Text(tide.isHighTide ? "PM" : "BM")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(tide.isHighTide ? .cyan : .purple)
                        .frame(width: 28, alignment: .leading)

                    Text(timeFmt.string(from: tide.date))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(UnitFormatter.height(tide.height, system: themeManager.measureSystem, decimals: 2))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))

                    Spacer()

                    if let coef = tide.coefficient {
                        Text("C\(coef)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.coefficientColor(coef))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.coefficientColor(coef).opacity(0.12))
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Conditions (Weather + Marine)

    private var conditionsSection: some View {
        HStack(spacing: 0) {
            if let w = data.weather {
                HStack(spacing: 6) {
                    Image(systemName: w.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(.yellow)
                    Text(UnitFormatter.temp(w.temp, system: themeManager.measureSystem))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: "wind")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.mint)
                    Text("\(UnitFormatter.windSpeed(w.windSpeed, unit: themeManager.windUnit)) \(w.windDir)")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            if data.weather != nil && data.marine != nil {
                Spacer()
            }

            if let m = data.marine {
                HStack(spacing: 5) {
                    Image(systemName: "water.waves")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text(UnitFormatter.height(m.waveHeight, system: themeManager.measureSystem))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                    Text("•")
                        .foregroundStyle(.white.opacity(0.4))
                    Text(String(format: "%.0fs", m.wavePeriod))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Activities

    private var activitiesSection: some View {
        let top3 = Array(data.activityScores.sorted { $0.score > $1.score }.prefix(3))

        return HStack(spacing: 0) {
            ForEach(top3) { score in
                HStack(spacing: 4) {
                    Image(systemName: score.activity.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(score.activity.color)
                    Text(cardActivityName(score.activity))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                    Text("\(score.score)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(score.color)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Noms courts pour la carte exportée
    private func cardActivityName(_ activity: NauticalActivity) -> String {
        switch activity {
        case .kitesurfing: return "Kite"
        case .kitefoil:    return "Kitefoil"
        case .wingfoil:    return "Wing"
        case .sailing:     return "Voile"
        case .boatLaunch:  return "Bateau"
        case .swimming:    return "Bain"
        case .fishing:     return "Pêche"
        case .surfing:     return "Surf"
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            if let rise = data.sunrise, let set = data.sunset {
                HStack(spacing: 20) {
                    HStack(spacing: 5) {
                        Image(systemName: "sunrise.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text(timeFmt.string(from: rise))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "sunset.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange.opacity(0.7))
                        Text(timeFmt.string(from: set))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }

            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.glassHighlight.opacity(0.08))
                    .frame(height: 0.5)
                Text("Tide It • Marées & Vent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
                Rectangle()
                    .fill(Color.glassHighlight.opacity(0.08))
                    .frame(height: 0.5)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Helpers

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.glassHighlight.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, 24)
    }
}

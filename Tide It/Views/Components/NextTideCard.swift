//
//  NextTideCard.swift
//  Tide It
//
//  Carte countdown vers la prochaine marée — sparkline, liquid fill, countdown animé
//

import SwiftUI

struct NextTideCard: View {
    let tideData: [TideData]
    let currentTime: Date
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var animateProgress = false

    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }
    @State private var wavePhase: CGFloat = 0

    private var tideState: TideCalculator.TideState? {
        TideCalculator.currentState(at: currentTime, sortedTides: tideData)
    }

    var body: some View {
        if let state = tideState, let nextTide = state.nextTide {
            let tideColor: Color = nextTide.isHighTide ? .tideHigh : .tideLow
            let progress = state.percentToNextTide

            VStack(spacing: 0) {
                // Top row: info + countdown
                HStack(alignment: .top, spacing: DS.spacingMD) {
                    // Left: trend + next tide info
                    VStack(alignment: .leading, spacing: DS.spacingSM) {
                        // Title with trend
                        HStack(spacing: 6) {
                            Image(systemName: nextTide.isHighTide ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .font(.scaled(size: DS.fontCallout, weight: .bold))
                                .foregroundStyle(tideColor)

                            Text("Prochaine \(nextTide.isHighTide ? "pleine mer" : "basse mer")")
                                .font(.scaled(size: DS.fontCallout, weight: .semibold))
                                .foregroundStyle(.primary)
                        }

                        // Countdown
                        if let timeToNext = state.timeToNextTide {
                            AnimatedCountdown(interval: timeToNext, color: tideColor)
                        }

                        // Details row
                        HStack(spacing: DS.spacingMD) {
                            Label(formatTime(nextTide.date), systemImage: "clock")
                                .font(.scaled(size: DS.fontFootnote, weight: .medium))
                                .foregroundStyle(.secondary)

                            Label(UnitFormatter.height(nextTide.height, system: themeManager.measureSystem, decimals: 2), systemImage: "ruler")
                                .font(.scaled(size: DS.fontFootnote, weight: .medium))
                                .foregroundStyle(.secondary)

                            if let coef = nextTide.coefficient {
                                Text("\(coef)")
                                    .font(.scaled(size: DS.fontCallout, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.coefficientColor(coef))
                                    .padding(.horizontal, DS.spacingSM)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(Color.coefficientColor(coef).opacity(0.15))
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.coefficientColor(coef).opacity(0.3), lineWidth: 0.5)
                                            )
                                    )
                            }
                        }
                        .labelStyle(.iconOnly)
                        .imageScale(.small)
                    }

                    Spacer()

                    // Right: current height display
                    VStack(spacing: 2) {
                        Text(UnitFormatter.height(state.currentHeight, system: themeManager.measureSystem))
                            .font(.scaled(size: DS.fontTitle, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(state.trend.localizedDescription)
                            .font(.scaled(size: DS.fontCaption2, weight: .semibold))
                            .foregroundStyle(state.trend == .rising ? Color.tideHigh : Color.tideLow)
                    }
                }

                Spacer().frame(height: DS.spacingMD)

                // Liquid fill progress bar
                LiquidProgressBar(
                    progress: animateProgress ? progress : 0,
                    color: tideColor,
                    wavePhase: wavePhase
                )
                .frame(height: 8)

                Spacer().frame(height: DS.spacingSM)

                // Mini sparkline (next 6 hours)
                MiniSparkline(
                    tideData: tideData,
                    currentTime: currentTime,
                    hoursAhead: 6,
                    tideColor: tideColor
                )
                .frame(height: 40)
            }
            .glassCard(cornerRadius: DS.radiusLG, accentColor: tideColor)
            .onAppear {
                // Réduire les animations : pas de remplissage progressif ni de vague en boucle.
                guard !reduceMotion else {
                    animateProgress = true   // état final, sans transition
                    return
                }
                withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                    animateProgress = true
                }
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    wavePhase = .pi * 2
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(nextTideAccessibilityLabel(state: state, nextTide: nextTide))
        }
    }

    // MARK: - Accessibility
    private func nextTideAccessibilityLabel(state: TideCalculator.TideState, nextTide: TideData) -> String {
        let type = nextTide.isHighTide ? "pleine mer" : "basse mer"
        let countdown: String
        if let timeToNext = state.timeToNextTide {
            countdown = "dans \(formatCountdown(timeToNext))"
        } else {
            countdown = ""
        }
        let time = formatTime(nextTide.date)
        let height = String(format: "%.2f mètres", nextTide.height)
        let coefStr = nextTide.coefficient.map { ", coefficient \($0)" } ?? ""
        let current = String(format: "%.1f mètres", state.currentHeight)
        let trend = state.trend.description.lowercased()
        return "Prochaine \(type) \(countdown), à \(time), \(height)\(coefStr). Hauteur actuelle \(current), \(trend)"
    }

    private func formatCountdown(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))min"
        } else {
            return "\(minutes) min"
        }
    }
}

// MARK: - Animated Countdown
struct AnimatedCountdown: View {
    let interval: TimeInterval
    let color: Color

    private var hours: Int { Int(interval) / 3600 }
    private var minutes: Int { (Int(interval) % 3600) / 60 }

    var body: some View {
        HStack(spacing: 2) {
            if hours > 0 {
                CountdownDigit(value: hours)
                Text("h")
                    .font(.scaled(size: DS.fontBody, weight: .medium))
                    .foregroundStyle(.gray)
                CountdownDigit(value: minutes, padded: true)
                Text("min")
                    .font(.scaled(size: DS.fontBody, weight: .medium))
                    .foregroundStyle(.gray)
            } else {
                CountdownDigit(value: minutes)
                Text("min")
                    .font(.scaled(size: DS.fontBody, weight: .medium))
                    .foregroundStyle(.gray)
            }
        }
        .foregroundStyle(
            LinearGradient(
                colors: [color, .tideMid],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

struct CountdownDigit: View {
    let value: Int
    var padded: Bool = false

    var body: some View {
        Text(padded ? String(format: "%02d", value) : "\(value)")
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
    }
}

// MARK: - Liquid Progress Bar
struct LiquidProgressBar: View {
    let progress: Double
    let color: Color
    let wavePhase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let fillWidth = width * CGFloat(min(max(progress, 0), 1))

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.glassHighlight.opacity(0.06))

                // Filled portion with wave top
                Canvas { context, size in
                    guard fillWidth > 0 else { return }

                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))

                    // Flat bottom + sides
                    path.addLine(to: CGPoint(x: 0, y: 0))

                    // Wavy top edge
                    let step: CGFloat = 2
                    for x in stride(from: 0, through: fillWidth, by: step) {
                        let normalX = x / 30
                        let wave = sin(normalX + wavePhase) * 1.5
                        let y = wave + 1.5
                        path.addLine(to: CGPoint(x: x, y: max(0, y)))
                    }

                    path.addLine(to: CGPoint(x: fillWidth, y: size.height))
                    path.closeSubpath()

                    let gradient = Gradient(colors: [color.opacity(0.8), color.opacity(0.5)])
                    context.fill(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: .zero,
                            endPoint: CGPoint(x: fillWidth, y: 0)
                        )
                    )
                }
                .frame(width: fillWidth, height: height)
                .clipShape(Capsule())

                // Glow at the leading edge
                if fillWidth > 4 {
                    Circle()
                        .fill(color.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .blur(radius: 3)
                        .offset(x: fillWidth - 4)
                }
            }
        }
        .animation(.easeOut(duration: 0.8), value: progress)
    }
}

// MARK: - Mini Sparkline (next N hours)
struct MiniSparkline: View {
    let tideData: [TideData]
    let currentTime: Date
    let hoursAhead: Int
    let tideColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let endTime = currentTime.addingTimeInterval(TimeInterval(hoursAhead * 3600))
            let duration = endTime.timeIntervalSince(currentTime)
            guard duration > 0 else { return }

            let sorted = tideData // déjà trié par TideService
            guard sorted.count >= 2 else { return }

            // Compute height bounds for visible range
            var minH = Double.infinity, maxH = -Double.infinity
            let step: CGFloat = 3
            var points: [CGPoint] = []

            for x in stride(from: 0, through: size.width, by: step) {
                let progress = Double(x / size.width)
                let date = currentTime.addingTimeInterval(progress * duration)

                if let h = TideCalculator.interpolatedHeight(at: date, sortedTides: sorted) {
                    if h < minH { minH = h }
                    if h > maxH { maxH = h }
                    points.append(CGPoint(x: Double(x), y: h))
                }
            }

            let hSpan = max(maxH - minH, 0.1)
            let margin: CGFloat = 4

            // Build path
            var linePath = Path()
            var fillPath = Path()
            var first = true

            for pt in points {
                let normalY = (pt.y - minH) / hSpan
                let y = margin + (size.height - margin * 2) * (1 - CGFloat(normalY))
                let point = CGPoint(x: pt.x, y: y)

                if first {
                    linePath.move(to: point)
                    fillPath.move(to: CGPoint(x: pt.x, y: size.height))
                    fillPath.addLine(to: point)
                    first = false
                } else {
                    linePath.addLine(to: point)
                    fillPath.addLine(to: point)
                }
            }

            // Close fill
            if let last = points.last {
                fillPath.addLine(to: CGPoint(x: last.x, y: size.height))
                fillPath.closeSubpath()
            }

            // Draw fill
            let fillGradient = Gradient(stops: [
                .init(color: tideColor.opacity(0.15), location: 0),
                .init(color: tideColor.opacity(0.02), location: 1),
            ])
            context.fill(
                fillPath,
                with: .linearGradient(
                    fillGradient,
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                )
            )

            // Draw line
            context.stroke(
                linePath,
                with: .linearGradient(
                    Gradient(colors: [tideColor.opacity(0.6), tideColor.opacity(0.3)]),
                    startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2)
                ),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )

            // Draw "now" marker
            if !points.isEmpty {
                let nowNormalY = (points[0].y - minH) / hSpan
                let nowY = margin + (size.height - margin * 2) * (1 - CGFloat(nowNormalY))
                let nowRect = CGRect(x: -2.5, y: nowY - 2.5, width: 5, height: 5)
                context.fill(Circle().path(in: nowRect), with: .color(colorScheme == .dark ? .white : Color(white: 0.2)))
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

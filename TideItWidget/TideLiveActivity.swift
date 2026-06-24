//
//  TideLiveActivity.swift
//  TideItWidget
//
//  Live Activity pour Dynamic Island et Lock Screen banner
//

import ActivityKit
import SwiftUI
import WidgetKit

struct TideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TideLiveActivityAttributes.self) { context in
            // Lock Screen / StandBy banner
            lockScreenBanner(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    expandedCenter(context: context)
                }
            } compactLeading: {
                // Compact : vent (vedette) coloré par force, sinon tendance marée.
                if let w = context.state.windKmh {
                    Image(systemName: "wind")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(liveWindColor(w))
                } else {
                    Image(systemName: context.state.nextTideIsHigh ? "arrow.up" : "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(context.state.nextTideIsHigh ? .cyan : .purple)
                }
            } compactTrailing: {
                // Compact : vitesse vent (mode vent), repli hauteur marée.
                if let w = context.state.windKmh {
                    Text(SharedUnitFormatter.windSpeed(w))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(liveWindColor(w))
                } else {
                    Text(SharedUnitFormatter.height(context.state.currentHeight))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            } minimal: {
                // Minimal : pastille colorée par force du vent, sinon vague.
                if let w = context.state.windKmh {
                    Image(systemName: "wind")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(liveWindColor(w))
                } else {
                    Image(systemName: "water.waves")
                        .font(.system(size: 12))
                        .foregroundColor(.cyan)
                }
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenBanner(context: ActivityViewContext<TideLiveActivityAttributes>) -> some View {
        let s = context.state
        let tideColor: Color = s.nextTideIsHigh ? .cyan : .purple
        let go = Color(red: 0.35, green: 0.85, blue: 0.6)
        let hasWind = s.windKmh != nil

        VStack(spacing: 9) {
            // En-tête : port (+ stale) · badge GO sinon source vent réel/prévu.
            HStack(spacing: 6) {
                Text(context.attributes.portName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                // Données figées (>30 min sans mise à jour) → signalé plutôt que faussement « live ».
                if context.isStale {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.orange.opacity(0.9))
                }
                Spacer(minLength: 0)
                if let sport = s.goSport {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 9, weight: .bold))
                        Text("\(sport) · GO").font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(go)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(go.opacity(0.18)))
                    .lineLimit(1)
                } else if hasWind {
                    Text(s.windIsLive == true ? "réel" : "prévu")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(s.windIsLive == true ? go : .white.opacity(0.5))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }

            // Héros : VENT (gauche, vedette mode vent) | MARÉE (droite, secondaire).
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    if let w = s.windKmh {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(SharedUnitFormatter.windSpeed(w))
                                .font(.system(size: 27, weight: .medium, design: .rounded))
                                .foregroundColor(liveWindColor(w))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            if let d = s.windDirDeg {
                                HStack(spacing: 2) {
                                    Image(systemName: "location.north.fill")
                                        .font(.system(size: 8, weight: .semibold))
                                        .rotationEffect(.degrees(d))
                                    Text(SharedUnitFormatter.windCardinal(d))
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        if let g = s.windGustKmh {
                            Text("raf \(SharedUnitFormatter.windSpeed(g))")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    } else {
                        Text("Vent —")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(SharedUnitFormatter.height(s.currentHeight))
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                        Image(systemName: s.nextTideIsHigh ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(tideColor)
                    }
                    HStack(spacing: 3) {
                        Text(s.nextTideIsHigh ? "PM" : "BM")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(tideColor)
                        Text(s.nextTideDate, style: .time)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                        Text("· \(SharedUnitFormatter.height(s.nextTideHeight))")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
            }

            // Courbe — MARÉE + arc solaire (mini-TodayView, vedette). Repli barre.
            if s.curve.count >= 2 {
                LiveTideCurve(points: s.curve, sunrise: s.sunrise, sunset: s.sunset)
                    .frame(height: 46)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15)).frame(height: 5)
                        Capsule()
                            .fill(LinearGradient(colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(geo.size.width * s.tideProgress, 5), height: 5)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - Dynamic Island Expanded

    // Leading : VENT (héros mode vent) — vitesse colorée par force + rafale/direction.
    @ViewBuilder
    private func expandedLeading(context: ActivityViewContext<TideLiveActivityAttributes>) -> some View {
        let s = context.state
        VStack(alignment: .leading, spacing: 1) {
            if let w = s.windKmh {
                Text(SharedUnitFormatter.windSpeed(w))
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundColor(liveWindColor(w))
                    .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    if let d = s.windDirDeg {
                        Text(SharedUnitFormatter.windCardinal(d)).font(.system(size: 10, weight: .semibold))
                    }
                    if let g = s.windGustKmh {
                        Text("raf \(SharedUnitFormatter.windSpeed(g))").font(.system(size: 9, weight: .regular))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .foregroundColor(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(SharedUnitFormatter.height(s.currentHeight))
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    // Trailing : MARÉE — hauteur live + prochaine PM/BM.
    @ViewBuilder
    private func expandedTrailing(context: ActivityViewContext<TideLiveActivityAttributes>) -> some View {
        let s = context.state
        VStack(alignment: .trailing, spacing: 1) {
            Text(SharedUnitFormatter.height(s.currentHeight))
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 3) {
                Text(s.nextTideIsHigh ? "PM" : "BM").font(.system(size: 9, weight: .semibold))
                Text(s.nextTideDate, style: .time).font(.system(size: 10, weight: .regular))
            }
            .foregroundColor(s.nextTideIsHigh ? .cyan : .purple)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // Center : badge GO (sport jouable maintenant) sinon port + source vent.
    @ViewBuilder
    private func expandedCenter(context: ActivityViewContext<TideLiveActivityAttributes>) -> some View {
        let s = context.state
        let go = Color(red: 0.35, green: 0.85, blue: 0.6)
        if let sport = s.goSport {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11, weight: .bold))
                Text("\(sport) · GO").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundColor(go)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(go.opacity(0.16)))
            .padding(.horizontal, 4)
        } else {
            HStack(spacing: 6) {
                Text(context.attributes.portName)
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if s.windKmh != nil {
                    Text(s.windIsLive == true ? "réel" : "prévu")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(s.windIsLive == true ? Color(red: 0.61, green: 0.5, blue: 0.88) : .white.opacity(0.5))
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // Bottom : courbe MARÉE + arc solaire (mini-TodayView) ; repli barre.
    @ViewBuilder
    private func expandedBottom(context: ActivityViewContext<TideLiveActivityAttributes>) -> some View {
        let s = context.state
        if s.curve.count >= 2 {
            LiveTideCurve(points: s.curve, sunrise: s.sunrise, sunset: s.sunset).frame(height: 44).padding(.top, 2)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: s.nextTideIsHigh ? [.purple, .cyan] : [.cyan, .purple],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * s.tideProgress, 6), height: 6)
                }
            }
            .frame(height: 6).padding(.top, 4)
        }
    }
}

// MARK: - Courbe signature (Live Activity)

/// Courbe de marée à la même DA que l'app (amplitude ample, dégradé 4 couleurs, glow,
/// point « maintenant » centré). Statique : rendue à chaque mise à jour de la Live Activity.
/// `now` est centré → la courbe « défile » à chaque rafraîchissement.
private struct LiveTideCurve: View {
    let points: [TideLiveActivityAttributes.CurvePoint]
    var sunrise: Date? = nil
    var sunset: Date? = nil

    private static let cHigh = Color.cyan
    private static let cMid  = Color(red: 0.30, green: 0.52, blue: 0.95)
    private static let cMidP = Color(red: 0.55, green: 0.40, blue: 0.90)
    private static let cLow  = Color.purple
    private static let cSun  = Color(red: 1.0, green: 0.80, blue: 0.35)

    var body: some View {
        Canvas { ctx, size in
            let sorted = points.sorted { $0.t < $1.t }
            guard sorted.count >= 2, let first = sorted.first, let last = sorted.last else { return }

            let now = Date().timeIntervalSince1970
            let half: TimeInterval = 6 * 3600
            let startT = now - half
            let endT = now + half
            let span = endT - startT

            func xFor(_ t: Double) -> CGFloat { size.width * CGFloat((t - startT) / span) }

            // Arc solaire (doré, pointillé) sur le MÊME axe temps que la marée → mini-TodayView.
            if let sr = sunrise?.timeIntervalSince1970, let ss = sunset?.timeIntervalSince1970, ss > sr {
                let baseY = size.height * 0.97
                let arcH = size.height * 0.60
                func sunY(_ t: Double) -> CGFloat { baseY - CGFloat(sin(max(0, min(1, (t - sr) / (ss - sr))) * .pi)) * arcH }
                var arc = Path()
                var started = false
                let n = 48
                for i in 0...n {
                    let t = sr + (ss - sr) * Double(i) / Double(n)
                    guard t >= startT && t <= endT else { continue }
                    let p = CGPoint(x: xFor(t), y: sunY(t))
                    if started { arc.addLine(to: p) } else { arc.move(to: p); started = true }
                }
                if started {
                    ctx.stroke(arc, with: .color(Self.cSun.opacity(0.30)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3]))
                }
                // Soleil à l'instant présent (uniquement de jour).
                if now >= sr && now <= ss {
                    let p = CGPoint(x: xFor(now), y: sunY(now))
                    var glow = ctx; glow.addFilter(.blur(radius: 4)); glow.opacity = 0.85
                    glow.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Self.cSun))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)), with: .color(Self.cSun))
                }
            }

            // Hauteur interpolée (cosinus entre extrema, extrapolation aux bords).
            func interp(_ time: Double) -> Double {
                func seg(_ a: TideLiveActivityAttributes.CurvePoint, _ b: TideLiveActivityAttributes.CurvePoint) -> Double {
                    let dur = b.t.timeIntervalSince(a.t)
                    if dur <= 0 { return a.h }
                    let f = (time - a.t.timeIntervalSince1970) / dur
                    return a.h + (b.h - a.h) * (1 - cos(f * .pi)) / 2
                }
                if time <= first.t.timeIntervalSince1970 { return seg(sorted[0], sorted[1]) }
                if time >= last.t.timeIntervalSince1970 { return seg(sorted[sorted.count - 2], sorted[sorted.count - 1]) }
                for i in 0..<sorted.count - 1 where time >= sorted[i].t.timeIntervalSince1970 && time <= sorted[i + 1].t.timeIntervalSince1970 {
                    return seg(sorted[i], sorted[i + 1])
                }
                return last.h
            }

            // Échantillonne la FENÊTRE visible et cadre dessus → la vague remplit toujours
            // la hauteur (jamais plate), même si la plage journalière est plus large.
            let steps = max(Int(size.width), 2)
            var heights: [Double] = []
            heights.reserveCapacity(steps + 1)
            for i in 0...steps { heights.append(interp(startT + span * Double(i) / Double(steps))) }
            let minH = heights.min() ?? 0
            let maxH = heights.max() ?? 1
            let pad = max((maxH - minH) * 0.12, 0.12)
            let adjMin = minH - pad
            let range = max((maxH + pad) - adjMin, 0.1)

            let top = size.height * 0.16
            let bottom = size.height * 0.12
            let drawH = max(size.height - top - bottom, 1)
            func yFor(_ h: Double) -> CGFloat { top + CGFloat(1 - (h - adjMin) / range) * drawH }

            var path = Path()
            for i in 0...steps {
                let x = size.width * CGFloat(i) / CGFloat(steps)
                let y = yFor(heights[i])
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Fill dégradé.
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Self.cHigh.opacity(0.30), location: 0),
                    .init(color: Self.cMidP.opacity(0.14), location: 0.5),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: top),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))

            // Glow (1 couche floutée).
            var glow = ctx
            glow.addFilter(.blur(radius: 6))
            glow.opacity = 0.45
            glow.stroke(path, with: .linearGradient(
                Gradient(colors: [Self.cHigh, Self.cMid, Self.cLow]),
                startPoint: CGPoint(x: 0, y: size.height / 2), endPoint: CGPoint(x: size.width, y: size.height / 2)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

            // Trait principal dégradé 4 couleurs.
            ctx.stroke(path, with: .linearGradient(
                Gradient(colors: [Self.cHigh, Self.cMid, Self.cMidP, Self.cLow]),
                startPoint: CGPoint(x: 0, y: size.height / 2), endPoint: CGPoint(x: size.width, y: size.height / 2)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            // Extrema (PM/BM) visibles.
            for p in sorted {
                let pt = p.t.timeIntervalSince1970
                guard pt >= startT && pt <= endT else { continue }
                let x = size.width * CGFloat((pt - startT) / span)
                let y = yFor(p.h)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)),
                         with: .color(p.high ? Self.cHigh : Self.cLow))
            }

            // Point « maintenant » centré + halo.
            let nowX = size.width / 2
            let nowY = yFor(interp(now))
            ctx.fill(Path(ellipseIn: CGRect(x: nowX - 6, y: nowY - 6, width: 12, height: 12)), with: .color(Self.cHigh.opacity(0.25)))
            ctx.fill(Path(ellipseIn: CGRect(x: nowX - 3, y: nowY - 3, width: 6, height: 6)), with: .color(.white))
        }
    }
}

/// Couleur du vent par force (DA mode vent) pour la pastille de la Live Activity.
func liveWindColor(_ kmh: Double) -> Color {
    switch kmh {
    case ..<12:  return Color(red: 0.32, green: 0.75, blue: 0.95)   // bleu / teal (léger)
    case ..<22:  return Color(red: 0.35, green: 0.85, blue: 0.60)   // vert (jouable)
    case ..<32:  return Color(red: 0.95, green: 0.84, blue: 0.35)   // jaune (bon)
    case ..<45:  return Color(red: 0.95, green: 0.60, blue: 0.30)   // orange (musclé)
    default:     return Color(red: 0.95, green: 0.42, blue: 0.45)   // rouge (trop)
    }
}


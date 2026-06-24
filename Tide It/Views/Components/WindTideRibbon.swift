//
//  WindTideRibbon.swift
//  Tide It
//
//  KILLER FEATURE — ruban fusionné VENT + MARÉE sur un axe de temps partagé.
//  La courbe de vent (force + rafales + incertitude multi-modèles) et la courbe de
//  marée (hauteur d'eau) partagent le même temps. Les fenêtres « GO » s'illuminent
//  là où TOUT s'aligne : vent dans la plage du rider + assez d'eau + de jour.
//  Le point de vent OBSERVÉ (balise) est posé sur « maintenant » → confronte la
//  prévision au réel et révèle le biais du modèle sur le spot.
//
//  100 % offline : tout est calculé à partir des données déjà chargées
//  (HourlyForecast multi-modèles Open-Meteo + marées du moteur harmonique).
//

import SwiftUI

// MARK: - Échelle de couleur du vent (Beaufort lissé, autonome)

enum WindPalette {
    /// Couleur du vent selon la force (km/h) : bleu calme → rouge tempête.
    static func color(_ kmh: Double) -> Color {
        let stops: [(Double, Color)] = [
            (0,  Color(red: 0.23, green: 0.48, blue: 0.84)),
            (8,  Color(red: 0.24, green: 0.79, blue: 0.63)),
            (15, Color(red: 0.75, green: 0.88, blue: 0.31)),
            (25, Color(red: 0.94, green: 0.71, blue: 0.31)),
            (35, Color(red: 0.89, green: 0.38, blue: 0.29)),
            (50, Color(red: 0.85, green: 0.22, blue: 0.20)),
        ]
        if kmh <= stops.first!.0 { return stops.first!.1 }
        if kmh >= stops.last!.0 { return stops.last!.1 }
        for i in 0..<(stops.count - 1) {
            let (x0, c0) = stops[i], (x1, c1) = stops[i + 1]
            if kmh >= x0 && kmh <= x1 {
                let t = (kmh - x0) / (x1 - x0)
                return c0.lerp(to: c1, t: t)
            }
        }
        return stops.last!.1
    }
}

private extension Color {
    func lerp(to other: Color, t: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r0, g0, b0, a0): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
        b.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        let k = CGFloat(max(0, min(1, t)))
        return Color(red: Double(r0 + (r1 - r0) * k),
                     green: Double(g0 + (g1 - g0) * k),
                     blue: Double(b0 + (b1 - b0) * k))
    }
}

// MARK: - Logique de planification (pure → testable, hors UI)

/// Fenêtre « GO » : intervalle où le vent prévu ∈ plage rider ET il fait jour.
struct GoWindow: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    static func == (l: GoWindow, r: GoWindow) -> Bool { l.start == r.start && l.end == r.end }
}

enum WindTidePlanner {

    /// Direction cardinale (FR, 8 secteurs) depuis un cap « FROM » en degrés.
    static func cardinal(_ fromDeg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let idx = Int((fromDeg.truncatingRemainder(dividingBy: 360) + 360 + 22.5)
            .truncatingRemainder(dividingBy: 360) / 45) % 8
        return dirs[idx]
    }

    /// Vrai s'il fait jour à `date` (entre lever et coucher du jour correspondant).
    static func isDaylight(_ date: Date, sunTimes: [(sunrise: Date, sunset: Date)]) -> Bool {
        guard !sunTimes.isEmpty else { return true }   // pas d'info → on n'exclut pas
        for s in sunTimes where date >= s.sunrise && date <= s.sunset { return true }
        return false
    }

    /// Écart angulaire (0–180°) entre deux caps en degrés.
    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        abs(((a - b + 540).truncatingRemainder(dividingBy: 360)) - 180)
    }

    /// Fenêtres GO : heures consécutives où minKmh ≤ vent prévu ≤ maxKmh ET de jour.
    /// Si `minWaterHeight` est fourni (spot à seuil, ex. bassin), on exige EN PLUS assez
    /// d'eau : `tideHeightAt(date) ≥ minWaterHeight` (gate dur). Hauteur inconnue → par défaut
    /// on ne bloque pas (fail-open : ne pas masquer les GO quand la marée n'est pas dispo).
    /// `blockWhenWaterUnknown: true` rend le gate FAIL-SAFE (hauteur inconnue → hors GO) pour
    /// les activités où l'eau est critique (foils, mise à l'eau) → pas de fausse fenêtre.
    /// Si `shoreOrientation` est fourni (cap de la mer vu du spot), on EXCLUT le vent de terre
    /// (offshore = dangereux) : vent venant de `orientation+180 ± offshoreHalfWidth` → hors GO.
    static func goWindows(forecasts: [HourlyForecast],
                          minKmh: Double, maxKmh: Double,
                          sunTimes: [(sunrise: Date, sunset: Date)],
                          minWaterHeight: Double? = nil,
                          tideHeightAt: ((Date) -> Double?)? = nil,
                          shoreOrientation: Double? = nil,
                          offshoreHalfWidth: Double = 45,
                          blockWhenWaterUnknown: Bool = false) -> [GoWindow] {
        let sorted = forecasts.sorted { $0.time < $1.time }
        var windows: [GoWindow] = []
        var runStart: Date?
        var lastOK: Date?
        let offshoreDir = shoreOrientation.map { ($0 + 180).truncatingRemainder(dividingBy: 360) }
        for f in sorted {
            var ok = f.windSpeedKmh >= minKmh && f.windSpeedKmh <= maxKmh
                && isDaylight(f.time, sunTimes: sunTimes)
            if ok, let off = offshoreDir, angularDistance(f.windDirection, off) <= offshoreHalfWidth {
                ok = false   // vent de terre (offshore) → dangereux, hors fenêtre GO
            }
            if ok, let minH = minWaterHeight {
                if let h = tideHeightAt?(f.time) {
                    ok = h >= minH                  // pas assez d'eau → hors fenêtre GO
                } else if blockWhenWaterUnknown {
                    ok = false                      // hauteur inconnue + eau critique → on bloque (sécurité)
                }
            }
            if ok {
                if runStart == nil { runStart = f.time }
                lastOK = f.time
            } else if let s = runStart, let e = lastOK {
                windows.append(GoWindow(start: s, end: e.addingTimeInterval(3600)))
                runStart = nil; lastOK = nil
            }
        }
        if let s = runStart, let e = lastOK {
            windows.append(GoWindow(start: s, end: e.addingTimeInterval(3600)))
        }
        // On comble les brefs creux (≤ maxGap) AVANT de filtrer : une perte de vent d'1 h
        // ne doit pas fragmenter une session. Puis on ne garde que les fenêtres ≥ 1 h.
        return bridgeBriefGaps(windows).filter { $0.end.timeIntervalSince($0.start) >= 3600 }
    }

    /// Fusionne deux fenêtres séparées par un trou ≤ `maxGap` (ex. un creux de vent d'1 h) →
    /// évite de fragmenter une session pour une brève perte. Fenêtres triées par début.
    static func bridgeBriefGaps(_ windows: [GoWindow], maxGap: TimeInterval = 3600) -> [GoWindow] {
        guard windows.count > 1 else { return windows }
        let sorted = windows.sorted { $0.start < $1.start }
        var merged: [GoWindow] = [sorted[0]]
        for w in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if w.start.timeIntervalSince(last.end) <= maxGap {
                merged[merged.count - 1] = GoWindow(start: last.start, end: max(last.end, w.end))
            } else {
                merged.append(w)
            }
        }
        return merged
    }
}

// MARK: - Géométrie temps→x partagée

private struct RibbonGeometry {
    let start: Date
    let pxPerHour: CGFloat
    func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(start) / 3600) * pxPerHour }
    func totalWidth(end: Date) -> CGFloat { max(x(end), 1) }
}

// MARK: - Le ruban fusionné (Canvas)

/// Vue Canvas dessinant vent (haut) + marée (bas) sur un temps partagé, avec fenêtres
/// GO, jour/nuit, ligne « maintenant » et point observé. Largeur = toute la prévision
/// (placée dans un ScrollView horizontal par l'appelant).
struct WindTideChart: View {
    let forecasts: [HourlyForecast]
    let tideData: [TideData]
    let sunTimes: [(sunrise: Date, sunset: Date)]
    let now: Date
    let minKmh: Double
    let maxKmh: Double
    let observedKmh: Double?
    let observedDirDeg: Double?
    let portTimeZone: TimeZone
    var pxPerHour: CGFloat = 9
    var height: CGFloat = 210

    private var sortedForecasts: [HourlyForecast] { forecasts.sorted { $0.time < $1.time } }

    var body: some View {
        let fc = sortedForecasts
        if fc.count >= 2 {
            let start = fc.first!.time
            let end = fc.last!.time
            let geo = RibbonGeometry(start: start, pxPerHour: pxPerHour)
            let width = geo.totalWidth(end: end)
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, fc: fc, geo: geo)
            }
            .frame(width: width, height: height)
        } else {
            Color.clear.frame(height: height)
        }
    }

    // Zones verticales
    private var windTop: CGFloat { 22 }
    private var windBottom: CGFloat { height * 0.46 }
    private var tideTop: CGFloat { height * 0.56 }
    private var tideBottom: CGFloat { height - 26 }

    private func draw(ctx: GraphicsContext, size: CGSize, fc: [HourlyForecast], geo: RibbonGeometry) {
        // Échelle vent (force + rafales)
        let maxWind = max(40, (fc.map { max($0.windSpeedKmh, $0.windGustKmh ?? 0) }.max() ?? 40) * 1.05)
        func windY(_ kmh: Double) -> CGFloat {
            windBottom - CGFloat(min(kmh, maxWind) / maxWind) * (windBottom - windTop)
        }
        // Échelle marée
        let heights = tideData.map(\.height)
        let lo = (heights.min() ?? 0) - 0.2
        let hi = (heights.max() ?? 5) + 0.2
        func tideY(_ h: Double) -> CGFloat {
            guard hi > lo else { return tideBottom }
            return tideBottom - CGFloat((h - lo) / (hi - lo)) * (tideBottom - tideTop)
        }

        // 1) Jour / nuit (nuit grisée)
        drawNight(ctx: ctx, geo: geo, start: fc.first!.time, end: fc.last!.time)

        // 2) Fenêtres GO (colonnes vertes pleine hauteur)
        let gos = WindTidePlanner.goWindows(forecasts: fc, minKmh: minKmh, maxKmh: maxKmh, sunTimes: sunTimes)
        for g in gos {
            let x0 = geo.x(g.start), x1 = geo.x(g.end)
            let rect = CGRect(x: x0, y: 2, width: max(x1 - x0, 2), height: height - 28)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 6),
                     with: .color(Color(red: 0.31, green: 0.88, blue: 0.63).opacity(0.13)))
        }

        // 3) Bande plage rider (zone vent)
        let bandRect = CGRect(x: 0, y: windY(maxKmh), width: size.width, height: windY(minKmh) - windY(maxKmh))
        ctx.fill(Path(bandRect), with: .color(Color(red: 0.31, green: 0.88, blue: 0.63).opacity(0.07)))

        // 4) Courbe de marée (remplie + trait cyan→violet)
        drawTide(ctx: ctx, geo: geo, tideY: tideY)

        // 5) Rafales (pointillé)
        var gustPath = Path()
        var started = false
        for f in fc {
            guard let g = f.windGustKmh else { continue }
            let p = CGPoint(x: geo.x(f.time), y: windY(g))
            if started { gustPath.addLine(to: p) } else { gustPath.move(to: p); started = true }
        }
        ctx.stroke(gustPath, with: .color(Color.white.opacity(0.35)),
                   style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))

        // 6) Courbe de vent — segments colorés par force (Beaufort)
        for i in 0..<(fc.count - 1) {
            let a = fc[i], b = fc[i + 1]
            var seg = Path()
            seg.move(to: CGPoint(x: geo.x(a.time), y: windY(a.windSpeedKmh)))
            seg.addLine(to: CGPoint(x: geo.x(b.time), y: windY(b.windSpeedKmh)))
            let avg = (a.windSpeedKmh + b.windSpeedKmh) / 2
            ctx.stroke(seg, with: .color(WindPalette.color(avg)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }

        // 7) Ligne « maintenant » + point observé
        let nowX = geo.x(now)
        if nowX >= 0 && nowX <= size.width {
            var nl = Path()
            nl.move(to: CGPoint(x: nowX, y: 2)); nl.addLine(to: CGPoint(x: nowX, y: height - 26))
            ctx.stroke(nl, with: .color(Color(red: 0.31, green: 0.82, blue: 0.88).opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            if let obs = observedKmh {
                let p = CGPoint(x: nowX, y: windY(obs))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                         with: .color(Color(red: 0.31, green: 0.82, blue: 0.88)))
            }
        }

        // 8) Repères jours (minuit) + PM/coef
        drawDayTicks(ctx: ctx, geo: geo, start: fc.first!.time, end: fc.last!.time)
    }

    private func drawTide(ctx: GraphicsContext, geo: RibbonGeometry, tideY: (Double) -> CGFloat) {
        let sorted = tideData.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return }
        // Échantillonne la courbe lissée (interpolation cosinus via TideCalculator).
        var pts: [CGPoint] = []
        let first = sorted.first!.date, last = sorted.last!.date
        var t = max(first, geo.start.addingTimeInterval(-3600))
        let step: TimeInterval = 1800
        while t <= last {
            if let st = TideCalculator.currentState(at: t, sortedTides: sorted) {
                pts.append(CGPoint(x: geo.x(t), y: tideY(st.currentHeight)))
            }
            t = t.addingTimeInterval(step)
        }
        guard pts.count >= 2 else { return }
        var line = Path(); line.addLines(pts)
        var fill = line; fill.addLine(to: CGPoint(x: pts.last!.x, y: tideBottom))
        fill.addLine(to: CGPoint(x: pts.first!.x, y: tideBottom)); fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [Color(red: 0.47, green: 0.55, blue: 0.90).opacity(0.30),
                              Color(red: 0.47, green: 0.55, blue: 0.90).opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: tideTop), endPoint: CGPoint(x: 0, y: tideBottom)))
        ctx.stroke(line, with: .linearGradient(
            Gradient(colors: [Color(red: 0.31, green: 0.82, blue: 0.88),
                              Color(red: 0.63, green: 0.42, blue: 0.85)]),
            startPoint: .zero, endPoint: CGPoint(x: geo.totalWidth(end: last), y: 0)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
    }

    private func drawNight(ctx: GraphicsContext, geo: RibbonGeometry, start: Date, end: Date) {
        guard !sunTimes.isEmpty else { return }
        let nightColor = Color.black.opacity(0.28)
        // Avant le 1er lever, après chaque coucher jusqu'au lever suivant.
        let sorted = sunTimes.sorted { $0.sunrise < $1.sunrise }
        for (i, s) in sorted.enumerated() {
            let nextSunrise = i + 1 < sorted.count ? sorted[i + 1].sunrise : end
            let x0 = geo.x(s.sunset), x1 = geo.x(nextSunrise)
            if x1 > 0 && x0 < geo.x(end) {
                ctx.fill(Path(CGRect(x: max(x0, 0), y: 0, width: max(x1 - x0, 0), height: height - 26)),
                         with: .color(nightColor))
            }
        }
        if let firstSr = sorted.first?.sunrise, geo.x(firstSr) > 0 {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: geo.x(firstSr), height: height - 26)),
                     with: .color(nightColor))
        }
    }

    private func drawDayTicks(ctx: GraphicsContext, geo: RibbonGeometry, start: Date, end: Date) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = portTimeZone
        let fmt = CachedDateFormatter.make("EEE d", timeZone: portTimeZone)
        var day = cal.startOfDay(for: start)
        while day <= end {
            let x = geo.x(day)
            if x > 4 {
                var tick = Path(); tick.move(to: CGPoint(x: x, y: 2)); tick.addLine(to: CGPoint(x: x, y: height - 26))
                ctx.stroke(tick, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                ctx.draw(Text(fmt.string(from: day).capitalized)
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.45)),
                    at: CGPoint(x: x + 3, y: height - 14), anchor: .leading)
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? end.addingTimeInterval(1)
        }
    }
}

// MARK: - Verdict par jour

struct DayVerdict: Identifiable {
    enum Status { case go, marginal, none }
    let id = UUID()
    let date: Date
    let label: String
    let status: Status
    let detail: String
}

extension WindTidePlanner {
    /// Construit un verdict synthétique par jour (à partir des fenêtres GO + marée).
    static func dayVerdicts(forecasts: [HourlyForecast], tideData: [TideData],
                            sunTimes: [(sunrise: Date, sunset: Date)],
                            minKmh: Double, maxKmh: Double,
                            windUnit: WindSpeedUnit, portTimeZone: TimeZone,
                            maxDays: Int = 7) -> [DayVerdict] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = portTimeZone
        let gos = goWindows(forecasts: forecasts, minKmh: minKmh, maxKmh: maxKmh, sunTimes: sunTimes)
        let byDay = Dictionary(grouping: forecasts) { cal.startOfDay(for: $0.time) }
        let labelFmt = DateFormatter(); labelFmt.timeZone = portTimeZone; labelFmt.dateFormat = "EEE d"
        let hourFmt = DateFormatter(); hourFmt.timeZone = portTimeZone; hourFmt.dateFormat = "HH'h'"
        let today = cal.startOfDay(for: Date())

        return byDay.keys.sorted().prefix(maxDays).map { day -> DayVerdict in
            let label: String
            if cal.isDate(day, inSameDayAs: today) { label = "Auj." }
            else if let tom = cal.date(byAdding: .day, value: 1, to: today), cal.isDate(day, inSameDayAs: tom) { label = "Demain" }
            else { label = labelFmt.string(from: day).capitalized }

            let dayEnd = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let hours = (byDay[day] ?? []).sorted { $0.time < $1.time }
            let maxW = hours.map(\.windSpeedKmh).max() ?? 0

            // Fenêtre GO du jour (la plus longue)
            let dayGo = gos.filter { $0.start < dayEnd && $0.end > day }
                .max { ($0.end.timeIntervalSince($0.start)) < ($1.end.timeIntervalSince($1.start)) }

            if let g = dayGo {
                // Vent + direction pendant la fenêtre
                let inWin = hours.filter { $0.time >= g.start && $0.time < g.end }
                let lo = Int((inWin.map(\.windSpeedKmh).min() ?? minKmh).rounded())
                let hi = Int((inWin.map(\.windSpeedKmh).max() ?? maxKmh).rounded())
                let loU = UnitFormatter.windSpeedInt(Double(lo), unit: windUnit)
                let hiU = UnitFormatter.windSpeedInt(Double(hi), unit: windUnit)
                let dir = inWin.last.map { cardinal($0.windDirection) } ?? ""
                // Eau basse pendant la fenêtre ? (sous le tiers inférieur du marnage du jour)
                let lowWater = isLowWater(during: g, tideData: tideData)
                let win = "\(hourFmt.string(from: g.start))–\(hourFmt.string(from: g.end))"
                if lowWater {
                    return DayVerdict(date: day, label: label, status: .marginal,
                                      detail: "\(loU)–\(hiU) \(dir) \(win) · marée basse")
                }
                return DayVerdict(date: day, label: label, status: .go,
                                  detail: "GO \(win) · \(loU)–\(hiU) \(dir)")
            }
            // Pas de fenêtre : pourquoi ?
            let maxU = UnitFormatter.windSpeedInt(maxW, unit: windUnit)
            if maxW < minKmh {
                return DayVerdict(date: day, label: label, status: .none, detail: "trop faible · max \(maxU)")
            }
            return DayVerdict(date: day, label: label, status: .marginal, detail: "max \(maxU) (hors jour ou trop fort)")
        }
    }

    /// Eau « basse » pendant la fenêtre : hauteur médiane < tiers inférieur du marnage global.
    static func isLowWater(during window: GoWindow, tideData: [TideData]) -> Bool {
        let sorted = tideData.sorted { $0.date < $1.date }
        guard let lo = sorted.map(\.height).min(), let hi = sorted.map(\.height).max(), hi > lo else { return false }
        let threshold = lo + (hi - lo) / 3
        let mid = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
        guard let st = TideCalculator.currentState(at: mid, sortedTides: sorted) else { return false }
        return st.currentHeight < threshold
    }

    /// Vitesse de vent prévue interpolée à `date` (linéaire entre les 2 heures encadrantes).
    static func forecastWind(at date: Date, forecasts: [HourlyForecast]) -> Double? {
        let sorted = forecasts.sorted { $0.time < $1.time }
        guard let after = sorted.first(where: { $0.time >= date }) else { return sorted.last?.windSpeedKmh }
        guard let before = sorted.last(where: { $0.time <= date }) else { return after.windSpeedKmh }
        let span = after.time.timeIntervalSince(before.time)
        if span <= 0 { return before.windSpeedKmh }
        let t = date.timeIntervalSince(before.time) / span
        return before.windSpeedKmh + (after.windSpeedKmh - before.windSpeedKmh) * t
    }
}

// MARK: - Météo (icône WMO + couleur température)

enum WeatherGlyph {
    /// (symbole SF, couleur) pour un code météo WMO.
    static func symbol(_ code: Int?) -> (String, Color) {
        switch code ?? -1 {
        case 0:        return ("sun.max.fill", Color(red: 0.98, green: 0.80, blue: 0.25))
        case 1, 2:     return ("cloud.sun.fill", Color(red: 0.92, green: 0.78, blue: 0.40))
        case 3:        return ("cloud.fill", Color(white: 0.78))
        case 45, 48:   return ("cloud.fog.fill", Color(white: 0.70))
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", Color(red: 0.46, green: 0.66, blue: 0.92))
        case 61, 63, 65, 66, 67, 80, 81, 82: return ("cloud.rain.fill", Color(red: 0.36, green: 0.60, blue: 0.95))
        case 71, 73, 75, 77, 85, 86: return ("cloud.snow.fill", Color(white: 0.88))
        case 95, 96, 99: return ("cloud.bolt.rain.fill", Color(red: 0.70, green: 0.56, blue: 0.95))
        default:       return ("cloud.fill", Color(white: 0.7))
        }
    }

    /// Couleur de température (bleu froid → rouge chaud).
    static func tempColor(_ c: Double) -> Color {
        switch c {
        case ..<2:   return Color(red: 0.40, green: 0.62, blue: 0.95)
        case ..<9:   return Color(red: 0.35, green: 0.78, blue: 0.85)
        case ..<15:  return Color(red: 0.33, green: 0.82, blue: 0.66)
        case ..<21:  return Color(red: 0.55, green: 0.82, blue: 0.40)
        case ..<26:  return Color(red: 0.94, green: 0.80, blue: 0.30)
        case ..<31:  return Color(red: 0.95, green: 0.62, blue: 0.28)
        default:     return Color(red: 0.92, green: 0.40, blue: 0.32)
        }
    }
}

/// Bande météo (temp + icône + pluie) ALIGNÉE sous le ruban : mêmes start + pxPerHour
/// que `WindTideChart` → chaque colonne 3 h tombe pile sous la courbe.
struct WeatherStrip: View {
    let forecasts: [HourlyForecast]
    let pxPerHour: CGFloat
    let portTimeZone: TimeZone
    @ObservedObject var themeManager: ThemeManager

    var body: some View {
        let sorted = forecasts.sorted { $0.time < $1.time }
        let cal = Calendar.inTimeZone(portTimeZone)
        if let start = sorted.first?.time, let end = sorted.last?.time {
            let width = CGFloat(end.timeIntervalSince(start) / 3600) * pxPerHour
            let colW = 3 * pxPerHour
            let slots = sorted.filter { cal.component(.hour, from: $0.time) % 3 == 0 }
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.time) { f in
                    let x = CGFloat(f.time.timeIntervalSince(start) / 3600) * pxPerHour
                    column(f).frame(width: colW).offset(x: x - colW / 2)
                }
            }
            .frame(width: width, height: 56, alignment: .topLeading)
        }
    }

    @ViewBuilder private func column(_ f: HourlyForecast) -> some View {
        let glyph = WeatherGlyph.symbol(f.weatherCode)
        VStack(spacing: 3) {
            if let t = f.temperature {
                Text(UnitFormatter.temp(t, system: themeManager.measureSystem))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(WeatherGlyph.tempColor(t))
            }
            Image(systemName: glyph.0).symbolRenderingMode(.multicolor)
                .font(.system(size: 14)).foregroundStyle(glyph.1)
            if let p = f.precipitationProbability, p >= 20 {
                Text("\(Int(p))%").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.66, blue: 0.95))
            }
        }
    }
}

// MARK: - Ruban inline (bas de Today) + tap → détail

struct WindTideRibbon: View {
    let forecasts: [HourlyForecast]
    let tideData: [TideData]
    let sunTimes: [(sunrise: Date, sunset: Date)]
    let now: Date
    let observedKmh: Double?
    let observedDirDeg: Double?
    let portName: String
    let portTimeZone: TimeZone
    @ObservedObject var themeManager: ThemeManager
    @State private var showDetail = false

    private var unit: WindSpeedUnit { themeManager.windUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Vent, marée & météo").font(.scaled(size: DS.fontTitle3, weight: .semibold))
                Spacer()
                Label("\(UnitFormatter.windSpeedInt(themeManager.riderMinWindKmh, unit: unit))–\(UnitFormatter.windSpeedInt(themeManager.riderMaxWindKmh, unit: unit)) \(unit.label)",
                      systemImage: "slider.horizontal.3")
                    .font(.scaled(size: DS.fontCaption, weight: .medium))
                    .foregroundStyle(Color.tideHigh)
            }

            confrontationRow

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    WindTideChart(
                        forecasts: forecasts, tideData: tideData, sunTimes: sunTimes, now: now,
                        minKmh: themeManager.riderMinWindKmh, maxKmh: themeManager.riderMaxWindKmh,
                        observedKmh: observedKmh, observedDirDeg: observedDirDeg,
                        portTimeZone: portTimeZone, pxPerHour: 15, height: 190)
                    WeatherStrip(forecasts: forecasts, pxPerHour: 15,
                                 portTimeZone: portTimeZone, themeManager: themeManager)
                }
                .padding(.trailing, 14)
            }

            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right").font(.system(size: 10))
                Text("glisse pour la semaine · tape pour le détail")
            }
            .font(.scaled(size: DS.fontCaption2, weight: .regular))
            .foregroundStyle(.secondary)
        }
        .glassCard(accentColor: Color.tideHigh, padding: 14)
        .contentShape(Rectangle())
        .onTapGesture { HapticManager.shared.impact(.light); showDetail = true }
        .sheet(isPresented: $showDetail) {
            WindDetailSheet(
                forecasts: forecasts, tideData: tideData, sunTimes: sunTimes, now: now,
                observedKmh: observedKmh, observedDirDeg: observedDirDeg,
                portName: portName, portTimeZone: portTimeZone, themeManager: themeManager)
        }
    }

    @ViewBuilder private var confrontationRow: some View {
        let predicted = WindTidePlanner.forecastWind(at: now, forecasts: forecasts)
        HStack(spacing: 8) {
            miniStat("prévu", predicted.map { UnitFormatter.windSpeedInt($0, unit: unit) }, accent: Color.tideHigh)
            miniStat("observé", observedKmh.map { UnitFormatter.windSpeedInt($0, unit: unit) }, accent: Color(red: 0.49, green: 0.42, blue: 0.87), live: observedKmh != nil)
            if let p = predicted, let o = observedKmh, o > 0 {
                biasChip(predicted: p, observed: o)
            }
        }
    }

    private func miniStat(_ label: String, _ value: Int?, accent: Color, live: Bool = false) -> some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(label).font(.scaled(size: DS.fontCaption2)).foregroundStyle(.secondary)
                    if live { Circle().fill(Color(red: 0.31, green: 0.88, blue: 0.63)).frame(width: 5, height: 5) }
                }
                Text(value.map { "\($0)" } ?? "—").font(.system(size: 19, weight: .semibold, design: .rounded))
                    + Text(" \(unit.label)").font(.scaled(size: DS.fontCaption2)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder private func biasChip(predicted: Double, observed: Double) -> some View {
        let ratio = observed / predicted
        let pct = Int(((ratio - 1) * 100).rounded())
        let text: String = abs(pct) < 8 ? "modèle fiable ici"
            : (pct < 0 ? "modèle +\(-pct)% optimiste" : "modèle −\(pct)% pessimiste")
        let color: Color = abs(pct) < 8 ? Color(red: 0.31, green: 0.88, blue: 0.63) : Color(red: 0.94, green: 0.71, blue: 0.31)
        HStack(spacing: 5) {
            Image(systemName: abs(pct) < 8 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").font(.system(size: 12))
            Text(text).font(.scaled(size: DS.fontCaption2, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(color)
        .padding(.vertical, 7).padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: - Vue détail plein écran

struct WindDetailSheet: View {
    let forecasts: [HourlyForecast]
    let tideData: [TideData]
    let sunTimes: [(sunrise: Date, sunset: Date)]
    let now: Date
    let observedKmh: Double?
    let observedDirDeg: Double?
    let portName: String
    let portTimeZone: TimeZone
    @ObservedObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    private var unit: WindSpeedUnit { themeManager.windUnit }

    private var verdicts: [DayVerdict] {
        WindTidePlanner.dayVerdicts(
            forecasts: forecasts, tideData: tideData, sunTimes: sunTimes,
            minKmh: themeManager.riderMinWindKmh, maxKmh: themeManager.riderMaxWindKmh,
            windUnit: unit, portTimeZone: portTimeZone)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    legend
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            WindTideChart(
                                forecasts: forecasts, tideData: tideData, sunTimes: sunTimes, now: now,
                                minKmh: themeManager.riderMinWindKmh, maxKmh: themeManager.riderMaxWindKmh,
                                observedKmh: observedKmh, observedDirDeg: observedDirDeg,
                                portTimeZone: portTimeZone, pxPerHour: 20, height: 280)
                            WeatherStrip(forecasts: forecasts, pxPerHour: 20,
                                         portTimeZone: portTimeZone, themeManager: themeManager)
                        }
                        .padding(.trailing, 14)
                    }
                    rangeSliders
                    verdictList
                }
                .padding(16)
            }
            .navigationTitle("Vent & marée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(portName).font(.scaled(size: DS.fontCaption, weight: .medium))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: Color.tideHigh, "vent")
            legendItem(color: .white.opacity(0.5), "rafales", dashed: true)
            legendItem(color: Color(red: 0.31, green: 0.88, blue: 0.63), "fenêtre GO")
            Spacer()
        }
        .font(.scaled(size: DS.fontCaption2))
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: dashed ? 2 : 3)
                .opacity(dashed ? 0.7 : 1)
            Text(label)
        }
    }

    private var rangeSliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ma plage praticable").font(.scaled(size: DS.fontBody, weight: .semibold))
            sliderRow(title: "Mini", value: $themeManager.riderMinWindKmh, range: 5...40,
                      cap: themeManager.riderMaxWindKmh - 3)
            sliderRow(title: "Maxi", value: $themeManager.riderMaxWindKmh, range: 20...90,
                      floor: themeManager.riderMinWindKmh + 3)
            Text("Les fenêtres GO s'allument quand le vent prévu reste dans ta plage, de jour.")
                .font(.scaled(size: DS.fontCaption2)).foregroundStyle(.secondary)
        }
        .padding(14)
        .glassCard(accentColor: Color.tideHigh, padding: 14)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           cap: Double = .greatestFiniteMagnitude, floor: Double = -.greatestFiniteMagnitude) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.scaled(size: DS.fontCaption, weight: .medium)).frame(width: 38, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(max($0, floor), cap) }
            ), in: range, step: 1).tint(Color.tideHigh)
            Text("\(UnitFormatter.windSpeedInt(value.wrappedValue, unit: unit)) \(unit.label)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var verdictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Par jour").font(.scaled(size: DS.fontBody, weight: .semibold))
            ForEach(verdicts) { v in
                HStack(spacing: 10) {
                    Circle().fill(statusColor(v.status)).frame(width: 9, height: 9)
                    Text(v.label).font(.scaled(size: DS.fontBody, weight: .medium)).frame(width: 64, alignment: .leading)
                    Text(v.detail).font(.scaled(size: DS.fontCaption, weight: .regular)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(statusColor(v.status).opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private func statusColor(_ s: DayVerdict.Status) -> Color {
        switch s {
        case .go: return Color(red: 0.31, green: 0.88, blue: 0.63)
        case .marginal: return Color(red: 0.94, green: 0.71, blue: 0.31)
        case .none: return Color(red: 0.89, green: 0.38, blue: 0.29)
        }
    }

}


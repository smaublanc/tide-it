//
//  WeekSummaryView.swift
//  Tide It
//
//  « Tendance 7 jours » — rubans couleur pleine largeur (vent, + houle sur un spot de surf),
//  segmentés par jour, pour lire la semaine d'un coup d'œil façon app de vent.
//
//  ⚠️ Ce bloc vivait dans une bottom sheet ouverte depuis le menu (« Résumé 7 jours »). Il est
//  désormais posé DIRECTEMENT dans la vue principale, sous les infos de la balise vent : la
//  tendance de la semaine est une info de coup d'œil, la mettre derrière deux taps (menu →
//  entrée) coûtait plus d'interactions qu'elle n'en valait. Un spot classique montre 1 ruban
//  (vent), un spot de surf en montre 2 (vent + houle).
//
//  Données = cache MarineWeatherService partagé → présentation pure, aucun fetch ici.
//  Couleurs vent réutilisées de PremiumCurveCanvas (source unique).
//

import SwiftUI

struct WeekTrendBands: View, Equatable {
    let forecasts: [HourlyForecast]
    /// Spot de surf → second ruban « Houle ». Un port classique n'affiche que le vent.
    let isSurfSpot: Bool

    private let days = 7

    /// Re-rendu uniquement si les prévisions ou le type de spot changent (le curseur
    /// « maintenant » n'a pas besoin d'une précision supérieure à l'heure).
    static func == (lhs: WeekTrendBands, rhs: WeekTrendBands) -> Bool {
        lhs.isSurfSpot == rhs.isSurfSpot && lhs.forecasts == rhs.forecasts
    }

    private var window: [HourlyForecast] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return [] }
        return forecasts.filter { $0.time >= start && $0.time < end }.sorted { $0.time < $1.time }
    }

    private var cursorFrac: Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return 0 }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(start) / span, 0), 1)
    }

    /// Y a-t-il une vraie donnée de houle ? Sans elle, PAS de ruban « Houle » — plutôt qu'une
    /// bande uniforme à 0 m qui se lirait comme une mer plate mesurée (règle d'honnêteté).
    private var hasSwellData: Bool {
        window.contains { ($0.swellHeight ?? $0.waveHeight) != nil }
    }

    var body: some View {
        // Rien à montrer sans au moins deux points : le bloc DISPARAÎT (pas de cadre vide).
        if window.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    dayHeader
                    band(title: "Vent", icon: "wind", tint: Color(red: 0.5, green: 0.84, blue: 0.9),
                         colors: window.map { PremiumCurveCanvas.windColorSmooth($0.windSpeedKmh) },
                         trailing: windRange)
                }
                if isSurfSpot, hasSwellData {
                    band(title: "Houle", icon: "water.waves", tint: Color(red: 0.37, green: 0.79, blue: 0.65),
                         colors: window.map { swellColor($0.swellHeight ?? $0.waveHeight ?? 0) },
                         trailing: swellRange)
                }
                footnote
            }
        }
    }

    // MARK: pièces

    private var dayHeader: some View {
        let accent = Color(red: 0.37, green: 0.79, blue: 0.65)
        return HStack(spacing: 0) {
            ForEach(dayLabels) { lbl in
                VStack(spacing: 0) {
                    Text(lbl.wd).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(lbl.weekend ? accent : Color.primary.opacity(0.85))
                    Text(lbl.day).font(.system(size: 10))
                        .foregroundStyle(lbl.weekend ? accent.opacity(0.7) : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)   // l'échelle de jours est décrite par le libellé du ruban
    }

    private func band(title: LocalizedStringKey, icon: String, tint: Color,
                      colors: [Color], trailing: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForecastRibbon(colors: colors, cursorFrac: cursorFrac, daySegments: days)
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                Spacer()
                Text(trailing).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        // VoiceOver : une phrase, pas un ruban muet suivi de nombres orphelins.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(String(localized: "tendance sur 7 jours, de \(trailing)")))
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Circle().stroke(Color.primary.opacity(0.8), lineWidth: 1.8).frame(width: 8, height: 8)
            Text("maintenant").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("tendance · 7 j").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .accessibilityHidden(true)
    }

    // MARK: données dérivées

    private var dayLabels: [DayCol] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        // Jour court LOCALISÉ (≈ 2 lettres) : JE/VE en fr, Mo/Di en de, Th/Fr en en…
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("EEEEEE")
        return (0..<days).compactMap { off in
            guard let d = cal.date(byAdding: .day, value: off, to: start) else { return nil }
            let wd = fmt.string(from: d).uppercased().replacingOccurrences(of: ".", with: "")
            return DayCol(id: off, wd: wd, day: "\(cal.component(.day, from: d))", weekend: cal.isDateInWeekend(d))
        }
    }

    private var windRange: String {
        let unit = ThemeManager.shared.windUnit
        let vals = window.map { $0.windSpeedKmh }
        let lo = UnitFormatter.windSpeedInt(vals.min() ?? 0, unit: unit)
        let hi = UnitFormatter.windSpeedInt(vals.max() ?? 0, unit: unit)
        return "\(lo)–\(hi) \(unit.label)"
    }

    private var swellRange: String {
        let sys = ThemeManager.shared.measureSystem
        let vals = window.compactMap { $0.swellHeight ?? $0.waveHeight }
        let unit = sys == .imperial ? "ft" : "m"
        let lo = UnitFormatter.height(vals.min() ?? 0, system: sys, decimals: 1).replacingOccurrences(of: " \(unit)", with: "")
        let hi = UnitFormatter.height(vals.max() ?? 0, system: sys, decimals: 1).replacingOccurrences(of: " \(unit)", with: "")
        return "\(lo)–\(hi) \(unit)"
    }
}

private struct DayCol: Identifiable {
    let id: Int
    let wd: String
    let day: String
    let weekend: Bool
}

// MARK: - Ruban couleur (Canvas)

private struct ForecastRibbon: View {
    let colors: [Color]
    let cursorFrac: Double
    var daySegments: Int = 7

    var body: some View {
        Canvas { ctx, size in
            let n = colors.count
            guard n > 1 else { return }
            let cw = size.width / CGFloat(n)
            for i in 0..<n {
                ctx.fill(Path(CGRect(x: CGFloat(i) * cw, y: 0, width: cw + 0.8, height: size.height)),
                         with: .color(colors[i]))
            }
            // Traits fins de séparation par jour (6 frontières pour 7 jours).
            if daySegments > 1 {
                for k in 1..<daySegments {
                    let x = CGFloat(k) / CGFloat(daySegments) * size.width
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                             with: .color(.white.opacity(0.28)))
                }
            }
            let cx = CGFloat(cursorFrac) * size.width
            ctx.fill(Path(CGRect(x: cx - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.2)))
            let r: CGFloat = 6
            let ring = CGRect(x: cx - r, y: size.height / 2 - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: ring), with: .color(.black.opacity(0.42)))
            ctx.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 2.2)
        }
    }
}

// MARK: - Rampe couleur HOULE (hauteur, m) : ardoise → teal → vert → ambre → orange

private func swellColor(_ meters: Double) -> Color {
    let stops: [(Double, (Double, Double, Double))] = [
        (0.0, (0.11, 0.22, 0.28)),
        (0.6, (0.12, 0.49, 0.51)),
        (1.2, (0.31, 0.73, 0.38)),
        (1.8, (0.88, 0.60, 0.16)),
        (2.6, (0.91, 0.45, 0.18))
    ]
    let v = max(0, meters)
    if v <= stops[0].0 { let c = stops[0].1; return Color(red: c.0, green: c.1, blue: c.2) }
    for i in 1..<stops.count where v <= stops[i].0 {
        let (v0, c0) = stops[i - 1]; let (v1, c1) = stops[i]
        let t = (v - v0) / (v1 - v0)
        return Color(red: c0.0 + (c1.0 - c0.0) * t,
                     green: c0.1 + (c1.1 - c0.1) * t,
                     blue: c0.2 + (c1.2 - c0.2) * t)
    }
    let c = stops[stops.count - 1].1
    return Color(red: c.0, green: c.1, blue: c.2)
}

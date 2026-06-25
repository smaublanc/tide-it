//
//  WeekSummaryView.swift
//  Tide It
//
//  Fenêtre flottante « Résumé 7 jours » — verre liquide en paysage, rubans couleur
//  (vent + houle) façon app de vent, pour lire la tendance de la semaine d'un coup d'œil.
//  Présentée en plein écran depuis le menu de TodayView ; le contenu est tourné en paysage
//  (l'utilisateur tourne l'iPhone). Données = openMeteoForecasts (déjà 14 j) → couche de
//  présentation pure, pas de nouveau moteur. Couleurs vent réutilisées de PremiumCurveCanvas.
//

import SwiftUI

struct WeekSummaryView: View {
    let forecasts: [HourlyForecast]
    let portName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backdrop
                // Contenu présenté en PAYSAGE : on échange les dimensions puis on tourne de 90°.
                // L'utilisateur tourne le téléphone pour lire la tendance sur toute la largeur.
                WeekSummaryPanel(forecasts: forecasts, portName: portName) { dismiss() }
                    .frame(width: proxy.size.height, height: proxy.size.width)
                    .rotationEffect(.degrees(90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }

    private var backdrop: some View {
        ZStack {
            Color(red: 0.04, green: 0.055, blue: 0.086)
            Circle().fill(Color(red: 0.18, green: 0.63, blue: 0.72))
                .frame(width: 300).blur(radius: 90).opacity(0.32).offset(x: -90, y: -50)
            Circle().fill(Color(red: 0.91, green: 0.47, blue: 0.18))
                .frame(width: 260).blur(radius: 96).opacity(0.22).offset(x: 110, y: 100)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}

// MARK: - Panneau (carte verre, format paysage)

private struct WeekSummaryPanel: View {
    let forecasts: [HourlyForecast]
    let portName: String
    let onClose: () -> Void

    private let days = 7

    /// Fenêtre = début du jour courant → +7 jours, triée.
    private var window: [HourlyForecast] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return [] }
        return forecasts.filter { $0.time >= start && $0.time < end }.sorted { $0.time < $1.time }
    }

    private var hasSwell: Bool {
        window.contains { ($0.swellHeight ?? $0.waveHeight) != nil }
    }

    /// Position du curseur « maintenant » dans la fenêtre [0…1].
    private var cursorFrac: Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return 0 }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(start) / span, 0), 1)
    }

    var body: some View {
        Group {
            if window.count >= 2 {
                content
            } else {
                unavailable
            }
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, 26)
    }

    private var content: some View {
        VStack(spacing: 13) {
            header
            dayHeader
            ribbonRow(
                title: "Vent", icon: "wind", tint: Color(red: 0.5, green: 0.84, blue: 0.9),
                colors: window.map { PremiumCurveCanvas.windColorSmooth($0.windSpeedKmh) },
                trailing: windRange
            )
            if hasSwell {
                ribbonRow(
                    title: "Houle", icon: "water.waves", tint: Color(red: 0.37, green: 0.79, blue: 0.65),
                    colors: window.map { swellColor($0.swellHeight ?? $0.waveHeight ?? 0) },
                    trailing: swellRange
                )
            }
            footnote
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(glassBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }

    // MARK: pièces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Résumé 7 jours")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(hasSwell ? "\(portName) · spot de surf" : portName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
        }
    }

    private var dayHeader: some View {
        let accent = Color(red: 0.37, green: 0.79, blue: 0.65)
        return HStack(spacing: 10) {
            Color.clear.frame(width: 62)
            HStack(spacing: 0) {
                ForEach(dayLabels) { lbl in
                    VStack(spacing: 1) {
                        Text(lbl.wd)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(lbl.weekend ? accent : .white.opacity(0.82))
                        Text(lbl.day)
                            .font(.system(size: 11))
                            .foregroundStyle(lbl.weekend ? accent.opacity(0.7) : .white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Color.clear.frame(width: 56)
        }
    }

    private func ribbonRow(title: String, icon: String, tint: Color, colors: [Color], trailing: (String, String)) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.88))
            }
            .frame(width: 62, alignment: .leading)

            ForecastRibbon(colors: colors, cursorFrac: cursorFrac)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.07), lineWidth: 1))

            VStack(alignment: .trailing, spacing: 0) {
                Text(trailing.0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                Text(trailing.1).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 56, alignment: .trailing)
        }
    }

    private var footnote: some View {
        HStack {
            HStack(spacing: 7) {
                Circle().stroke(Color.white, lineWidth: 2).frame(width: 9, height: 9)
                Text("maintenant").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            Text("tendance · 7 prochains jours")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.top, 2)
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "wind.snow").font(.system(size: 30)).foregroundStyle(.white.opacity(0.4))
            Text("Prévisions indisponibles").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Text("Reviens une fois les données chargées.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Button("Fermer", action: onClose).font(.system(size: 13, weight: .semibold)).foregroundStyle(.cyan).padding(.top, 4)
        }
        .padding(40)
        .background(glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 28).fill(Color.white.opacity(0.04)))
            .environment(\.colorScheme, .dark)
    }

    // MARK: données dérivées

    private var dayLabels: [DayCol] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let wd = ["", "DI", "LU", "MA", "ME", "JE", "VE", "SA"]
        return (0..<days).compactMap { off in
            guard let d = cal.date(byAdding: .day, value: off, to: start) else { return nil }
            let w = cal.component(.weekday, from: d)
            return DayCol(id: off, wd: wd[w], day: "\(cal.component(.day, from: d))", weekend: cal.isDateInWeekend(d))
        }
    }

    private var windRange: (String, String) {
        let unit = ThemeManager.shared.windUnit
        let vals = window.map { $0.windSpeedKmh }
        let lo = UnitFormatter.windSpeedInt(vals.min() ?? 0, unit: unit)
        let hi = UnitFormatter.windSpeedInt(vals.max() ?? 0, unit: unit)
        return ("\(lo)–\(hi)", unit.label)
    }

    private var swellRange: (String, String) {
        let sys = ThemeManager.shared.measureSystem
        let vals = window.compactMap { $0.swellHeight ?? $0.waveHeight }
        let lo = UnitFormatter.height(vals.min() ?? 0, system: sys, decimals: 1)
        let hi = UnitFormatter.height(vals.max() ?? 0, system: sys, decimals: 1)
        // lo contient déjà l'unité (« 0.6 m ») → on garde la valeur et l'unité au pied
        let unit = sys == .imperial ? "ft" : "m"
        let loN = lo.replacingOccurrences(of: " \(unit)", with: "")
        let hiN = hi.replacingOccurrences(of: " \(unit)", with: "")
        return ("\(loN)–\(hiN)", unit)
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

    var body: some View {
        Canvas { ctx, size in
            let n = colors.count
            guard n > 1 else { return }
            let cw = size.width / CGFloat(n)
            for i in 0..<n {
                let x = CGFloat(i) * cw
                ctx.fill(Path(CGRect(x: x, y: 0, width: cw + 0.8, height: size.height)), with: .color(colors[i]))
            }
            // Curseur « maintenant » : fine règle + anneau verre sombre cerclé de blanc.
            let cx = CGFloat(cursorFrac) * size.width
            ctx.fill(Path(CGRect(x: cx - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.18)))
            let r: CGFloat = 9
            let ring = CGRect(x: cx - r, y: size.height / 2 - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: ring), with: .color(.black.opacity(0.42)))
            ctx.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 2.5)
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

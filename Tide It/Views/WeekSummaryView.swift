//
//  WeekSummaryView.swift
//  Tide It
//
//  Petite fenêtre flottante « Résumé 7 jours » — verre liquide de forme PAYSAGE, posée
//  par-dessus la TodayView (qui reste en PORTRAIT, visible au travers du liquid glass et
//  autour). Aucune rotation de l'appareil. Rubans couleur (vent + houle) façon app de vent
//  pour lire la tendance de la semaine d'un coup d'œil. Données = cache MarineWeatherService
//  partagé → couche de présentation pure. Couleurs vent réutilisées de PremiumCurveCanvas.
//

import SwiftUI

struct WeekSummaryView: View {
    let forecasts: [HourlyForecast]
    let portName: String
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Voile léger : la TodayView reste VISIBLE derrière (on ne fait que l'assombrir un peu).
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            WeekSummaryCard(forecasts: forecasts, portName: portName, onClose: dismiss)
                .padding(.horizontal, 16)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isPresented = false }
    }
}

// MARK: - Carte verre (forme paysage, compacte)

private struct WeekSummaryCard: View {
    let forecasts: [HourlyForecast]
    let portName: String
    let onClose: () -> Void

    private let days = 7

    private var window: [HourlyForecast] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return [] }
        return forecasts.filter { $0.time >= start && $0.time < end }.sorted { $0.time < $1.time }
    }

    private var hasSwell: Bool { window.contains { ($0.swellHeight ?? $0.waveHeight) != nil } }

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
            if window.count >= 2 { content } else { unavailable }
        }
        .frame(maxWidth: 380)
    }

    private var content: some View {
        VStack(spacing: 10) {
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
        .padding(14)
        .background(glassBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Résumé 7 jours")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(hasSwell ? "\(portName) · spot de surf" : portName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }

    private var dayHeader: some View {
        let accent = Color(red: 0.37, green: 0.79, blue: 0.65)
        return HStack(spacing: 8) {
            Color.clear.frame(width: 52)
            HStack(spacing: 0) {
                ForEach(dayLabels) { lbl in
                    VStack(spacing: 0) {
                        Text(lbl.wd)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(lbl.weekend ? accent : .white.opacity(0.8))
                        Text(lbl.day)
                            .font(.system(size: 10))
                            .foregroundStyle(lbl.weekend ? accent.opacity(0.7) : .white.opacity(0.42))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Color.clear.frame(width: 46)
        }
    }

    private func ribbonRow(title: String, icon: String, tint: Color, colors: [Color], trailing: (String, String)) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.88))
            }
            .frame(width: 52, alignment: .leading)

            ForecastRibbon(colors: colors, cursorFrac: cursorFrac)
                .frame(height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))

            VStack(alignment: .trailing, spacing: 0) {
                Text(trailing.0).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                Text(trailing.1).font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
            }
            .frame(width: 46, alignment: .trailing)
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Circle().stroke(Color.white, lineWidth: 1.8).frame(width: 8, height: 8)
            Text("maintenant").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
            Spacer()
            Text("tendance · 7 j").font(.system(size: 10)).foregroundStyle(.white.opacity(0.34))
        }
        .padding(.horizontal, 2)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "wind.snow").font(.system(size: 26)).foregroundStyle(.white.opacity(0.4))
            Text("Prévisions indisponibles").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Text("Ouvre le spot un instant, puis reviens.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Button("Fermer", action: onClose).font(.system(size: 12, weight: .semibold)).foregroundStyle(.cyan).padding(.top, 2)
        }
        .padding(28)
        .background(glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.03)))
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
        let unit = sys == .imperial ? "ft" : "m"
        let lo = UnitFormatter.height(vals.min() ?? 0, system: sys, decimals: 1).replacingOccurrences(of: " \(unit)", with: "")
        let hi = UnitFormatter.height(vals.max() ?? 0, system: sys, decimals: 1).replacingOccurrences(of: " \(unit)", with: "")
        return ("\(lo)–\(hi)", unit)
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
                ctx.fill(Path(CGRect(x: CGFloat(i) * cw, y: 0, width: cw + 0.8, height: size.height)),
                         with: .color(colors[i]))
            }
            let cx = CGFloat(cursorFrac) * size.width
            ctx.fill(Path(CGRect(x: cx - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.18)))
            let r: CGFloat = 7
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

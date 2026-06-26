//
//  ObservedWindCard.swift
//  Tide It
//
//  Affiche le vent temps réel mesuré depuis un anémomètre à proximité du port.
//  Comparaison avec la prévision météo si disponible.
//  Crédit obligatoire de la source (CC-BY Pioupiou).
//

import SwiftUI

struct ObservedWindCard: View, Equatable {
    /// Station source (Pioupiou / Holfuy / ...)
    let station: WindStation

    /// Lecture valide (non-nil garanti par le call site)
    let reading: WindReading

    /// Distance en km entre la station et le port
    let distanceKm: Double

    /// Vitesse prévue par le modèle météo (km/h) — optionnel
    let predictedKmh: Double?

    /// Unité d'affichage choisie par l'utilisateur
    let unit: WindSpeedUnit

    /// Heure courante (rafraîchie chaque minute par la vue parente). Incluse dans
    /// l'égalité (Equatable synthétisé) pour que `.equatable()` ne FIGE pas l'âge de la
    /// mesure : sans elle, « il y a 3 min » et la pastille « live » restaient bloqués
    /// tant que la balise ne publiait pas une nouvelle valeur (données périmées vues
    /// comme fraîches). Reste constante pendant le scroll → perf préservée.
    var currentTime: Date = Date()

    // MARK: - Derived

    private var displaySpeed: Int {
        UnitFormatter.windSpeedInt(reading.speedAvgKmh, unit: unit)
    }

    private var displayGust: Int? {
        reading.gustKmh.map { UnitFormatter.windSpeedInt($0, unit: unit) }
    }

    private var unitLabel: String {
        switch unit {
        case .kmh: return "km/h"
        case .mph: return "mph"
        case .ms: return "m/s"
        case .knots: return "kt"
        }
    }

    /// Écart observé - prévu (dans l'unité d'affichage)
    private var deltaVsPredicted: Int? {
        guard let predictedKmh else { return nil }
        let predictedInt = UnitFormatter.windSpeedInt(predictedKmh, unit: unit)
        return displaySpeed - predictedInt
    }

    private var beaufortScale: Int {
        switch reading.speedAvgKmh {
        case 0..<2: return 0
        case 2..<6: return 1
        case 6..<12: return 2
        case 12..<20: return 3
        case 20..<29: return 4
        case 29..<39: return 5
        case 39..<50: return 6
        case 50..<62: return 7
        case 62..<75: return 8
        case 75..<89: return 9
        case 89..<103: return 10
        case 103..<118: return 11
        default: return 12
        }
    }

    private var windColor: Color {
        switch beaufortScale {
        case 0...2: return .green
        case 3...4: return .cyan
        case 5...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingMD) {
            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.scaled(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [windColor, windColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("Vent observé")
                    .font(.scaled(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Pastille "live" pulsante si frais (< 10 min)
                if reading.ageMinutes < 10 {
                    LivePulseDot(color: windColor)
                }
            }

            // Main content : hélice animée (vitesse ∝ vent réel) + stats
            HStack(alignment: .center, spacing: DS.spacingLG) {
                windDial

                VStack(alignment: .leading, spacing: 6) {
                    // Vitesse principale
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(displaySpeed)")
                            .font(.scaled(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(displaySpeed)))
                        Text(unitLabel)
                            .font(.scaled(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Direction cardinale
                    HStack(spacing: 8) {
                        Text(reading.directionCardinal)
                            .font(.scaled(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(windColor)
                            .tracking(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(windColor.opacity(0.15))
                                    .overlay(Capsule().stroke(windColor.opacity(0.3), lineWidth: 0.5))
                            )

                        Text("F\(beaufortScale) Beaufort")
                            .font(.scaled(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Rafales + écart vs prévu
                    HStack(spacing: 10) {
                        if let gust = displayGust {
                            HStack(spacing: 3) {
                                Image(systemName: "wind")
                                    .font(.scaled(size: 9, weight: .bold))
                                Text("rafales \(gust)")
                                    .font(.scaled(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        }

                        if let delta = deltaVsPredicted, delta != 0 {
                            HStack(spacing: 2) {
                                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                                    .font(.scaled(size: 8, weight: .bold))
                                Text("\(delta > 0 ? "+" : "")\(delta) vs prévu")
                                    .font(.scaled(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(delta > 0 ? Color.orange : Color.cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill((delta > 0 ? Color.orange : Color.cyan).opacity(0.12))
                            )
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            // Légende météo complète (balise + prévision) — le maximum de données dispo.
            let legend = legendItems()
            if !legend.isEmpty {
                Divider().overlay(Color.glassHighlight.opacity(0.08))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                          alignment: .leading, spacing: 9) {
                    ForEach(legend) { it in
                        HStack(spacing: 5) {
                            Image(systemName: it.icon)
                                .font(.scaled(size: 12, weight: .semibold))
                                .foregroundStyle(it.tint)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(it.value)
                                    .font(.scaled(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                                Text(it.label)
                                    .font(.scaled(size: 8, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.2)
                            }
                        }
                    }
                }
            }

            // Footer : station + distance + age + crédit source
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "location.circle")
                        .font(.scaled(size: 9))
                    Text(station.name)
                        .font(.scaled(size: 10, weight: .medium))
                        .lineLimit(1)
                    Text("·")
                        .font(.scaled(size: 10))
                    Text(String(format: "%.1f km", locale: Locale.current, distanceKm))
                        .font(.scaled(size: 10, weight: .medium))
                    Text("·")
                        .font(.scaled(size: 10))
                    Text(reading.ageLabel)
                        .font(.scaled(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
                // Nom de la source de la balise retiré (demande). ⚠ Pioupiou est en CC-BY :
                // l'attribution doit être conservée AILLEURS (écran « À propos / Crédits »).
            }
        }
        // Sans cadre (glassCard retiré) — même DA aérée que le bandeau météo.
        .padding(.vertical, DS.spacingSM)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Cadran à hélice animée (vitesse de rotation ∝ vent réel)

    private var windDial: some View {
        ZStack {
            // Cercle extérieur + intérieur pointillé
            Circle()
                .stroke(Color.glassHighlight.opacity(0.15), lineWidth: 1.5)
                .frame(width: 80, height: 80)
            Circle()
                .stroke(Color.glassHighlight.opacity(0.1), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
                .frame(width: 54, height: 54)

            // Cardinaux
            ForEach(0..<4) { i in
                Text(["N", "E", "S", "O"][i])
                    // Police FIXE : ces cardinaux sont positionnés par offset géométrique
                    // dans le cadran (y: -34, rotation) → Dynamic Type les ferait déborder.
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // Pointeur de DIRECTION (sens où souffle le vent : +180°)
            Triangle()
                .fill(windColor)
                .frame(width: 9, height: 7)
                .offset(y: -33)
                .rotationEffect(.degrees(reading.directionDegrees + 180))

            // HÉLICE centrale : tourne d'autant plus vite que le vent réel est fort.
            SpinningPropeller(windKmh: reading.speedAvgKmh, color: windColor)
                .frame(width: 42, height: 42)
        }
        .frame(width: 80, height: 80)
        .accessibilityHidden(true)
    }

    // MARK: - Légende météo (balise + prévision)

    private struct LegendItem: Identifiable {
        let id = UUID()
        let icon: String
        let value: String
        let label: String
        let tint: Color
    }

    /// Légende issue UNIQUEMENT de la balise (certaines ne donnent que le vent → la grille
    /// se réduit d'elle-même). La météo complète est dans le bandeau météo en bas.
    private func legendItems() -> [LegendItem] {
        var out: [LegendItem] = []
        // Système d'unités (°C/°F) — la card montrait température & rosée en °C brut même en impérial.
        let sys = MeasureSystem(rawValue: UserDefaults.standard.string(forKey: "measureSystem") ?? "") ?? .metric
        if let g = reading.gustKmh {
            out.append(.init(icon: "wind", value: "\(UnitFormatter.windSpeedInt(g, unit: unit))", label: "RAFALE", tint: windColor))
        }
        out.append(.init(icon: "location.north.fill", value: reading.directionCardinal, label: "DIRECTION", tint: windColor))
        if let t = reading.temperatureC {
            out.append(.init(icon: "thermometer.medium", value: "\(Int(UnitFormatter.tempValue(t, system: sys).rounded()))°", label: "TEMP.", tint: .orange))
        }
        if let h = reading.humidityPct {
            out.append(.init(icon: "humidity.fill", value: "\(Int(h.rounded()))%", label: "HUMIDITÉ", tint: .cyan))
        }
        if let d = reading.dewpointC {
            out.append(.init(icon: "drop.fill", value: "\(Int(UnitFormatter.tempValue(d, system: sys).rounded()))°", label: "ROSÉE", tint: .teal))
        }
        if let p = reading.pressureHpa {
            let arrow = (reading.pressureTrendHpa).map { $0 > 0.3 ? " ↑" : ($0 < -0.3 ? " ↓" : "") } ?? ""
            out.append(.init(icon: "barometer", value: "\(Int(p.rounded()))\(arrow)", label: "PRESSION", tint: .indigo))
        }
        return out
    }

    // MARK: - A11y

    private var accessibilityLabel: String {
        var s = "Vent observé \(displaySpeed) \(unitLabel), direction \(reading.directionCardinal), force \(beaufortScale) Beaufort"
        if let gust = displayGust { s += ", rafales \(gust)" }
        s += ". Station \(station.name) à \(String(format: "%.1f", locale: Locale.current, distanceKm)) km, \(reading.ageLabel)."
        return s
    }
}

// MARK: - Triangle (pointeur de direction)

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Hélice qui tourne (vitesse de rotation ∝ vent réel)

private struct SpinningPropeller: View {
    let windKmh: Double
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    /// Durée d'un tour (s) : plus le vent est fort, plus l'hélice tourne vite (bornée pour
    /// rester lisible — pas d'effet stroboscopique, et toujours un léger mouvement).
    private var revolution: Double { 360.0 / max(25, min(620, windKmh * 8)) }

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(LinearGradient(colors: [color, color.opacity(0.5)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: 19)
                    .offset(y: -9.5)
                    .rotationEffect(.degrees(Double(i) * 120))
            }
            Circle().fill(color).frame(width: 8, height: 8)
            Circle().fill(.white.opacity(0.9)).frame(width: 2.6, height: 2.6)
        }
        .rotationEffect(.degrees(angle))
        .onAppear { spin() }
        .onChange(of: windKmh) { _, _ in spin() }
    }

    private func spin() {
        guard !reduceMotion, windKmh > 0.5 else { angle = 0; return }
        angle = 0
        withAnimation(.linear(duration: revolution).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

// MARK: - Live pulse dot

private struct LivePulseDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .opacity(pulse ? 0 : 1)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 18, height: 18)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Jauge de confiance (biais modèle vs réel)

/// Verdict d'HONNÊTETÉ sur la prévision pour ce spot : le modèle tape-t-il juste ICI, ces
/// derniers relevés ? Appris des écarts balise/modèle accumulés (ForecastBiasService).
/// GRATUIT (teaser premium → voir le réel + corriger les fenêtres GO). Réactif au service.
struct ForecastTrustBadge: View {
    let portId: String
    let unit: WindSpeedUnit
    @ObservedObject private var bias = ForecastBiasService.shared

    var body: some View {
        if let r = bias.readout(for: portId), r.isReliable {
            let v = UnitFormatter.windSpeedInt(abs(r.meanBiasKmh), unit: unit)
            if r.meanBiasKmh > ForecastBiasService.BiasReadout.meaningfulBiasKmh {
                pill(icon: "arrow.down.right.circle.fill", color: .orange,
                     title: "Modèle optimiste",
                     detail: "+\(v) \(unit.label) " + String(localized: "vs réel"))
            } else if r.meanBiasKmh < -ForecastBiasService.BiasReadout.meaningfulBiasKmh {
                pill(icon: "arrow.up.right.circle.fill", color: .cyan,
                     title: "Modèle prudent",
                     detail: "−\(v) \(unit.label) " + String(localized: "vs réel"))
            } else {
                pill(icon: "checkmark.seal.fill", color: .green,
                     title: "Prévision fiable ici", detail: nil)
            }
        } else if bias.sampleCount(for: portId) >= 1 {
            pill(icon: "gauge.medium", color: .gray,
                 title: "Calibration en cours", detail: "(\(bias.sampleCount(for: portId)))")
        }
    }

    private func pill(icon: String, color: Color, title: LocalizedStringKey, detail: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            if let detail {
                Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Contrôle de CORRECTION (jauge de confiance, stage 2). N'apparaît QUE quand un biais local fiable
/// ET significatif a été mesuré (`isCorrectable`) — sinon rien (on ne propose pas de corriger un
/// modèle déjà juste, honnêteté). Premium : interrupteur réel câblé sur `debiasGoEnabled` (la courbe
/// + les fenêtres GO se décalent du biais appris). Gratuit : ligne verrouillée → paywall.
struct ForecastCorrectionRow: View {
    let portId: String
    let isPremium: Bool
    @Binding var enabled: Bool
    let onUpsell: () -> Void
    @ObservedObject private var bias = ForecastBiasService.shared

    var body: some View {
        if let r = bias.readout(for: portId), r.isCorrectable {
            if isPremium {
                Toggle(isOn: $enabled) {
                    rowLabel(locked: false)
                }
                .tint(.green)
                .padding(DS.spacingLG)
                .sectionCard(cornerRadius: DS.radiusXL)
            } else {
                Button {
                    HapticManager.shared.impact(.light)
                    onUpsell()
                } label: {
                    HStack(spacing: DS.spacingMD) {
                        rowLabel(locked: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(DS.spacingLG)
                    .sectionCard(cornerRadius: DS.radiusXL)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rowLabel(locked: Bool) -> some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: DS.radiusSM).fill(Color.green.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Corriger avec le réel")
                        .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                // ⚠️ Chaque branche porte son PROPRE `Text("littéral")` → résout en LocalizedStringKey
                // (localisé + auto-extrait). `Text(ternaire-de-String)` prendrait l'init non localisé.
                (locked ? Text("Ajuste la prévision avec le vent réel · Premium")
                        : Text("Courbe & fenêtres GO ajustées du biais mesuré"))
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

//
//  AlertPresetsView.swift
//  Tide It
//
//  Presets d'alertes rapides — UI cohérente avec Design System
//

import SwiftUI

struct AlertPresetsView: View {
    @ObservedObject var alertService: AlertService
    @ObservedObject var tideService: TideService
    @ObservedObject private var premium = PremiumManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var addedPresets: Set<String> = []
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.spacingXXL) {
                    headerInfo
                    presetsGrid
                }
                .padding(.top, DS.spacingLG)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .navigationTitle("Modèles")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showPaywall) {
            PremiumPaywallView()
                .presentationDetents([.large])
                .sheetBackground()
        }
    }

    // MARK: - Header
    private var headerInfo: some View {
        VStack(spacing: DS.spacingSM) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)
                )
            Text("Alertes prêtes à l'emploi")
                .font(.scaled(size: DS.fontTitle3, weight: .bold))
                .foregroundStyle(.primary)
            Text("Ajoutez-les en un tap, personnalisez-les ensuite")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.gray)
        }
        .padding(DS.spacingXL)
    }

    // MARK: - Grid
    private var presetsGrid: some View {
        VStack(spacing: DS.spacingMD) {
            ForEach(Presets.all, id: \.name) { preset in
                PresetCard(
                    preset: preset,
                    isAdded: addedPresets.contains(preset.name)
                ) {
                    addPreset(preset)
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }

    private func addPreset(_ preset: Presets.AlertPreset) {
        // Consultation libre, mais l'AJOUT est premium → paywall (le but : donner envie).
        guard premium.canUseAlerts else {
            HapticManager.shared.impact(.medium)
            showPaywall = true
            return
        }
        HapticManager.shared.notification(.success)
        let alert = TideAlert(
            name: preset.name,
            isEnabled: true,
            conditions: preset.conditions,
            actions: [AlertAction(type: .notification, message: preset.message)],
            port: tideService.selectedPort?.id,
            portName: tideService.selectedPort?.name,
            requireAllConditions: preset.requireAll,
            cooldownPeriod: 3600
        )
        alertService.addAlert(alert)
        _ = withAnimation(DS.defaultSpring) {
            addedPresets.insert(preset.name)
        }
    }
}

// MARK: - Presets Data
enum Presets {
    struct AlertPreset {
        let name: String
        let icon: String
        let color: Color
        let description: String
        let message: String
        let conditions: [AlertCondition]
        let requireAll: Bool
    }

    static let all: [AlertPreset] = [
        AlertPreset(
            name: String(localized: "Le vent s'établit"),
            icon: "wind.snow",
            color: .green,
            description: String(localized: "La balise franchit le seuil et le vent tient ~20 min"),
            message: String(localized: "Le vent s'établit — fonce !"),
            conditions: [
                // value1 = seuil en km/h (≈ 15 kn) ; value2 = minutes de confirmation.
                AlertCondition(type: .windEstablishing, operator1: .greaterThan, value1: 28, value2: 20)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Grande marée"),
            icon: "water.waves",
            color: .red,
            description: String(localized: "Coefficient supérieur à 100"),
            message: String(localized: "Grande marée en approche !"),
            conditions: [
                AlertCondition(type: .tideCoefficient, operator1: .greaterThan, value1: 100)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Vives-eaux"),
            icon: "chart.bar.fill",
            color: .orange,
            description: String(localized: "Coefficient supérieur à 90"),
            message: String(localized: "Période de vives-eaux"),
            conditions: [
                AlertCondition(type: .tideCoefficient, operator1: .greaterThan, value1: 90)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Mortes-eaux"),
            icon: "chart.bar",
            color: .green,
            description: String(localized: "Coefficient inférieur à 45"),
            message: String(localized: "Période de mortes-eaux"),
            conditions: [
                AlertCondition(type: .tideCoefficient, operator1: .lessThan, value1: 45)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Basse mer imminente"),
            icon: "arrow.down.circle.fill",
            color: .purple,
            description: String(localized: "Basse mer dans moins d'1h"),
            message: String(localized: "Basse mer dans moins d'une heure"),
            conditions: [
                AlertCondition(type: .timeBeforeTide, operator1: .lessThan, value1: 1.0, tideType: false)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Pleine mer imminente"),
            icon: "arrow.up.circle.fill",
            color: .cyan,
            description: String(localized: "Pleine mer dans moins d'1h"),
            message: String(localized: "Pleine mer dans moins d'une heure"),
            conditions: [
                AlertCondition(type: .timeBeforeTide, operator1: .lessThan, value1: 1.0, tideType: true)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Vent fort"),
            icon: "wind",
            color: .orange,
            description: String(localized: "Vent fort (force 6+)"),
            message: String(localized: "Vent fort détecté !"),
            conditions: [
                AlertCondition(type: .windSpeed, operator1: .greaterThan, value1: 40)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Sortie pêche idéale"),
            icon: "fish.fill",
            color: .teal,
            description: String(localized: "Coef 70-90, vent modéré"),
            message: String(localized: "Conditions idéales pour la pêche"),
            conditions: [
                AlertCondition(type: .tideCoefficient, operator1: .between, value1: 70, value2: 90),
                AlertCondition(type: .windSpeed, operator1: .lessThan, value1: 20)
            ],
            requireAll: true
        ),
        AlertPreset(
            name: String(localized: "Conditions de surf"),
            icon: "figure.surfing",
            color: .blue,
            description: String(localized: "Coef > 80, 2h avant PM"),
            message: String(localized: "Bonnes conditions de surf !"),
            conditions: [
                AlertCondition(type: .tideCoefficient, operator1: .greaterThan, value1: 80),
                AlertCondition(type: .timeBeforeTide, operator1: .lessThan, value1: 2.0, tideType: true)
            ],
            requireAll: true
        )
    ]
}

// MARK: - Preset Card
private struct PresetCard: View {
    let preset: Presets.AlertPreset
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: DS.spacingLG) {
            Image(systemName: preset.icon)
                .font(.scaled(size: DS.fontTitle3, weight: .semibold))
                .foregroundStyle(preset.color)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusMD)
                        .fill(preset.color.opacity(0.2))
                )

            VStack(alignment: .leading, spacing: DS.spacingXS) {
                Text(preset.name)
                    .font(.scaled(size: DS.fontBody, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(preset.description)
                    .font(.scaled(size: DS.fontFootnote))
                    .foregroundStyle(.gray)

                HStack(spacing: DS.spacingXS) {
                    ForEach(preset.conditions, id: \.type) { condition in
                        Text(condition.type.localizedName)
                            .font(.scaled(size: DS.fontCaption2, weight: .medium))
                            .foregroundStyle(preset.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(preset.color.opacity(0.15)))
                    }
                }
            }

            Spacer()

            Button(action: onAdd) {
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.cyan)
                }
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
        }
        // Dé-cadré : ligne ouverte.
        .padding(.vertical, DS.spacingMD)
        .padding(.horizontal, DS.spacingXS)
        .contentShape(Rectangle())
        .opacity(isAdded ? 0.7 : 1)
    }
}

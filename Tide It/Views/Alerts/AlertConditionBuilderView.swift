//
//  AlertConditionBuilderView.swift
//  Tide It
//
//  Constructeur visuel de conditions d'alerte — UI cohérente DS
//

import SwiftUI

struct AlertConditionBuilderView: View {
    let existingCondition: AlertCondition?
    let onSave: (AlertCondition) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var selectedType: AlertConditionType = .tideCoefficient
    @State private var selectedOperator: ConditionOperator = .greaterThan
    @State private var value1: Double = 90
    @State private var value2: Double = 110
    @State private var tideType: Bool?

    // Wind direction: center + spread model
    @State private var windDirCenter: Double = 180
    @State private var windDirSpread: Double = 20

    // Sunrise / Sunset
    @State private var sunEvent: SunEvent = .sunrise
    @State private var sunTiming: SunTiming = .before
    @State private var sunOffsetMinutes: Double = 30

    init(existingCondition: AlertCondition?, onSave: @escaping (AlertCondition) -> Void) {
        self.existingCondition = existingCondition
        self.onSave = onSave

        // Lire les unités depuis UserDefaults (themeManager pas accessible dans init)
        let windUnit = WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh
        let measureSystem = MeasureSystem(rawValue: UserDefaults.standard.string(forKey: "measureSystem") ?? "") ?? .metric

        if let c = existingCondition {
            // value1/value2 sont stockés en canonical (km/h, m) — convertir vers display unit pour le slider
            let displayValue1: Double
            let displayValue2: Double
            switch c.type {
            case .windSpeed, .windEstablishing:
                displayValue1 = UnitFormatter.windSpeedValue(c.value1, unit: windUnit)
                displayValue2 = UnitFormatter.windSpeedValue(c.value2 ?? 110, unit: windUnit)
            case .tideHeight:
                displayValue1 = UnitFormatter.heightValue(c.value1, system: measureSystem)
                displayValue2 = UnitFormatter.heightValue(c.value2 ?? 110, system: measureSystem)
            default:
                displayValue1 = c.value1
                displayValue2 = c.value2 ?? 110
            }
            _selectedType = State(initialValue: c.type)
            _selectedOperator = State(initialValue: c.operator1)
            _value1 = State(initialValue: displayValue1)
            _value2 = State(initialValue: displayValue2)
            _tideType = State(initialValue: c.tideType)
            _windDirCenter = State(initialValue: c.windDirectionCenter ?? c.value1)
            _windDirSpread = State(initialValue: c.windDirectionSpread ?? 20)
            _sunEvent = State(initialValue: c.sunEvent ?? .sunrise)
            _sunTiming = State(initialValue: c.sunTiming ?? .before)
            _sunOffsetMinutes = State(initialValue: c.sunOffsetMinutes ?? 30)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.spacingXXL) {
                    typeSelector
                    if showOperatorSelector { operatorSelector }
                    valueInputs
                    if showTideTypeFilter { tideTypeSelector }
                    previewSection
                    confirmButton
                }
                .padding(DS.spacingXL)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .navigationTitle(existingCondition != nil ? "Modifier la condition" : "Nouvelle condition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
        .onChange(of: selectedType) { _, _ in updateDefaultValues() }
    }

    private var showTideTypeFilter: Bool {
        [.tideHeight, .timeBeforeTide, .timeAfterTide, .tideWindow].contains(selectedType)
    }

    private var showOperatorSelector: Bool {
        selectedType != .windDirection && selectedType != .sunriseSunset && selectedType != .tideWindow
    }

    // MARK: - Type Selector
    private var typeSelector: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("Type de condition")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.spacingSM) {
                ForEach(AlertConditionType.allCases) { type in
                    TypeChip(type: type, isSelected: selectedType == type) {
                        HapticManager.shared.impact(.light)
                        selectedType = type
                    }
                }
            }
        }
    }

    // MARK: - Operator Selector
    private var operatorSelector: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("Opérateur")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: DS.spacingSM) {
                ForEach(availableOperators) { op in
                    OperatorChip(op: op, isSelected: selectedOperator == op) {
                        HapticManager.shared.impact(.light)
                        selectedOperator = op
                    }
                }
            }
        }
    }

    private var availableOperators: [ConditionOperator] {
        // « Le vent s'établit » n'a de sens qu'en seuil franchi (>). On interdit .between, qui
        // écraserait value2 (la fenêtre de confirmation en minutes lue par WindEstablishingService).
        selectedType == .windEstablishing ? [.greaterThan] : ConditionOperator.allCases
    }

    // MARK: - Value Inputs
    private var valueInputs: some View {
        VStack(alignment: .leading, spacing: DS.spacingMD) {
            if selectedType != .sunriseSunset && selectedType != .tideWindow {
                Text("Valeur\(selectedOperator == .between && selectedType != .windDirection ? "s" : "")")
                    .font(.scaled(size: DS.fontBody, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            switch selectedType {
            case .windDirection:
                windDirectionInput
            case .sunriseSunset:
                sunriseSunsetInput
            case .tideWindow:
                tideWindowInput
            default:
                standardValueInput
            }
        }
    }

    private var standardValueInput: some View {
        VStack(spacing: DS.spacingLG) {
            // Value 1
            HStack {
                Text(valueLabel)
                    .font(.scaled(size: DS.fontSubheadline))
                    .foregroundStyle(.gray)
                Spacer()
                Text(formattedValue(value1))
                    .font(.scaled(size: DS.fontTitle2, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
            }

            Slider(value: $value1, in: valueRange, step: valueStep)
                .tint(.cyan)
                .accessibilityLabel(valueLabel)
                .accessibilityValue(formattedValue(value1))

            if selectedOperator == .between {
                HStack {
                    Text("Valeur max")
                        .font(.scaled(size: DS.fontSubheadline))
                        .foregroundStyle(.gray)
                    Spacer()
                    Text(formattedValue(value2))
                        .font(.scaled(size: DS.fontTitle2, weight: .bold, design: .rounded))
                        .foregroundStyle(.purple)
                }

                Slider(value: $value2, in: valueRange, step: valueStep)
                    .tint(.purple)
                    .accessibilityLabel("Valeur max")
                    .accessibilityValue(formattedValue(value2))
            }
        }
        .padding(.vertical, DS.spacingSM)
    }

    private var windDirectionInput: some View {
        WindDirectionPicker(centerDirection: $windDirCenter, spreadAngle: $windDirSpread)
            .padding(.horizontal, DS.spacingSM)
            .padding(.vertical, DS.spacingLG)
            .background(RoundedRectangle(cornerRadius: DS.radiusLG).fill(Color.glassHighlight.opacity(0.05)))
    }

    // MARK: - Fenêtre de marée (avant ET après) — value1 = heures avant, value2 = heures après
    private var tideWindowInput: some View {
        VStack(spacing: DS.spacingLG) {
            HStack {
                Text("Heures avant").font(.scaled(size: DS.fontSubheadline)).foregroundStyle(.gray)
                Spacer()
                Text(String(format: "%.1f h", locale: Locale.current, value1))
                    .font(.scaled(size: DS.fontTitle2, weight: .bold, design: .rounded)).foregroundStyle(.cyan)
            }
            Slider(value: $value1, in: 0...8, step: 0.5).tint(.cyan)

            HStack {
                Text("Heures après").font(.scaled(size: DS.fontSubheadline)).foregroundStyle(.gray)
                Spacer()
                Text(String(format: "%.1f h", locale: Locale.current, value2))
                    .font(.scaled(size: DS.fontTitle2, weight: .bold, design: .rounded)).foregroundStyle(.purple)
            }
            Slider(value: $value2, in: 0...8, step: 0.5).tint(.purple)
        }
        .padding(.vertical, DS.spacingSM)
    }

    // MARK: - Sunrise / Sunset Input
    private var sunriseSunsetInput: some View {
        VStack(spacing: DS.spacingLG) {
            // Event choice: sunrise or sunset
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("Événement")
                    .font(.scaled(size: DS.fontBody, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: DS.spacingSM) {
                    SunEventChip(event: .sunrise, isSelected: sunEvent == .sunrise) {
                        HapticManager.shared.impact(.light)
                        sunEvent = .sunrise
                    }
                    SunEventChip(event: .sunset, isSelected: sunEvent == .sunset) {
                        HapticManager.shared.impact(.light)
                        sunEvent = .sunset
                    }
                }
            }

            // Timing: before, at, or after
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("Quand")
                    .font(.scaled(size: DS.fontBody, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: DS.spacingSM) {
                    ForEach(SunTiming.allCases) { timing in
                        SunTimingChip(timing: timing, isSelected: sunTiming == timing) {
                            HapticManager.shared.impact(.light)
                            sunTiming = timing
                        }
                    }
                }
            }

            // Offset (if not "at")
            if sunTiming != .at {
                VStack(spacing: DS.spacingSM) {
                    HStack {
                        Text("Décalage")
                            .font(.scaled(size: DS.fontSubheadline))
                            .foregroundStyle(.gray)
                        Spacer()
                        Text(formatMinutes(sunOffsetMinutes))
                            .font(.scaled(size: DS.fontTitle2, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }

                    Slider(value: $sunOffsetMinutes, in: 5...180, step: 5)
                        .tint(.orange)
                }
            }
        }
        .padding(.vertical, DS.spacingSM)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let m = Int(minutes)
        if m >= 60 {
            let h = m / 60
            let remainMin = m % 60
            return remainMin > 0 ? "\(h)h \(remainMin)min" : "\(h)h"
        }
        return "\(m) min"
    }

    // MARK: - Tide Type Selector
    private var tideTypeSelector: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("Type de marée")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: DS.spacingSM) {
                TideTypeChip(title: "Les deux", icon: "water.waves", isSelected: tideType == nil, color: .blue) {
                    HapticManager.shared.impact(.light)
                    tideType = nil
                }
                TideTypeChip(title: "Pleine mer", icon: "arrow.up.circle.fill", isSelected: tideType == true, color: .cyan) {
                    HapticManager.shared.impact(.light)
                    tideType = true
                }
                TideTypeChip(title: "Basse mer", icon: "arrow.down.circle.fill", isSelected: tideType == false, color: .purple) {
                    HapticManager.shared.impact(.light)
                    tideType = false
                }
            }
        }
    }

    // MARK: - Preview
    private var previewSection: some View {
        VStack(spacing: DS.spacingSM) {
            Text("Aperçu")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: DS.spacingMD) {
                Image(systemName: selectedType.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.cyan)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.cyan.opacity(0.2)))

                Text(previewText)
                    .font(.scaled(size: DS.fontCallout, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .padding(.vertical, DS.spacingSM)
        }
    }

    // MARK: - Confirm
    private var confirmButton: some View {
        Button {
            HapticManager.shared.impact(.medium)
            save()
        } label: {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.scaled(size: DS.fontTitle3))
                Text(existingCondition != nil ? "Mettre à jour" : "Ajouter la condition")
                    .font(.scaled(size: DS.fontHeadline, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingXL)
            .background(Capsule().fill(Color.accentGradient))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logic

    private func save() {
        var condition: AlertCondition

        switch selectedType {
        case .windDirection:
            condition = AlertCondition(
                id: existingCondition?.id ?? UUID(),
                type: .windDirection,
                operator1: .between,
                value1: windDirCenter,
                value2: windDirSpread,
                windDirectionCenter: windDirCenter,
                windDirectionSpread: windDirSpread
            )

        case .sunriseSunset:
            condition = AlertCondition(
                id: existingCondition?.id ?? UUID(),
                type: .sunriseSunset,
                operator1: .equals,
                value1: sunOffsetMinutes,
                sunEvent: sunEvent,
                sunTiming: sunTiming,
                sunOffsetMinutes: sunTiming == .at ? 0 : sunOffsetMinutes
            )

        case .tideWindow:
            // value1 = heures AVANT, value2 = heures APRÈS (toujours stockée). tideType = PM/BM/les deux.
            condition = AlertCondition(
                id: existingCondition?.id ?? UUID(),
                type: .tideWindow,
                operator1: .between,
                value1: value1,
                value2: value2,
                tideType: tideType
            )

        default:
            // Convertir display → canonical avant stockage (windSpeed: kn→km/h, tideHeight: ft→m)
            let storedValue1: Double
            let storedValue2: Double
            switch selectedType {
            case .windSpeed, .windEstablishing:
                storedValue1 = UnitFormatter.kmhFromWindSpeed(value1, unit: themeManager.windUnit)
                storedValue2 = UnitFormatter.kmhFromWindSpeed(value2, unit: themeManager.windUnit)
            case .tideHeight:
                storedValue1 = UnitFormatter.metersFromHeight(value1, system: themeManager.measureSystem)
                storedValue2 = UnitFormatter.metersFromHeight(value2, system: themeManager.measureSystem)
            default:
                storedValue1 = value1
                storedValue2 = value2
            }
            condition = AlertCondition(
                id: existingCondition?.id ?? UUID(),
                type: selectedType,
                operator1: selectedOperator,
                value1: storedValue1,
                value2: selectedOperator == .between ? storedValue2 : nil,
                tideType: showTideTypeFilter ? tideType : nil
            )
        }
        onSave(condition)
        dismiss()
    }

    private func updateDefaultValues() {
        switch selectedType {
        case .tideHeight:
            if themeManager.measureSystem == .imperial { value1 = 13; value2 = 20 }
            else { value1 = 4; value2 = 6 }
        case .tideCoefficient: value1 = 90; value2 = 110
        case .timeBeforeTide, .timeAfterTide: value1 = 1; value2 = 3
        case .tideWindow: value1 = 3; value2 = 3   // ±3 h autour de la marée par défaut
        case .windSpeed:
            // Défauts sensibles dans l'unité utilisateur (~30 km/h / ~50 km/h équivalents)
            switch themeManager.windUnit {
            case .kmh:   value1 = 30; value2 = 50
            case .knots: value1 = 16; value2 = 27
            case .mph:   value1 = 19; value2 = 31
            case .ms:    value1 = 8;  value2 = 14
            }
        case .windEstablishing:
            // Seuil de déclenchement (par défaut ~28 km/h ≈ 15 kn). La fenêtre de confirmation
            // (value2) est gérée par le preset ; en greaterThan elle reste nil → 20 min par défaut.
            switch themeManager.windUnit {
            case .kmh:   value1 = 28
            case .knots: value1 = 15
            case .mph:   value1 = 17
            case .ms:    value1 = 8
            }
            selectedOperator = .greaterThan   // cohérent avec availableOperators (pas de .between)
        case .windDirection:   windDirCenter = 180; windDirSpread = 20
        case .sunriseSunset:   sunEvent = .sunrise; sunTiming = .before; sunOffsetMinutes = 30
        }
    }

    private var valueLabel: String {
        selectedOperator == .between ? "Valeur min" : "Valeur"
    }

    private var valueRange: ClosedRange<Double> {
        switch selectedType {
        case .tideHeight:
            return themeManager.measureSystem == .imperial ? 0...50 : 0...15
        case .tideCoefficient: return 20...120
        case .timeBeforeTide, .timeAfterTide: return 0.5...12
        case .tideWindow: return 0...8
        case .windSpeed, .windEstablishing:
            switch themeManager.windUnit {
            case .kmh:   return 0...150
            case .knots: return 0...80
            case .mph:   return 0...90
            case .ms:    return 0...50
            }
        case .windDirection: return 0...360
        case .sunriseSunset: return 5...180
        }
    }

    private var valueStep: Double {
        switch selectedType {
        case .tideHeight:
            return themeManager.measureSystem == .imperial ? 0.5 : 0.1
        case .tideCoefficient: return 1
        case .timeBeforeTide, .timeAfterTide: return 0.5
        case .tideWindow: return 0.5
        case .windSpeed, .windEstablishing: return 1
        case .windDirection: return 5
        case .sunriseSunset: return 5
        }
    }

    private func formattedValue(_ v: Double) -> String {
        // value1/value2 sont désormais en display unit (slider opère en unité utilisateur)
        switch selectedType {
        case .tideHeight:
            return String(format: "%.1f %@", locale: Locale.current, v, themeManager.measureSystem.heightUnit)
        case .tideCoefficient: return "\(Int(v))"
        case .timeBeforeTide, .timeAfterTide, .tideWindow: return String(format: "%.1f h", locale: Locale.current, v)
        case .windSpeed, .windEstablishing:
            return "\(Int(v.rounded())) \(themeManager.windUnit.label)"
        case .windDirection: return "\(Int(v))°"
        case .sunriseSunset: return formatMinutes(v)
        }
    }

    private var previewText: String {
        switch selectedType {
        case .windDirection:
            return "Quand le vent vient de \(Int(windDirCenter))° ±\(Int(windDirSpread))°"

        case .sunriseSunset:
            let eventStr = sunEvent == .sunrise ? "lever du soleil" : "coucher du soleil"
            switch sunTiming {
            case .at:
                return "Au moment du \(eventStr)"
            case .before:
                return "\(formatMinutes(sunOffsetMinutes)) avant le \(eventStr)"
            case .after:
                return "\(formatMinutes(sunOffsetMinutes)) après le \(eventStr)"
            }

        case .tideWindow:
            let ref = tideType == true ? "la pleine mer" : (tideType == false ? "la basse mer" : "la marée")
            return "Navigable de \(String(format: "%.1f", locale: Locale.current, value1)) h avant à \(String(format: "%.1f", locale: Locale.current, value2)) h après \(ref)"

        default:
            let typeStr = selectedType.rawValue.lowercased()
            let v1Str = formattedValue(value1)
            switch selectedOperator {
            case .greaterThan: return "Quand \(typeStr) > \(v1Str)"
            case .lessThan:    return "Quand \(typeStr) < \(v1Str)"
            case .equals:      return "Quand \(typeStr) = \(v1Str)"
            case .between:     return "Quand \(typeStr) entre \(v1Str) et \(formattedValue(value2))"
            }
        }
    }
}

// MARK: - Type Chip
private struct TypeChip: View {
    let type: AlertConditionType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: type.icon)
                    .font(.scaled(size: DS.fontCallout))
                Text(type.localizedName)
                    .font(.scaled(size: DS.fontFootnote, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(isSelected ? Color.cyan.opacity(0.25) : Color.glassHighlight.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(isSelected ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Operator Chip
private struct OperatorChip: View {
    let op: ConditionOperator
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(op.operatorSymbol)
                    .font(.scaled(size: DS.fontTitle3, weight: .bold, design: .monospaced))
                Text(op.localizedName)
                    .font(.scaled(size: DS.fontCaption2))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(isSelected ? Color.cyan.opacity(0.2) : Color.glassHighlight.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(isSelected ? Color.cyan.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tide Type Chip
private struct TideTypeChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.scaled(size: DS.fontTitle3))
                Text(title)
                    .font(.scaled(size: DS.fontCaption2, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? color : .gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(isSelected ? color.opacity(0.2) : Color.glassHighlight.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sun Event Chip
private struct SunEventChip: View {
    let event: SunEvent
    let isSelected: Bool
    let action: () -> Void

    private var color: Color { event == .sunrise ? .orange : .purple }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: event.icon)
                    .font(.scaled(size: DS.fontTitle2))
                    .symbolRenderingMode(.multicolor)
                Text(event.localizedName)
                    .font(.scaled(size: DS.fontCaption, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? color : .gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingLG)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMD)
                    .fill(isSelected ? color.opacity(0.2) : Color.glassHighlight.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMD)
                    .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sun Timing Chip
private struct SunTimingChip: View {
    let timing: SunTiming
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: timing.icon)
                    .font(.scaled(size: DS.fontBody))
                Text(timing.localizedName)
                    .font(.scaled(size: DS.fontCaption2, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .orange : .gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(isSelected ? Color.orange.opacity(0.2) : Color.glassHighlight.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(isSelected ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

//
//  AlertEditorView.swift
//  Tide It
//
//  Création et édition d'alertes — UI cohérente avec Design System
//

import SwiftUI

struct AlertEditorView: View {
    @ObservedObject var alertService: AlertService
    @ObservedObject var tideService: TideService
    @Environment(\.dismiss) private var dismiss

    let existingAlert: TideAlert?

    @State private var name: String = ""
    @State private var isEnabled: Bool = true
    @State private var requireAllConditions: Bool = true
    @State private var conditions: [AlertCondition] = []
    @State private var actions: [AlertAction] = []
    @State private var cooldownHours: Double = 1
    @State private var selectedPortId: String?
    @State private var selectedPortName: String?
    @State private var conditionSheet: ConditionSheetMode?
    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var showNamePrompt = false

    // Aperçu prédictif (« prochaine fois » + dry-run 7 jours). Données chargées par port,
    // forecast recalculé (sync, cheap) à chaque édition de condition.
    @State private var previewTide: [TideData] = []
    @State private var previewWind: [HourlyForecast] = []
    @State private var previewSun: [(sunrise: Date, sunset: Date)] = []
    @State private var previewResult: AlertForecaster.Result?
    @State private var previewLoading = false

    /// Mode du panneau de condition. Identifiable → `.sheet(item:)` garantit que
    /// le bon contenu est construit dès la 1re présentation (corrige le bug du
    /// "1er clic ouvre Création au lieu de Modification" causé par `.sheet(isPresented:)`
    /// qui lisait un `editingCondition` encore stale au moment du 1er rendu).
    private enum ConditionSheetMode: Identifiable {
        case new
        case edit(AlertCondition)

        var id: String {
            switch self {
            case .new:                 return "new"
            case .edit(let condition): return condition.id.uuidString
            }
        }

        var existingCondition: AlertCondition? {
            if case .edit(let condition) = self { return condition }
            return nil
        }
    }

    init(alertService: AlertService, tideService: TideService, existingAlert: TideAlert?) {
        self.alertService = alertService
        self.tideService = tideService
        self.existingAlert = existingAlert

        if let alert = existingAlert {
            _name = State(initialValue: alert.name)
            _isEnabled = State(initialValue: alert.isEnabled)
            _requireAllConditions = State(initialValue: alert.requireAllConditions)
            _conditions = State(initialValue: alert.conditions)
            _actions = State(initialValue: alert.actions)
            _cooldownHours = State(initialValue: alert.cooldownPeriod / 3600)
            _selectedPortId = State(initialValue: alert.port)
            _selectedPortName = State(initialValue: alert.portName)
        } else {
            _actions = State(initialValue: [
                AlertAction(type: .notification, message: "Condition de marée atteinte")
            ])
            _selectedPortId = State(initialValue: tideService.selectedPort?.id)
            _selectedPortName = State(initialValue: tideService.selectedPort?.name)
        }
    }

    private var hasConditions: Bool { !conditions.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.spacingXXL) {
                    portSection
                    conditionsSection
                    if conditions.count > 1 { combineSection }
                    if hasConditions { previewSection }
                    notificationsSection
                    cooldownSection
                    saveButton
                }
                .padding(DS.spacingXL)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .task(id: selectedPortId) { await loadPreviewData() }
            .onChange(of: conditions) { recomputePreview() }
            .onChange(of: requireAllConditions) { recomputePreview() }
            .onChange(of: cooldownHours) { recomputePreview() }
            .navigationTitle(existingAlert != nil ? "Modifier l'alerte" : "Nouvelle alerte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
            .sheet(item: $conditionSheet) { mode in
                AlertConditionBuilderView(
                    existingCondition: mode.existingCondition,
                    onSave: { condition in
                        // condition.id = id existant si édition, nouveau sinon.
                        if let idx = conditions.firstIndex(where: { $0.id == condition.id }) {
                            conditions[idx] = condition
                        } else {
                            conditions.append(condition)
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .sheetBackground()
            }
            .alert("Alerte incomplète", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(validationMessage)
            }
            .sheet(isPresented: $showNamePrompt) {
                AlertNameSheet(
                    name: $name,
                    isEditing: existingAlert != nil,
                    onConfirm: {
                        showNamePrompt = false
                        saveAlert()
                    },
                    onCancel: { showNamePrompt = false }
                )
                .presentationDetents([.height(280)])
                .sheetBackground()
            }
        }
    }

    // MARK: - 1. Port
    private var portSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            EditorSectionLabel(icon: "mappin.circle.fill", title: "Port")

            VStack(spacing: 0) {
                if let currentPort = tideService.selectedPort {
                    PortOptionRow(
                        icon: "mappin.circle.fill", name: currentPort.name,
                        subtitle: "Port actuel", isSelected: selectedPortId == currentPort.id,
                        accentColor: .cyan
                    ) {
                        HapticManager.shared.impact(.light)
                        selectedPortId = currentPort.id
                        selectedPortName = currentPort.name
                    }
                }

                PortOptionRow(
                    icon: "globe.europe.africa.fill", name: "Tous les ports",
                    subtitle: "Alerte globale", isSelected: selectedPortId == nil,
                    accentColor: .purple
                ) {
                    HapticManager.shared.impact(.light)
                    selectedPortId = nil
                    selectedPortName = nil
                }

                ForEach(tideService.ports.filter { $0.isFavorite && $0.id != tideService.selectedPort?.id }) { port in
                    PortOptionRow(
                        icon: "star.fill", name: port.name, subtitle: nil,
                        isSelected: selectedPortId == port.id, accentColor: .yellow
                    ) {
                        HapticManager.shared.impact(.light)
                        selectedPortId = port.id
                        selectedPortName = port.name
                    }
                }
            }
        }
    }

    // MARK: - 2. Conditions
    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack {
                EditorSectionLabel(icon: "bell.badge.fill", title: "Préviens-moi quand…")
                Spacer()
                if !conditions.isEmpty {
                    Text("\(conditions.count)")
                        .font(.scaled(size: DS.fontFootnote, weight: .bold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.2)))
                }
            }

            Text(conditions.isEmpty
                 ? "Ajoute une ou plusieurs conditions de déclenchement."
                 : (requireAllConditions
                    ? "Toutes ces conditions doivent être réunies."
                    : "Au moins une de ces conditions suffit."))
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.gray)

            VStack(spacing: DS.spacingSM) {
                ForEach(conditions) { condition in
                    ConditionRow(condition: condition, onEdit: {
                        HapticManager.shared.impact(.light)
                        conditionSheet = .edit(condition)
                    }, onDelete: {
                        HapticManager.shared.notification(.warning)
                        withAnimation(DS.defaultSpring) {
                            conditions.removeAll { $0.id == condition.id }
                        }
                    })
                }

                Button {
                    HapticManager.shared.impact(.light)
                    conditionSheet = .new
                } label: {
                    HStack(spacing: DS.spacingSM) {
                        Image(systemName: "plus.circle.fill")
                            .font(.scaled(size: DS.fontTitle3))
                        Text(conditions.isEmpty ? "Ajouter une condition" : "Ajouter une autre condition")
                            .font(.scaled(size: DS.fontBody, weight: .medium))
                    }
                    .foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.spacingLG)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusMD)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                            .foregroundStyle(.cyan.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 3. Combinaison
    private var combineSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            EditorSectionLabel(icon: "arrow.triangle.2.circlepath", title: "Combinaison")

            Text("Comment combiner les \(conditions.count) conditions ?")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.gray)

            HStack(spacing: DS.spacingMD) {
                CombineChip(symbol: "&", title: "Toutes", subtitle: "ET", isSelected: requireAllConditions) {
                    HapticManager.shared.impact(.light)
                    requireAllConditions = true
                }
                CombineChip(symbol: "|", title: "Une au moins", subtitle: "OU", isSelected: !requireAllConditions) {
                    HapticManager.shared.impact(.light)
                    requireAllConditions = false
                }
            }
            .padding(.vertical, DS.spacingSM)
        }
    }

    // MARK: - 4. Notifications
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            EditorSectionLabel(icon: "bell.fill", title: "Actions")

            Text("Que faire quand l'alerte se déclenche ?")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.gray)

            VStack(spacing: 0) {
                ForEach(AlertActionType.allCases, id: \.self) { actionType in
                    let isActive = actions.contains { $0.type == actionType }
                    ActionRow(
                        actionType: actionType, isActive: isActive,
                        message: actions.first(where: { $0.type == actionType })?.message
                    ) {
                        HapticManager.shared.impact(.light)
                        if isActive {
                            actions.removeAll { $0.type == actionType }
                        } else {
                            actions.append(AlertAction(
                                type: actionType,
                                message: actionType == .notification ? "Condition de marée atteinte" : nil
                            ))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Cooldown
    private var cooldownSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            EditorSectionLabel(icon: "clock.arrow.circlepath", title: "Fréquence")

            Text("Éviter les alertes trop rapprochées")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.gray)

            VStack(spacing: DS.spacingLG) {
                HStack {
                    Text("Minimum entre deux alertes")
                        .font(.scaled(size: DS.fontCallout, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(cooldownLabel)
                        .font(.scaled(size: DS.fontCallout, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                Slider(value: $cooldownHours, in: 0.5...24, step: 0.5)
                    .tint(.cyan)
                    .accessibilityLabel("Délai entre alertes")
                    .accessibilityValue(cooldownLabel)
            }
            .padding(.vertical, DS.spacingSM)
        }
    }

    private var cooldownLabel: String {
        if cooldownHours < 1 {
            return "\(Int(cooldownHours * 60)) min"
        } else if cooldownHours == 1 {
            return "1 heure"
        } else {
            let h = Int(cooldownHours)
            let m = Int((cooldownHours - Double(h)) * 60)
            return m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h) h"
        }
    }

    // MARK: - Aperçu prédictif

    /// Port de référence pour la projection : le port ciblé par l'alerte, ou — pour une alerte
    /// « tous les ports » — le port actuellement affiché (échantillon représentatif).
    private var targetPort: Port? {
        if let id = selectedPortId { return tideService.ports.first { $0.id == id } ?? tideService.selectedPort }
        return tideService.selectedPort
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            EditorSectionLabel(icon: "wand.and.stars", title: "Aperçu")

            Group {
                if let result = previewResult {
                    if !result.projectable {
                        previewCard(
                            tint: .green,
                            icon: "sparkles",
                            headline: "Alerte intelligente",
                            detail: "Confirmée en temps réel quand le vent s'établit — impossible à prévoir à l'avance."
                        )
                    } else if let next = result.next {
                        projectedCard(next: next, count: result.count)
                    } else {
                        previewCard(
                            tint: .orange,
                            icon: "calendar.badge.exclamationmark",
                            headline: "Aucun déclenchement prévu",
                            detail: "Ces conditions ne seraient pas réunies dans les 7 prochains jours\(targetPortSuffix)."
                        )
                    }
                } else if previewLoading {
                    previewCard(tint: .cyan, icon: "hourglass", headline: "Calcul…",
                                detail: "Projection sur les 7 prochains jours.")
                } else {
                    previewCard(tint: .gray, icon: "questionmark", headline: "Aperçu indisponible",
                                detail: "Pas assez de données de marée pour projeter cette alerte.")
                }
            }
        }
    }

    private var targetPortSuffix: String {
        if let name = targetPort?.name { return " à \(name)" }
        return ""
    }

    /// Carte « ça sonnerait » : prochaine occurrence + dry-run sur 7 jours.
    private func projectedCard(next: Date, count: Int) -> some View {
        VStack(spacing: DS.spacingLG) {
            HStack(spacing: DS.spacingLG) {
                previewStat(
                    icon: "bell.badge.fill", tint: .cyan, label: "Prochaine fois",
                    value: Self.nextFormatter.string(from: next)
                )
                Rectangle().fill(Color.glassHighlight.opacity(0.12)).frame(width: 1, height: 44)
                previewStat(
                    icon: "repeat", tint: .green, label: "Sur 7 jours",
                    value: count == 0 ? "—" : "\(count)×"
                )
            }
            Text(dryRunSentence(count: count))
                .font(.scaled(size: DS.fontFootnote))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.spacingLG)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .fill(Color.glassHighlight.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusMD)
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private func previewStat(icon: String, tint: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.scaled(size: DS.fontFootnote, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.scaled(size: DS.fontCaption2, weight: .medium))
                    .foregroundStyle(.gray)
            }
            Text(value)
                .font(.scaled(size: DS.fontCallout, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewCard(tint: Color, icon: String, headline: String, detail: String) -> some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontTitle3))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.scaled(size: DS.fontFootnote))
                    .foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.spacingLG)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .fill(Color.glassHighlight.opacity(0.05))
        )
    }

    private func dryRunSentence(count: Int) -> String {
        switch count {
        case 0:  return "Ne sonnerait pas avant longtemps — vérifiez vos conditions."
        case 1:  return "Sonnerait une seule fois sur la semaine à venir."
        default: return "Sonnerait \(count) fois sur la semaine à venir\(targetPortSuffix)."
        }
    }

    /// « mar. 24 juin · 6h42 »
    private static let nextFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM H mm")
        return f
    }()

    private func loadPreviewData() async {
        guard let port = targetPort else {
            previewResult = nil
            return
        }
        previewLoading = true
        defer { previewLoading = false }

        // Marées : port courant → données déjà chargées ; autre port → fetch (mis en cache).
        let tide: [TideData]
        if selectedPortId == nil || port.id == tideService.selectedPort?.id {
            tide = tideService.allTideData
        } else {
            tide = await tideService.fetchTideDataForPort(port.id)
        }
        let wind = await MarineWeatherService.shared.fetchHourlyForecast(for: port)

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        var sun: [(sunrise: Date, sunset: Date)] = []
        for d in 0...8 {
            if let day = cal.date(byAdding: .day, value: d, to: start),
               let s = SolarCalculator.sunriseSunset(latitude: port.latitude, longitude: port.longitude, date: day) {
                sun.append(s)
            }
        }

        previewTide = tide
        previewWind = wind
        previewSun = sun
        recomputePreview()
    }

    private func recomputePreview() {
        guard hasConditions, !previewTide.isEmpty else {
            previewResult = nil
            return
        }
        previewResult = AlertForecaster.forecast(
            conditions: conditions,
            requireAll: requireAllConditions,
            tideData: previewTide,
            windForecasts: previewWind,
            sunTimes: previewSun,
            days: 7,
            cooldown: cooldownHours * 3600
        )
    }

    // MARK: - Save Button
    private var saveButton: some View {
        Button {
            HapticManager.shared.impact(.medium)
            guard hasConditions else {
                validationMessage = "Ajoutez au moins une condition à votre alerte."
                showValidationError = true
                return
            }
            guard actions.contains(where: { $0.type == .notification }) else {
                validationMessage = "Activez au moins l'action « Notification » pour recevoir vos alertes."
                showValidationError = true
                return
            }
            showNamePrompt = true
        } label: {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: existingAlert != nil ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.scaled(size: DS.fontTitle3))
                Text(existingAlert != nil ? "Enregistrer" : "Créer l'alerte")
                    .font(.scaled(size: DS.fontHeadline, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingXL)
            .background(
                Capsule().fill(
                    hasConditions
                    ? Color.accentGradient
                    : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasConditions)
    }

    private func saveAlert() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if var existing = existingAlert {
            existing.name = trimmedName
            existing.isEnabled = isEnabled
            existing.requireAllConditions = requireAllConditions
            existing.conditions = conditions
            existing.actions = actions
            existing.cooldownPeriod = cooldownHours * 3600
            existing.port = selectedPortId
            existing.portName = selectedPortName
            alertService.updateAlert(existing)
        } else {
            alertService.addAlert(TideAlert(
                name: trimmedName, isEnabled: isEnabled,
                conditions: conditions, actions: actions,
                port: selectedPortId, portName: selectedPortName,
                requireAllConditions: requireAllConditions,
                cooldownPeriod: cooldownHours * 3600
            ))
        }
        dismiss()
    }
}

// MARK: - Editor Section Label
private struct EditorSectionLabel: View {
    let icon: String
    let title: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.scaled(size: DS.fontBody, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Port Option Row
private struct PortOptionRow: View {
    let icon: String
    let name: String
    let subtitle: String?
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spacingMD) {
                Image(systemName: icon)
                    .font(.scaled(size: DS.fontTitle3))
                    .foregroundStyle(isSelected ? accentColor : .gray)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isSelected ? accentColor.opacity(0.2) : Color.glassHighlight.opacity(0.05)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.scaled(size: DS.fontBody, weight: .medium))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.scaled(size: DS.fontFootnote))
                            .foregroundStyle(.gray)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(DS.spacingLG)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Condition Row
private struct ConditionRow: View {
    let condition: AlertCondition
    let onEdit: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            Button(action: onEdit) {
                HStack(spacing: DS.spacingMD) {
                    Image(systemName: condition.type.icon)
                        .font(.scaled(size: DS.fontHeadline))
                        .foregroundStyle(.cyan)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.cyan.opacity(0.15)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(condition.type.localizedName)
                            .font(.scaled(size: DS.fontCallout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(conditionDescription)
                            .font(.scaled(size: DS.fontFootnote))
                            .foregroundStyle(.gray)
                        if condition.usesWindSource {
                            Label(condition.windSourceLabel, systemImage: "antenna.radiowaves.left.and.right")
                                .font(.scaled(size: DS.fontCaption2, weight: .medium))
                                .foregroundStyle(.orange.opacity(0.9))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.scaled(size: DS.fontFootnote, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.scaled(size: DS.fontCallout))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.spacingLG)
        .padding(.vertical, DS.spacingMD)
        .accessibilityElement(children: .combine)
    }

    private var conditionDescription: String {
        // Wind direction: center + spread
        if condition.type == .windDirection {
            let center = Int(condition.windDirectionCenter ?? condition.value1)
            let spread = Int(condition.windDirectionSpread ?? condition.value2 ?? 20)
            return "Vent de \(center)° ±\(spread)°"
        }

        // Sunrise/Sunset
        if condition.type == .sunriseSunset {
            let event = condition.sunEvent == .sunrise ? "lever" : "coucher"
            let timing = condition.sunTiming ?? .before
            let offset = Int(condition.sunOffsetMinutes ?? 30)
            switch timing {
            case .at:     return "Au \(event) du soleil"
            case .before: return "\(offset) min avant le \(event)"
            case .after:  return "\(offset) min après le \(event)"
            }
        }

        let op = condition.operator1.rawValue
        let v1 = formattedValue(condition.value1)
        if condition.operator1 == .between, let v2 = condition.value2 {
            return "\(op) \(v1) et \(formattedValue(v2))"
        }
        return "\(op) \(v1)"
    }

    /// Convertit la valeur stockée (km/h, m, etc.) vers l'unité d'affichage de l'utilisateur,
    /// puis suffixe avec l'unité. Évite le bug "stocké 28 km/h → affiché 28 kn".
    private func formattedValue(_ stored: Double) -> String {
        switch condition.type {
        case .tideHeight:
            let v = UnitFormatter.heightValue(stored, system: themeManager.measureSystem)
            return String(format: "%.1f %@", v, themeManager.measureSystem.heightUnit)
        case .tideCoefficient:
            return "\(Int(stored.rounded()))"
        case .timeBeforeTide, .timeAfterTide, .tideWindow:
            return String(format: "%.1f h", stored)
        case .windSpeed, .windEstablishing:
            let displayInt = UnitFormatter.windSpeedInt(stored, unit: themeManager.windUnit)
            return "\(displayInt) \(themeManager.windUnit.label)"
        case .windDirection:
            return "\(Int(stored.rounded()))°"
        case .sunriseSunset:
            return String(format: "%.0f", stored)
        }
    }
}

// MARK: - Combine Chip
private struct CombineChip: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(symbol)
                    .font(.scaled(size: DS.fontTitle, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? .cyan : .gray)
                Text(title)
                    .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(subtitle)
                    .font(.scaled(size: DS.fontCaption2, weight: .medium))
                    .foregroundStyle(isSelected ? .cyan.opacity(0.9) : .gray.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingXL)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMD)
                    .fill(isSelected ? Color.cyan.opacity(0.15) : Color.glassHighlight.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMD)
                    .stroke(isSelected ? Color.cyan.opacity(0.4) : Color.glassHighlight.opacity(0.1),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

// MARK: - Action Row
private struct ActionRow: View {
    let actionType: AlertActionType
    let isActive: Bool
    let message: String?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: actionType.icon)
                .font(.scaled(size: DS.fontTitle3))
                .foregroundStyle(isActive ? .cyan : .gray)
                .frame(width: 36, height: 36)
                .background(Circle().fill(isActive ? Color.cyan.opacity(0.2) : Color.glassHighlight.opacity(0.05)))

            VStack(alignment: .leading, spacing: 2) {
                Text(actionType.localizedName)
                    .font(.scaled(size: DS.fontBody, weight: .medium))
                    .foregroundStyle(.primary)
                if let message, isActive {
                    Text(message)
                        .font(.scaled(size: DS.fontFootnote))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isActive }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(.cyan)
        }
        .padding(DS.spacingLG)
    }
}

// MARK: - Alert Name Sheet
private struct AlertNameSheet: View {
    @Binding var name: String
    let isEditing: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var showEmptyError = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: DS.spacingXL) {
            Text(isEditing ? "Modifier le nom" : "Nom de l'alerte")
                .font(.scaled(size: DS.fontTitle3, weight: .bold))
                .foregroundStyle(.primary)

            Text("Donnez un nom pour identifier cette alerte")
                .font(.scaled(size: DS.fontCallout))
                .foregroundStyle(.gray)

            TextField("Ex : Grande marée à Brest", text: $name)
                .textFieldStyle(.plain)
                .font(.scaled(size: DS.fontHeadline))
                .foregroundStyle(.primary)
                .padding(DS.spacingMD)
                .focused($isFocused)
                .background(RoundedRectangle(cornerRadius: DS.radiusMD).fill(Color.glassHighlight.opacity(0.07)))
                .overlay(
                    Group {
                        if showEmptyError {
                            RoundedRectangle(cornerRadius: DS.radiusMD)
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                        }
                    }
                )

            if showEmptyError {
                Text("Le nom est requis")
                    .font(.scaled(size: DS.fontFootnote))
                    .foregroundStyle(.red)
            }

            HStack(spacing: DS.spacingMD) {
                Button("Annuler") { onCancel() }
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.spacingMD)

                Button(isEditing ? "Enregistrer" : "Créer") {
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        showEmptyError = true
                    } else {
                        onConfirm()
                    }
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.spacingMD)
                .background(Capsule().fill(Color.accentGradient))
            }
        }
        .padding(DS.spacingXXL)
        .onAppear { isFocused = true }
    }
}

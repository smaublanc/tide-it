//
//  SportSetupView.swift
//  Tide It
//
//  « Mes sports » : l'utilisateur active les sports qu'il pratique et règle leurs conditions
//  (vent mini/maxi, direction, hauteur d'eau, heures avant/après pleine/basse mer). On réutilise
//  le builder de conditions des alertes (`AlertConditionBuilderView`, dont le module de direction
//  du vent). Le calendrier ne suit que les sports activés.
//

import SwiftUI

struct SportSetupView: View {
    /// Spot dont on règle les sports — les conditions sont PROPRES À CE SPOT.
    let portID: String
    @ObservedObject private var sportStore = SportSetupStore.shared
    @ObservedObject private var premium = PremiumManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var conditionEdit: ConditionEdit?
    @State private var showPaywall = false

    private struct ConditionEdit: Identifiable {
        let id = UUID()
        let sport: WindSport
        let existing: AlertCondition?
    }

    /// Sports réglables sur CE spot. Le SURF est un mode à part, réservé aux spots de surf :
    /// on ne le propose pas à l'édition sur un port classique (cohérent avec les fenêtres GO).
    private var visibleSports: [WindSport] {
        let isSurfSpot = SurfSpotCatalog.shared.spot(id: portID) != nil
        let all = WindSport.allCases.filter { isSurfSpot || !$0.isSurf }
        // Surf EN PREMIER (sur un spot de surf), le reste dans l'ordre de l'enum.
        return all.filter(\.isSurf) + all.filter { !$0.isSurf }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: DS.spacingXL) {
                Text("Règle les sports que tu pratiques SUR CE SPOT et leurs conditions. Le calendrier ne suit que les sports activés ici. (Gratuit : 1 sport.)")
                    .font(.scaled(size: DS.fontFootnote))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(visibleSports.enumerated()), id: \.element) { idx, sport in
                    sportCard(sport)
                    if idx < visibleSports.count - 1 {
                        Rectangle()
                            .fill(Color.glassHighlight.opacity(0.08))
                            .frame(height: 0.5)
                    }
                }
            }
            .padding(DS.spacingXL)
            .padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle("Mes sports")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }.foregroundStyle(.cyan)
            }
        }
        .sheet(item: $conditionEdit) { edit in
            AlertConditionBuilderView(existingCondition: edit.existing) { cond in
                var conds = sportStore.setup(edit.sport, for: portID).conditions
                if let idx = conds.firstIndex(where: { $0.id == cond.id }) { conds[idx] = cond }
                else { conds.append(cond) }
                sportStore.setConditions(edit.sport, conds, for: portID)
            }
            .presentationDetents([.medium, .large])
            .sheetBackground()
        }
        .sheet(isPresented: $showPaywall) {
            PremiumPaywallView()
                .presentationDetents([.large])
                .sheetBackground()
        }
    }

    // MARK: - Carte d'un sport

    private func sportCard(_ sport: WindSport) -> some View {
        let setup = sportStore.setup(sport, for: portID)
        return VStack(alignment: .leading, spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingMD) {
                Image(systemName: sport.icon)
                    .font(.scaled(size: DS.fontTitle3))
                    .foregroundStyle(setup.enabled ? sport.color : .gray)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill((setup.enabled ? sport.color : Color.gray).opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(sport.localizedName)
                        .font(.scaled(size: DS.fontBody, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(setup.enabled ? "Suivi activé" : "Non suivi")
                        .font(.scaled(size: DS.fontFootnote))
                        .foregroundStyle(setup.enabled ? sport.color : .gray)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { setup.enabled },
                    set: { on in
                        HapticManager.shared.impact(.light)
                        // Gratuit : 1 SEUL sport actif par spot. Activer un 2ᵉ → paywall.
                        if on, !setup.enabled, !premium.isPremium,
                           sportStore.enabledCount(for: portID) >= 1 {
                            showPaywall = true
                            return
                        }
                        sportStore.setEnabled(sport, on, for: portID)
                    }
                ))
                .labelsHidden()
                .tint(sport.color)
            }

            if setup.enabled {
                Rectangle().fill(Color.glassHighlight.opacity(0.1)).frame(height: 0.5)
                autoRow(sport, setup)
                if setup.auto {
                    // Mode AUTO (exclusif) : l'app calcule → on n'affiche QUE le niveau du rider.
                    riderLevelRow(sport, setup)
                } else if sport.isSurf {
                    // Manuel SURF : conditions de HOULE (pas de conditions de vent) → éditeur dédié.
                    SurfConditionsEditor(portID: portID, store: sportStore)
                } else {
                    conditionList(sport, setup.conditions)
                }
            }
        }
        .padding(.vertical, DS.spacingMD)
        // Sans cadre : ni fond ni liseré. Les sports sont séparés par un fin trait.
    }

    /// Ligne « Automatique » : l'app calcule le GO (note ≥ seuil). Exclusif → masque les conditions.
    private func autoRow(_ sport: WindSport, _ setup: SportSetup) -> some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: "sparkles")
                .font(.scaled(size: DS.fontCallout))
                .foregroundStyle(.cyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automatique")
                    .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                    .foregroundStyle(.primary)
                Text("L'app calcule le meilleur moment, sans réglage")
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.gray)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { setup.auto },
                set: { on in
                    HapticManager.shared.impact(.light)
                    sportStore.setAuto(sport, on, for: portID)
                }
            ))
            .labelsHidden()
            .tint(sport.color)
        }
    }

    /// Niveau du rider (mode AUTO) : pilote le seuil GO + les plages de confort (vent/houle).
    /// Menu (pas segmenté) car 4 libellés longs ne tiennent pas en segments.
    private func riderLevelRow(_ sport: WindSport, _ setup: SportSetup) -> some View {
        HStack(spacing: DS.spacingMD) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Niveau du rider")
                    .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                    .foregroundStyle(.primary)
                Text("L'app croise toutes les données pour le meilleur créneau, calé sur ton niveau.")
                    .font(.scaled(size: DS.fontCaption2, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { setup.riderLevel },
                set: { lvl in
                    HapticManager.shared.impact(.light)
                    sportStore.setRiderLevel(sport, lvl, for: portID)
                }
            )) {
                ForEach(RiderLevel.allCases) { lvl in
                    Text(lvl.localizedName).tag(lvl)
                }
            }
            .pickerStyle(.menu)
            .tint(sport.color)
        }
    }

    private func conditionList(_ sport: WindSport, _ conditions: [AlertCondition]) -> some View {
        VStack(spacing: DS.spacingSM) {
            ForEach(conditions) { c in
                HStack(spacing: DS.spacingMD) {
                    Button {
                        HapticManager.shared.impact(.light)
                        conditionEdit = ConditionEdit(sport: sport, existing: c)
                    } label: {
                        HStack(spacing: DS.spacingMD) {
                            Image(systemName: c.type.icon)
                                .font(.scaled(size: DS.fontCallout))
                                .foregroundStyle(.cyan)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.type.localizedName)
                                    .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(summary(c))
                                    .font(.scaled(size: DS.fontCaption))
                                    .foregroundStyle(.gray)
                                if c.usesWindSource {
                                    Label(c.windSourceLabel, systemImage: "antenna.radiowaves.left.and.right")
                                        .font(.scaled(size: DS.fontCaption2, weight: .medium))
                                        .foregroundStyle(.orange.opacity(0.9))
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.scaled(size: DS.fontCaption2, weight: .semibold))
                                .foregroundStyle(.gray)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        HapticManager.shared.notification(.warning)
                        var conds = conditions
                        conds.removeAll { $0.id == c.id }
                        sportStore.setConditions(sport, conds, for: portID)
                    } label: {
                        Image(systemName: "trash")
                            .font(.scaled(size: DS.fontFootnote))
                            .foregroundStyle(.red.opacity(0.8))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                HapticManager.shared.impact(.light)
                conditionEdit = ConditionEdit(sport: sport, existing: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.scaled(size: DS.fontCallout))
                    Text("Ajouter une condition")
                        .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                }
                .foregroundStyle(.cyan)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DS.spacingSM)
                // Sans cadre : simple action texte + icône, alignée à gauche.
            }
            .buttonStyle(.plain)

            if conditions.isEmpty {
                Text("Sans condition, ce sport ne s'affichera pas. Ajoute au moins une plage de vent.")
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Résumé lisible d'une condition (unités de l'utilisateur)

    private func summary(_ c: AlertCondition) -> String {
        switch c.type {
        case .windSpeed:
            let lo = UnitFormatter.windSpeedInt(c.value1, unit: themeManager.windUnit)
            if c.operator1 == .between, let v2 = c.value2 {
                let hi = UnitFormatter.windSpeedInt(v2, unit: themeManager.windUnit)
                return "\(lo)–\(hi) \(themeManager.windUnit.label)"
            }
            return "\(c.operator1.operatorSymbol) \(lo) \(themeManager.windUnit.label)"
        case .windDirection:
            let center = Int(c.windDirectionCenter ?? c.value1)
            let spread = Int(c.windDirectionSpread ?? c.value2 ?? 20)
            return "vent de \(center)° ±\(spread)°"
        case .tideHeight:
            let v = UnitFormatter.heightValue(c.value1, system: themeManager.measureSystem)
            return "\(c.operator1.operatorSymbol) \(String(format: "%.1f", v)) \(themeManager.measureSystem.heightUnit)"
        case .timeBeforeTide, .timeAfterTide:
            let ref = c.tideType == nil ? "marée" : (c.tideType == true ? "pleine mer" : "basse mer")
            let dir = c.type == .timeBeforeTide ? "avant" : "après"
            return "\(String(format: "%.1f", c.value1)) h \(dir) \(ref)"
        case .tideWindow:
            let ref = c.tideType == nil ? "marée" : (c.tideType == true ? "PM" : "BM")
            return "\(String(format: "%.1f", c.value1)) h avant → \(String(format: "%.1f", c.value2 ?? c.value1)) h après \(ref)"
        case .tideCoefficient:
            return "\(c.operator1.operatorSymbol) \(Int(c.value1))"
        case .sunriseSunset, .windEstablishing:
            return c.type.localizedName
        }
    }
}

// MARK: - Éditeur de conditions SURF (mode manuel)

/// Conditions de HOULE éditables à la main pour un spot de surf (mode manuel) : hauteur mini/maxi,
/// période mini, vent maxi, marée idéale — le surf n'a PAS de conditions de vent comme le kite.
/// Source unique = `SportSetupStore.setSurfConditions`. Les sliders ne persistent qu'à la FIN du
/// glissement (onEditingChanged) → aucun spam d'écriture/iCloud. 3 presets comme point de départ.
private struct SurfConditionsEditor: View {
    let portID: String
    @ObservedObject var store: SportSetupStore
    @State private var sc: SurfConditions

    init(portID: String, store: SportSetupStore) {
        self.portID = portID
        self.store = store
        _sc = State(initialValue: store.setup(.surf, for: portID).surfConditions ?? SurfConditions())
    }

    private let orange = Color.orange
    private var windUnit: WindSpeedUnit {
        WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh
    }

    private func commit() {
        HapticManager.shared.impact(.light)
        store.setSurfConditions(sc, for: portID)
    }

    private struct Preset { let name: String; let minH: Double; let maxH: Double?; let period: Double; let wind: Double }
    private let presets: [Preset] = [
        .init(name: "Petit propre", minH: 0.4, maxH: 1.2, period: 8,  wind: 25),
        .init(name: "Classique",    minH: 0.7, maxH: 2.0, period: 9,  wind: 35),
        .init(name: "Costaud",      minH: 1.2, maxH: nil, period: 11, wind: 40),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingMD) {
                Image(systemName: "water.waves")
                    .font(.scaled(size: DS.fontCallout)).foregroundStyle(orange).frame(width: 28)
                Text("Conditions de houle")
                    .font(.scaled(size: DS.fontSubheadline, weight: .medium)).foregroundStyle(.primary)
                Spacer()
            }

            // Presets (point de départ — l'utilisateur affine ensuite).
            HStack(spacing: DS.spacingSM) {
                ForEach(presets, id: \.name) { p in
                    Button {
                        sc.minSwellHeight = p.minH; sc.maxSwellHeight = p.maxH
                        sc.minSwellPeriod = p.period; sc.maxWindKmh = p.wind
                        commit()
                    } label: {
                        Text(LocalizedStringKey(p.name))
                            .font(.scaled(size: DS.fontCaption, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(orange.opacity(0.15)))
                            .foregroundStyle(orange)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            sliderRow(title: "Houle mini", value: $sc.minSwellHeight, range: 0.3...3.0, step: 0.1,
                      label: String(format: "%.1f m", sc.minSwellHeight))
            maxHeightRow
            sliderRow(title: "Période mini", value: $sc.minSwellPeriod, range: 5...16, step: 1,
                      label: "\(Int(sc.minSwellPeriod)) s")
            sliderRow(title: "Vent maxi", value: $sc.maxWindKmh, range: 15...50, step: 1,
                      label: UnitFormatter.windSpeed(sc.maxWindKmh, unit: windUnit))
            tideRow
        }
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LocalizedStringKey(title)).font(.scaled(size: DS.fontCaption)).foregroundStyle(.gray)
                Spacer()
                Text(label).font(.scaled(size: DS.fontFootnote, weight: .semibold))
                    .foregroundStyle(.primary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step) { editing in if !editing { commit() } }
                .tint(orange)
        }
    }

    @ViewBuilder private var maxHeightRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Houle maxi").font(.scaled(size: DS.fontCaption)).foregroundStyle(.gray)
                Spacer()
                Text(sc.maxSwellHeight.map { String(format: "%.1f m", $0) } ?? String(localized: "illimité"))
                    .font(.scaled(size: DS.fontFootnote, weight: .semibold)).foregroundStyle(.primary).monospacedDigit()
            }
            HStack(spacing: DS.spacingSM) {
                Slider(value: Binding(get: { sc.maxSwellHeight ?? 5.0 },
                                      set: { sc.maxSwellHeight = $0 }),
                       in: 1.0...5.0, step: 0.1) { editing in if !editing { commit() } }
                    .tint(orange)
                    .disabled(sc.maxSwellHeight == nil)
                Button {
                    sc.maxSwellHeight = (sc.maxSwellHeight == nil) ? 2.5 : nil
                    commit()
                } label: {
                    Image(systemName: sc.maxSwellHeight == nil ? "infinity" : "xmark.circle.fill")
                        .font(.scaled(size: DS.fontCallout)).foregroundStyle(orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var tideRow: some View {
        HStack {
            Text("Marée idéale").font(.scaled(size: DS.fontCaption)).foregroundStyle(.gray)
            Spacer()
            Picker("", selection: Binding(get: { sc.idealTideStage },
                                          set: { sc.idealTideStage = $0; commit() })) {
                Text("Indifférent").tag(TideStage?.none)
                ForEach(TideStage.allCases) { st in
                    Text(st.localizedName).tag(TideStage?.some(st))
                }
            }
            .pickerStyle(.menu).tint(orange)
        }
    }
}

//
//  ThemeManager.swift
//  Tide It
//
//  Gestion de l'apparence et des unités.
//

import SwiftUI

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return String(localized: "Système")
        case .light:  return String(localized: "Clair")
        case .dark:   return String(localized: "Sombre")
        }
    }
}

// MARK: - Unit System

enum MeasureSystem: String, CaseIterable {
    case metric
    case imperial

    var label: String {
        switch self {
        case .metric:   return String(localized: "Métrique")
        case .imperial: return String(localized: "Impérial")
        }
    }

    var heightUnit: String {
        switch self {
        case .metric:   return "m"
        case .imperial: return "ft"
        }
    }

    var tempUnit: String {
        switch self {
        case .metric:   return "°C"
        case .imperial: return "°F"
        }
    }
}

enum WindSpeedUnit: String, CaseIterable {
    case kmh   = "km/h"
    case knots = "kn"
    case ms    = "m/s"
    case mph   = "mph"

    var label: String { rawValue }
}

// MARK: - Unit Formatter (conversion helpers)

enum UnitFormatter {

    // MARK: Height (meters → display)
    static func height(_ meters: Double, system: MeasureSystem, decimals: Int = 1) -> String {
        switch system {
        case .metric:
            return String(format: "%.\(decimals)f m", locale: Locale.current, meters)
        case .imperial:
            let ft = meters * 3.28084
            return String(format: "%.\(decimals)f ft", locale: Locale.current, ft)
        }
    }

    static func heightValue(_ meters: Double, system: MeasureSystem) -> Double {
        system == .imperial ? meters * 3.28084 : meters
    }

    /// Inverse de `heightValue` : valeur affichée (m ou ft) → canonical interne (m)
    static func metersFromHeight(_ displayValue: Double, system: MeasureSystem) -> Double {
        system == .imperial ? displayValue / 3.28084 : displayValue
    }

    // MARK: Temperature (Celsius → display)
    static func temp(_ celsius: Double, system: MeasureSystem) -> String {
        switch system {
        case .metric:
            return "\(Int(celsius.rounded()))°C"
        case .imperial:
            let f = celsius * 9 / 5 + 32
            return "\(Int(f.rounded()))°F"
        }
    }

    static func tempValue(_ celsius: Double, system: MeasureSystem) -> Double {
        system == .imperial ? celsius * 9 / 5 + 32 : celsius
    }

    // MARK: Wind speed (km/h → display unit)
    /// Input is always km/h (the internal storage format)
    static func windSpeed(_ kmh: Double, unit: WindSpeedUnit) -> String {
        let v = windSpeedValue(kmh, unit: unit)
        return "\(Int(v.rounded())) \(unit.label)"
    }

    static func windSpeedValue(_ kmh: Double, unit: WindSpeedUnit) -> Double {
        switch unit {
        case .kmh:   return kmh
        case .knots: return kmh / 1.852
        case .ms:    return kmh / 3.6
        case .mph:   return kmh / 1.609344
        }
    }

    /// Inverse de `windSpeedValue` : valeur affichée (kn, mph, m/s) → canonical interne (km/h)
    static func kmhFromWindSpeed(_ displayValue: Double, unit: WindSpeedUnit) -> Double {
        switch unit {
        case .kmh:   return displayValue
        case .knots: return displayValue * 1.852
        case .ms:    return displayValue * 3.6
        case .mph:   return displayValue * 1.609344
        }
    }

    static func windSpeedInt(_ kmh: Double, unit: WindSpeedUnit) -> Int {
        Int(windSpeedValue(kmh, unit: unit).rounded())
    }
}

/// Rendu de la courbe principale : classique (marée) / vent / surf. Piloté par le bouton bas-droite.
enum CurveMode: String, CaseIterable {
    case classic, wind, surf

    /// État suivant dans le cycle classique → vent → surf → classique.
    var next: CurveMode {
        switch self {
        case .classic: return .wind
        case .wind:    return .surf
        case .surf:    return .classic
        }
    }
    /// Cycle qui SAUTE le mode surf quand le port n'est pas un spot de surf (pas de houle pertinente) :
    /// classique → vent → classique. Le mode surf n'a de sens que sur un spot du catalogue surf.
    func next(surfAvailable: Bool) -> CurveMode {
        switch self {
        case .classic: return .wind
        case .wind:    return surfAvailable ? .surf : .classic
        case .surf:    return .classic
        }
    }
    /// Icône du bouton selon l'état courant.
    var buttonIcon: String {
        switch self {
        case .classic: return "water.waves"
        case .wind:    return "wind"
        case .surf:    return "figure.surfing"
        }
    }
    /// Libellé court (caption sous le bouton + accessibilité).
    var label: String {
        switch self {
        case .classic: return "Marée"
        case .wind:    return "Vent"
        case .surf:    return "Surf"
        }
    }
    /// Couleur d'accent néon par mode (glow du bouton + pastille de feedback).
    var accent: Color {
        switch self {
        case .classic: return .cyan      // marée
        case .wind:    return .mint       // vent
        case .surf:    return .orange     // surf = ORANGE (cohérent avec toute l'identité surf)
        }
    }
}

// MARK: - Theme Manager

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    /// Pêche à pied RETIRÉE du périmètre (juin 2026) : pas de plus-value sur ces données.
    /// Flag de désactivation (vs suppression) car l'infra d'alerte est partagée. Repasser à
    /// `true` réactive tout (vues/notifier/sync laissés intacts).
    static let pecheAPiedEnabled = false

    // Apparence — thème sombre par défaut
    @AppStorage("appearanceMode") var appearance: AppearanceMode = .dark {
        didSet { objectWillChange.send(); CloudSyncService.shared.saveSettings() }
    }

    /// Mode de rendu de la courbe (remplace l'ancien Bool windMode). @AppStorage RawRepresentable.
    @AppStorage("curveMode") var curveMode: CurveMode = .classic {
        didSet { objectWillChange.send(); CloudSyncService.shared.saveSettings() }
    }
    /// Shim rétro-compat : tout l'ancien code `windMode` (lectures + l'écriture du calendrier)
    /// continue de fonctionner sans modification.
    var windMode: Bool {
        get { curveMode == .wind }
        set { curveMode = newValue ? .wind : .classic }
    }

    /// Effet de profondeur : particules ambiantes qui suivent le sens de la marée.
    @AppStorage("tideParticlesEnabled") var tideParticles: Bool = true {
        didSet { objectWillChange.send(); CloudSyncService.shared.saveSettings() }
    }

    // Unités
    @AppStorage("measureSystem") var measureSystem: MeasureSystem = .metric {
        didSet {
            objectWillChange.send()
            syncUnitsToAppGroup()
            CloudSyncService.shared.saveSettings()
        }
    }

    @AppStorage("windSpeedUnit") var windUnit: WindSpeedUnit = .kmh {
        didSet {
            objectWillChange.send()
            syncUnitsToAppGroup()
            CloudSyncService.shared.saveSettings()
        }
    }

    /// Vent minimum (km/h) à partir duquel le rider peut naviguer (selon son quiver).
    /// Pilote le plancher de vent du scoring kite/wing ET les fenêtres GO. Synchronisé iCloud.
    @AppStorage("riderMinWindKmh") var riderMinWindKmh: Double = 12 {
        didSet {
            objectWillChange.send()
            CloudSyncService.shared.saveSettings()
        }
    }

    /// Vent MAXIMUM praticable (km/h) — au-delà c'est trop (sécurité / mauvaise toile).
    /// Borne haute des fenêtres GO du ruban Vent & Marée. Synchronisé iCloud.
    @AppStorage("riderMaxWindKmh") var riderMaxWindKmh: Double = 65 {
        didSet {
            objectWillChange.send()
            CloudSyncService.shared.saveSettings()
        }
    }

    /// Alerte proactive « Sorties Parfaites » (fenêtres pour tes activités). Activée par défaut.
    @AppStorage("pwAlertsEnabled") var pwAlertsEnabled: Bool = true {
        didSet {
            objectWillChange.send()
            CloudSyncService.shared.saveSettings()
        }
    }

    /// Alerte proactive « Pêche à pied » (basses mers à fort coefficient). Désactivée par défaut (premium).
    @AppStorage("pecheAlertsEnabled") var pecheAlertsEnabled: Bool = false {
        didSet {
            objectWillChange.send()
            CloudSyncService.shared.saveSettings()
        }
    }

    /// Jauge de confiance — corriger le vent prévu (courbe + fenêtres GO) par le BIAIS LOCAL appris
    /// (modèle vs balise). Premium. Opt-in (false par défaut) : on ne déforme JAMAIS la prévision sans
    /// l'accord explicite du rider. N'a d'effet que si le biais mesuré est fiable et significatif.
    @AppStorage("debiasGoEnabled") var debiasGoEnabled: Bool = false {
        didSet {
            objectWillChange.send()
            CloudSyncService.shared.saveSettings()
        }
    }

    /// ColorScheme résolu (nil = système)
    var resolvedColorScheme: ColorScheme? {
        appearance.colorScheme
    }

    /// Synchronise les préférences d'unités vers l'App Group pour widgets/watch
    private func syncUnitsToAppGroup() {
        let shared = UserDefaults(suiteName: "group.seb.Tide-It")
        shared?.set(measureSystem.rawValue, forKey: "measureSystem")
        shared?.set(windUnit.rawValue, forKey: "windSpeedUnit")
    }

    private init() {
        // Récupère les réglages iCloud (apparence, unités, affichage) au lancement.
        // @AppStorage lit UserDefaults en direct → les valeurs tirées d'iCloud sont
        // prises en compte immédiatement.
        CloudSyncService.shared.mergeInitialSettings()
        // Migration unique : l'ancien Bool "windMode" → "curveMode" (.wind) si jamais réglé.
        if UserDefaults.standard.object(forKey: "curveMode") == nil,
           UserDefaults.standard.bool(forKey: "windMode") {
            curveMode = .wind
        }
        // Sync initiale des unités vers l'App Group (widgets / Watch).
        syncUnitsToAppGroup()
        // Réglages modifiés depuis un autre appareil → rafraîchir l'UI + le widget.
        CloudSyncService.shared.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.syncUnitsToAppGroup()
            ActivityPreferences.shared.reloadFromDefaults()
            SpotConfigStore.shared.reloadFromDefaults()
            SportSetupStore.shared.reloadFromDefaults()
        }
    }
}

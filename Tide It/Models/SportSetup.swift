//
//  SportSetup.swift
//  Tide It
//
//  « Mes sports » : l'utilisateur configure une fois ses sports de vent et leurs conditions,
//  puis active le suivi. Le calendrier 7 jours n'affiche QUE les sports activés, selon LEURS
//  conditions. App orientée vent : pas de houle.
//
//  Un sport = un jeu de `AlertCondition` (on réutilise tout le modèle d'alerte : vent mini/maxi,
//  direction du vent ± plage, hauteur d'eau, heures avant/après pleine ou basse mer) + un toggle.
//

import SwiftUI

enum WindSport: String, CaseIterable, Identifiable, Codable {
    case kitesurf = "Kitesurf"
    case kitefoil = "Kitefoil"
    case wing     = "Wing"
    case voile    = "Voile"
    /// Sport de HOULE (pas de vent) — évalué par ses `SurfConditions`, pas par des conditions de vent.
    case surf     = "Surf"

    var id: String { rawValue }

    /// Sport piloté par la HOULE (SurfConditions) plutôt que par le vent. Le moteur GO le route
    /// vers un chemin dédié ; sa fiche de conditions « vent » n'est pas utilisée.
    var isSurf: Bool { self == .surf }

    /// Activité de scoring correspondante (pour le mode AUTO = note de l'app ≥ seuil).
    /// La voile a désormais SON profil (`.sailing`) : plage de vent plus large et plus basse.
    var nauticalActivity: NauticalActivity {
        switch self {
        case .kitesurf: return .kitesurfing
        case .kitefoil:  return .kitefoil
        case .wing:      return .wingfoil
        case .voile:     return .sailing
        case .surf:      return .surfing
        }
    }

    var localizedName: String {
        switch self {
        case .kitesurf: return String(localized: "Kitesurf")
        case .kitefoil: return String(localized: "Kitefoil")
        case .wing:     return String(localized: "Wing")
        case .voile:    return String(localized: "Voile")
        case .surf:     return String(localized: "Surf")
        }
    }

    var icon: String {
        switch self {
        case .kitesurf: return "wind"
        case .kitefoil: return "water.waves.and.arrow.up"
        case .wing:     return "figure.surfing"
        case .voile:    return "sailboat.fill"
        case .surf:     return "figure.surfing"
        }
    }

    var color: Color {
        switch self {
        case .kitesurf: return .mint
        case .kitefoil: return .green
        case .wing:     return .pink
        case .voile:    return .blue
        case .surf:     return .orange   // identité surf = ORANGE (calendrier + fenêtres GO + légende)
        }
    }

    /// Conditions de départ : la plage de vent praticable typique du sport (km/h, canonique).
    /// L'utilisateur ajoute ensuite direction / hauteur d'eau / fenêtre marée selon son spot.
    /// Réglage par défaut SIMPLE : vent 10–20 nœuds, AUCUNE autre condition. Ainsi, dès qu'un
    /// sport est activé, le calendrier affiche déjà des fenêtres GO (l'utilisateur affine ensuite).
    /// (10 kn ≈ 18,5 km/h, 20 kn ≈ 37 km/h — stocké en km/h canonique.)
    var defaultConditions: [AlertCondition] {
        switch self {
        // Le surf est évalué par ses SurfConditions (houle), pas par des conditions de vent.
        case .surf: return []
        default:    return [AlertCondition(type: .windSpeed, operator1: .between, value1: 18.5, value2: 37)]
        }
    }
}

/// Conditions de départ d'un SPORT DE HOULE (surf). Seuils transparents (cohérents avec la
/// marque : pas de boîte noire). Évaluées par `ActivityGoPlanner` sur chaque heure de prévision,
/// qui porte désormais houle/période/direction + vent. Le cap offshore est FIGÉ à la création
/// depuis l'orientation du spot ((orientation+180)%360) → pas besoin de threader le spot.
struct SurfConditions: Codable, Equatable {
    /// Houle minimale exploitable (m). En dessous : flat / trop petit.
    var minSwellHeight: Double = 0.8
    /// Plafond de sécurité (m). nil = pas de plafond (au rider de juger).
    var maxSwellHeight: Double? = nil
    /// Période minimale (s) : sépare une vraie houle d'un clapot de vent.
    var minSwellPeriod: Double = 8
    /// Vent au-delà duquel c'est lessivé (km/h), quelle que soit la direction.
    var maxWindKmh: Double = 35
    /// Vent faible (km/h) : glassy → toujours OK quelle que soit la direction.
    var glassyMaxKmh: Double = 12
    /// Cap OFFSHORE du spot (deg) = (orientation+180)%360, figé à la création. nil = pas de gate direction.
    var offshoreBearingDeg: Double? = nil
    /// Tolérance ± (deg) autour de l'offshore (large : side-offshore reste propre).
    var offshoreToleranceDeg: Double = 60
    /// Demi-fenêtre d'exposition à la HOULE (deg) : la houle doit venir à ±cette valeur du CAP
    /// du spot (= offshore+180). Au-delà, le spot est dans l'ombre → pas de vagues exploitables.
    var swellWindowSpreadDeg: Double = 80
    /// Phase de marée idéale du spot (gate OPTIONNEL). nil = on ne contraint pas la marée (on ne
    /// devine pas la marée idéale d'un spot → pas de faux négatifs ; l'utilisateur l'affine).
    var idealTideStage: TideStage? = nil

    /// Vrai si l'heure de prévision satisfait le CROISEMENT surf : taille + période + SENS DE
    /// HOULE (exposition au cap) + VENT (offshore/glassy) + MARÉE (optionnelle). Pur, sans I/O.
    /// `tideState` (depuis la marée du port de réf) n'est requis que si `idealTideStage` est défini.
    func isSatisfied(at f: HourlyForecast, tideState: TideCalculator.TideState? = nil) -> Bool {
        // 1. Taille de houle (houle si dispo, sinon mer totale).
        guard let h = f.swellHeight ?? f.waveHeight, h >= minSwellHeight else { return false }
        if let maxH = maxSwellHeight, h > maxH { return false }
        // 2. Période : houle organisée (vs clapot de vent).
        let period = f.swellPeriod ?? f.wavePeriod ?? 0
        guard period >= minSwellPeriod else { return false }
        // 3. SENS DE HOULE : la houle doit être pointée vers le spot (exposition au cap).
        if let off = offshoreBearingDeg, let swellDir = f.swellDirection ?? f.waveDirection {
            let facing = (off + 180).truncatingRemainder(dividingBy: 360)   // cap mer ouverte = offshore+180
            let delta = abs(((swellDir - facing + 540).truncatingRemainder(dividingBy: 360)) - 180)
            if delta > swellWindowSpreadDeg { return false }   // houle de derrière / mal orientée
        }
        // 4. VENT : lessivé = non ; sinon glassy OK, ou offshore dans la tolérance (sens INVERSE du kite).
        let wind = f.windSpeedKmh
        if wind > maxWindKmh { return false }
        if wind > glassyMaxKmh, let off = offshoreBearingDeg {
            let d = abs(((f.windDirection - off + 540).truncatingRemainder(dividingBy: 360)) - 180)
            if d > offshoreToleranceDeg { return false }   // onshore / cross fort → surface dégradée
        }
        // 5. MARÉE (optionnel) : phase idéale du spot, lue via la marée du port de référence.
        if let ideal = idealTideStage, let state = tideState,
           !SurfConditions.tideMatches(state, ideal: ideal) {
            return false
        }
        return true
    }

    /// La phase de marée courante correspond-elle à la phase idéale du spot (± ~30 % de course) ?
    static func tideMatches(_ state: TideCalculator.TideState, ideal: TideStage) -> Bool {
        let p = state.percentToNextTide
        let level: Double
        switch state.trend {
        case .rising:    level = p          // de bas (0) vers haut (1)
        case .falling:   level = 1 - p      // de haut (1) vers bas (0)
        case .highSlack: level = 1
        case .lowSlack:  level = 0
        }
        let target: Double = (ideal == .low) ? 0 : (ideal == .high ? 1 : 0.5)
        return abs(level - target) <= 0.3
    }

    /// Conditions surf INTELLIGENTES dérivées d'un spot : cap OFFSHORE depuis l'orientation de
    /// la côte, et seuils houle/période adaptés au NIVEAU du spot (débutant = accueillant pour
    /// catcher les petits jours propres ; expert/reef = exigeant). Objectif : proposer d'emblée
    /// les meilleures conditions, justes pour CE spot — « le meilleur à tout niveau ».
    static func intelligent(facingBearingDeg: Double?, skillFloor: Int?, breakType: BreakType?) -> SurfConditions {
        var c = SurfConditions()
        if let f = facingBearingDeg {
            c.offshoreBearingDeg = (f + 180).truncatingRemainder(dividingBy: 360)
        }
        switch skillFloor ?? 2 {
        case ...1:                                  // débutant : on capte les petits jours propres
            c.minSwellHeight = 0.4; c.maxSwellHeight = 1.6; c.minSwellPeriod = 7
        case 2:
            c.minSwellHeight = 0.6; c.maxSwellHeight = 2.2; c.minSwellPeriod = 8
        case 3:
            c.minSwellHeight = 0.8; c.maxSwellHeight = 3.0; c.minSwellPeriod = 9
        default:                                    // expert : gros et organisé, pas de plafond
            c.minSwellHeight = 1.2; c.maxSwellHeight = nil; c.minSwellPeriod = 10
        }
        // Reef / point break : il faut une houle plus organisée → période un cran au-dessus.
        if breakType == .reef || breakType == .point { c.minSwellPeriod += 1 }
        return c
    }

    /// Resserre la fenêtre de houle au CONFORT du rider (le niveau prime sur le terrain pour la
    /// taille acceptable) : un débutant ne se voit pas proposer 2,5 m, un expert n'a pas de plafond.
    func adjusted(for level: RiderLevel) -> SurfConditions {
        var c = self
        if let cap = level.surfMaxSwellM {
            c.maxSwellHeight = min(c.maxSwellHeight ?? .greatestFiniteMagnitude, cap)
            c.minSwellHeight = min(c.minSwellHeight, cap - 0.1)   // jamais min > max
        }
        if level == .debutant { c.minSwellHeight = min(c.minSwellHeight, 0.4) }   // capte les petits jours propres
        return c
    }
}

/// Exigence du mode AUTO : à quel point l'app est difficile pour déclarer un créneau GO.
/// Mappe sur un seuil de note (0–100) du scoring de l'app.
enum AutoSensitivity: String, Codable, CaseIterable, Identifiable {
    case souple, normal, strict
    var id: String { rawValue }
    var goThreshold: Int {
        switch self {
        case .souple: return 45
        case .normal: return 60
        case .strict: return 72
        }
    }
    var localizedName: String {
        switch self {
        case .souple: return String(localized: "Souple")
        case .normal: return String(localized: "Normal")
        case .strict: return String(localized: "Strict")
        }
    }
}

/// NIVEAU DU RIDER (remplace l'ancienne « Exigence »). C'est LE bouton du mode AUTO : il croise
/// toutes les données pour proposer les fenêtres JUSTES pour le niveau. Il pilote DEUX choses :
///  1. le SEUIL GO (note ≥ seuil) — un débutant ne veut que des créneaux francs/sûrs (barre haute),
///     un expert accepte le marginal/musclé (barre basse → plus de fenêtres) ;
///  2. les PLAGES DE CONFORT — plafond de vent (sports de vent) et taille de houle max (surf).
enum RiderLevel: String, Codable, CaseIterable, Identifiable {
    case debutant, intermediaire, confirme, expert
    var id: String { rawValue }

    /// Seuil de note (0–100) au-dessus duquel une heure devient GO.
    var goThreshold: Int {
        switch self {
        case .debutant:      return 68
        case .intermediaire: return 60
        case .confirme:      return 52
        case .expert:        return 46
        }
    }

    /// Plafond de vent CONFORT (km/h) du niveau, pour les sports de vent. Combiné par MIN avec le
    /// `riderMaxWindKmh` réglé par l'utilisateur (jamais au-dessus de SON max). Intermédiaire = 50
    /// = l'ancien plafond par défaut → AUCUNE régression pour les utilisateurs migrés ; débutant
    /// abaissé (protection) ; expert quasi-déplafonné (c'est le max utilisateur qui borne).
    var windCeilingKmh: Double {
        switch self {
        case .debutant:      return 35
        case .intermediaire: return 50
        case .confirme:      return 62
        case .expert:        return 90
        }
    }

    /// Plafond de houle confortable (m) pour le surf. nil = pas de plafond (expert juge lui-même).
    var surfMaxSwellM: Double? {
        switch self {
        case .debutant:      return 1.2
        case .intermediaire: return 1.8
        case .confirme:      return 2.5
        case .expert:        return nil
        }
    }

    var localizedName: String {
        switch self {
        case .debutant:      return String(localized: "Débutant")
        case .intermediaire: return String(localized: "Intermédiaire")
        case .confirme:      return String(localized: "Confirmé")
        case .expert:        return String(localized: "Expert")
        }
    }

    /// Migration depuis l'ancienne « Exigence » : souple (barre basse) → expert, normal →
    /// intermédiaire, strict (barre haute) → débutant. Préserve à peu près le seuil de l'utilisateur.
    static func fromLegacy(_ s: AutoSensitivity) -> RiderLevel {
        switch s {
        case .souple: return .expert
        case .normal: return .intermediaire
        case .strict: return .debutant
        }
    }
}

/// Réglage d'un sport : ses conditions + s'il est suivi (affiché dans le calendrier).
struct SportSetup: Codable, Equatable, Identifiable {
    var sport: WindSport
    var enabled: Bool
    var conditions: [AlertCondition]
    /// Conditions de HOULE (surf uniquement). Optionnel → les anciens blobs décodent intacts ;
    /// nil pour un sport de vent. Le moteur GO retombe sur `SurfConditions()` par défaut si nil.
    var surfConditions: SurfConditions? = nil
    /// Mode AUTO (EXCLUSIF) : l'app calcule le GO via son scoring (note ≥ seuil), au lieu des
    /// conditions manuelles. Quand `auto` est vrai, `conditions` est ignoré. Optionnel = rétro-compat.
    var auto: Bool = false
    /// NIVEAU du rider (remplace « Exigence ») : seuil GO + plages de confort. Ignoré si `auto` faux.
    var riderLevel: RiderLevel = .intermediaire

    var id: WindSport { sport }

    init(sport: WindSport, enabled: Bool, conditions: [AlertCondition],
         surfConditions: SurfConditions? = nil, auto: Bool = false,
         riderLevel: RiderLevel = .intermediaire) {
        self.sport = sport
        self.enabled = enabled
        self.conditions = conditions
        self.surfConditions = surfConditions
        self.auto = auto
        self.riderLevel = riderLevel
    }

    enum CodingKeys: String, CodingKey {
        case sport, enabled, conditions, surfConditions, auto, riderLevel
        case autoSensitivity   // hérité (« Exigence ») → migré vers riderLevel, jamais ré-écrit
    }

    // Décodage RÉTRO-COMPATIBLE : un ancien blob (sans riderLevel) migre depuis autoSensitivity ;
    // toute clé absente prend son défaut → AUCUNE perte des réglages utilisateur sur mise à jour.
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        sport = try c.decode(WindSport.self, forKey: .sport)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        conditions = try c.decodeIfPresent([AlertCondition].self, forKey: .conditions) ?? []
        surfConditions = try c.decodeIfPresent(SurfConditions.self, forKey: .surfConditions)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        if let lvl = try c.decodeIfPresent(RiderLevel.self, forKey: .riderLevel) {
            riderLevel = lvl
        } else if let legacy = try c.decodeIfPresent(AutoSensitivity.self, forKey: .autoSensitivity) {
            riderLevel = RiderLevel.fromLegacy(legacy)
        } else {
            riderLevel = .intermediaire
        }
    }

    // Encodage : on n'écrit QUE les champs courants (la clé héritée autoSensitivity est abandonnée).
    func encode(to enc: Encoder) throws {
        var c = enc.container(keyedBy: CodingKeys.self)
        try c.encode(sport, forKey: .sport)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(conditions, forKey: .conditions)
        try c.encodeIfPresent(surfConditions, forKey: .surfConditions)
        try c.encode(auto, forKey: .auto)
        try c.encode(riderLevel, forKey: .riderLevel)
    }
}

/// Stockage des réglages sport — désormais PAR SPOT : chaque port a ses propres conditions
/// + un toggle notifications « fenêtre GO ici » (premium). Un spot jamais configuré HÉRITE du
/// `defaultTemplate` (sports cochés à l'onboarding + conditions par défaut). Persisté + iCloud.
@MainActor
final class SportSetupStore: ObservableObject {
    static let shared = SportSetupStore()
    static let storageKey = "sportSetupsBySpot_v1"
    private static let legacyGlobalKey = "sportSetups"   // ancien store GLOBAL → devient le template

    /// portID → (sport → réglage). Absent ⇒ le spot hérite de `defaultTemplate`.
    @Published private(set) var byPort: [String: [WindSport: SportSetup]] = [:]
    /// portID → notifications « fenêtre GO ici » activées (premium).
    @Published private(set) var notifyByPort: [String: Bool] = [:]
    /// Réglage par défaut appliqué à tout NOUVEAU spot (= choix de l'onboarding). Modifiable
    /// uniquement via `setTemplateEnabled` (onboarding) — l'édition fine se fait par spot.
    @Published private(set) var defaultTemplate: [WindSport: SportSetup]

    private struct Persisted: Codable {
        var byPort: [String: [SportSetup]]
        var notifyByPort: [String: Bool]
        var template: [SportSetup]
    }

    private init() {
        let loaded = Self.load()
        byPort = loaded.byPort
        notifyByPort = loaded.notifyByPort
        defaultTemplate = loaded.template
    }

    private static func defaultsTemplate() -> [WindSport: SportSetup] {
        var map: [WindSport: SportSetup] = [:]
        for sport in WindSport.allCases {
            map[sport] = SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
        }
        return map
    }

    private static func load() -> (byPort: [String: [WindSport: SportSetup]],
                                   notifyByPort: [String: Bool],
                                   template: [WindSport: SportSetup]) {
        let d = UserDefaults.standard
        // Nouveau format par-spot.
        if let data = d.data(forKey: storageKey),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            var bp: [String: [WindSport: SportSetup]] = [:]
            for (port, arr) in p.byPort {
                var m: [WindSport: SportSetup] = [:]
                for s in arr { m[s.sport] = s }
                bp[port] = m
            }
            var tmpl = defaultsTemplate()
            for s in p.template { tmpl[s.sport] = s }
            return (bp, p.notifyByPort, tmpl)
        }
        // Migration : l'ancien store GLOBAL devient le TEMPLATE (proposition 6 — les sports cochés
        // à l'onboarding restent le défaut des nouveaux spots).
        var tmpl = defaultsTemplate()
        if let data = d.data(forKey: legacyGlobalKey),
           let decoded = try? JSONDecoder().decode([SportSetup].self, from: data) {
            for s in decoded { tmpl[s.sport] = s }
        }
        return ([:], [:], tmpl)
    }

    // MARK: - Lecture par spot
    func setups(for portID: String) -> [WindSport: SportSetup] {
        byPort[portID] ?? defaultTemplate
    }
    func setup(_ sport: WindSport, for portID: String) -> SportSetup {
        setups(for: portID)[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
    }
    /// Sports suivis du spot, ordre stable de l'enum.
    /// RÈGLE : le SURF est un mode à part, réservé aux SPOTS DE SURF (données houle spécifiques).
    /// Un port classique n'accueille jamais l'activité surf → on la retire à la SOURCE, donc
    /// fenêtres GO (courbe + calendrier), notifications et badges l'excluent tous de façon cohérente.
    func enabledSetups(for portID: String) -> [SportSetup] {
        let m = setups(for: portID)
        let isSurfSpot = SurfSpotCatalog.shared.spot(id: portID) != nil
        return WindSport.allCases.compactMap { m[$0] }
            .filter { $0.enabled }
            .filter { isSurfSpot || !$0.sport.isSurf }
    }
    func enabledCount(for portID: String) -> Int { enabledSetups(for: portID).count }
    func anyEnabled(for portID: String) -> Bool { !enabledSetups(for: portID).isEmpty }

    // MARK: - Écriture par spot (matérialise le spot depuis le template au 1er changement)
    private func materialize(_ portID: String) -> [WindSport: SportSetup] {
        byPort[portID] ?? defaultTemplate
    }
    func setEnabled(_ sport: WindSport, _ on: Bool, for portID: String) {
        var m = materialize(portID)
        var s = m[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
        s.enabled = on
        m[sport] = s
        byPort[portID] = m
        persist()
    }
    func setConditions(_ sport: WindSport, _ conditions: [AlertCondition], for portID: String) {
        var m = materialize(portID)
        var s = m[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
        s.conditions = conditions
        m[sport] = s
        byPort[portID] = m
        persist()
    }

    /// Active/désactive le mode AUTO (exclusif) d'un sport pour un spot.
    func setAuto(_ sport: WindSport, _ on: Bool, for portID: String) {
        var m = materialize(portID)
        var s = m[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
        s.auto = on
        m[sport] = s
        byPort[portID] = m
        persist()
    }

    /// Règle le NIVEAU du rider (mode AUTO) d'un sport pour un spot.
    func setRiderLevel(_ sport: WindSport, _ level: RiderLevel, for portID: String) {
        var m = materialize(portID)
        var s = m[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
        s.riderLevel = level
        m[sport] = s
        byPort[portID] = m
        persist()
    }

    /// Conditions de HOULE du surf pour un spot (offshore + seuils). Cf. `SurfConditions.intelligent`.
    func setSurfConditions(_ surf: SurfConditions, for portID: String) {
        var m = materialize(portID)
        var s = m[.surf] ?? SportSetup(sport: .surf, enabled: false, conditions: [])
        s.surfConditions = surf
        m[.surf] = s
        byPort[portID] = m
        persist()
    }

    /// Configure un spot comme SURF UNIQUEMENT : surf activé avec ses conditions de houle, et
    /// TOUS les sports de vent (kite/wing/voile) désactivés. Un spot de surf n'hérite donc PAS
    /// du kite du template d'onboarding. Atomique (un seul persist).
    func configureAsSurfSpot(_ surf: SurfConditions, for portID: String) {
        var m = materialize(portID)
        for sport in WindSport.allCases {
            var s = m[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
            if sport == .surf {
                s.enabled = true
                s.surfConditions = surf
                s.auto = true            // AUTO par défaut : l'app calcule le GO (note ≥ seuil)
            } else {
                s.enabled = false        // pas de kite/wing/voile sur un spot de surf
            }
            m[sport] = s
        }
        byPort[portID] = m
        persist()
    }
    func resetToDefaults(_ sport: WindSport, for portID: String) {
        var m = materialize(portID)
        var s = m[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
        s.conditions = sport.defaultConditions
        m[sport] = s
        byPort[portID] = m
        persist()
    }

    // MARK: - Notifications « fenêtre GO » par spot (premium)
    func notify(for portID: String) -> Bool { notifyByPort[portID] ?? false }
    func setNotify(_ on: Bool, for portID: String) {
        notifyByPort[portID] = on
        persist()
    }
    /// Spots dont la notification « fenêtre GO ici » est active.
    var notifyEnabledPortIDs: [String] { notifyByPort.filter { $0.value }.map(\.key) }

    /// Purge COMPLÈTE des réglages + de l'abonnement « fenêtre GO » d'un spot supprimé.
    /// Indispensable : `notifyByPort[portID]` resté à `true` garde le spot dans
    /// `notifyEnabledPortIDs` → la boucle de fond continue de lui envoyer des notifs GO.
    func removePort(_ portID: String) {
        var changed = false
        if byPort.removeValue(forKey: portID) != nil { changed = true }
        if notifyByPort.removeValue(forKey: portID) != nil { changed = true }
        if changed { persist() }
    }

    // MARK: - Template (onboarding / défaut des nouveaux spots)
    func templateSetup(_ sport: WindSport) -> SportSetup {
        defaultTemplate[sport] ?? SportSetup(sport: sport, enabled: false, conditions: sport.defaultConditions)
    }
    func setTemplateEnabled(_ sport: WindSport, _ on: Bool) {
        var s = templateSetup(sport)
        s.enabled = on
        defaultTemplate[sport] = s
        persist()
    }

    func reloadFromDefaults() {
        let loaded = Self.load()
        if loaded.byPort != byPort { byPort = loaded.byPort }
        if loaded.notifyByPort != notifyByPort { notifyByPort = loaded.notifyByPort }
        if loaded.template != defaultTemplate { defaultTemplate = loaded.template }
    }

    private func persist() {
        var bp: [String: [SportSetup]] = [:]
        for (port, m) in byPort {
            bp[port] = WindSport.allCases.compactMap { m[$0] }
        }
        let p = Persisted(byPort: bp,
                          notifyByPort: notifyByPort,
                          template: WindSport.allCases.compactMap { defaultTemplate[$0] })
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            CloudSyncService.shared.saveSettings()
        }
    }
}

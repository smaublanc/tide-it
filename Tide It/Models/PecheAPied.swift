//
//  PecheAPied.swift
//  Tide It
//
//  Modèles du mode « Pêche à pied » (Premium).
//
//  Principe : la pêche à pied dépend du DÉCOUVERT de l'estran. Plus le
//  coefficient est élevé (vives-eaux), plus la mer se retire bas et plus la
//  zone accessible est grande. La fenêtre utile se situe autour de la basse
//  mer ; le danger vient de la marée montante qui revient vite.
//

import SwiftUI

// MARK: - Qualité d'une sortie

enum ForagingQuality: Int, Comparable {
    case modest      // estran peu découvert
    case fair
    case good
    case veryGood
    case exceptional // grandes vives-eaux

    init(coefficient: Int) {
        switch coefficient {
        case 100...:    self = .exceptional
        case 90..<100:  self = .veryGood
        case 75..<90:   self = .good
        case 60..<75:   self = .fair
        default:        self = .modest
        }
    }

    var label: String {
        switch self {
        case .exceptional: return String(localized: "Exceptionnelle")
        case .veryGood:    return String(localized: "Très bonne")
        case .good:        return String(localized: "Bonne")
        case .fair:        return String(localized: "Correcte")
        case .modest:      return String(localized: "Modeste")
        }
    }

    var color: Color {
        switch self {
        case .exceptional: return .mint
        case .veryGood:    return .tideHigh
        case .good:        return .cyan
        case .fair:        return .orange
        case .modest:      return .gray
        }
    }

    static func < (lhs: ForagingQuality, rhs: ForagingQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Luminosité au moment de la basse mer

enum DaylightStatus {
    case day, twilight, night, unknown

    var label: String {
        switch self {
        case .day:      return String(localized: "En journée")
        case .twilight: return String(localized: "Aube / crépuscule")
        case .night:    return String(localized: "De nuit (lampe requise)")
        case .unknown:  return ""
        }
    }

    var icon: String {
        switch self {
        case .day:      return "sun.max.fill"
        case .twilight: return "sun.horizon.fill"
        case .night:    return "moon.stars.fill"
        case .unknown:  return "questionmark"
        }
    }
}

// MARK: - Session de pêche à pied (autour d'une basse mer)

struct ForagingSession: Identifiable {
    let id = UUID()
    let lowTideDate: Date          // heure de la basse mer
    let lowTideHeight: Double      // hauteur d'eau à la BM (m)
    let coefficient: Int           // coefficient de marée associé
    let windowStart: Date?         // début estran découvert (descente)
    let windowEnd: Date?           // fin estran découvert (= retour de l'eau)
    let daylight: DaylightStatus
    let score: Int                 // 0-100 (coefficient + luminosité)

    var quality: ForagingQuality { ForagingQuality(coefficient: coefficient) }

    /// Durée de la fenêtre découverte
    var windowDuration: TimeInterval? {
        guard let s = windowStart, let e = windowEnd else { return nil }
        return max(0, e.timeIntervalSince(s))
    }

    /// Temps disponible APRÈS la basse mer avant le retour de l'eau (sécurité)
    var safetyMarginAfterLow: TimeInterval? {
        guard let e = windowEnd else { return nil }
        return max(0, e.timeIntervalSince(lowTideDate))
    }
}

// MARK: - Espèces (pêche à pied de loisir, façade France)

enum ShellfishHabitat: String {
    case sable = "Sable"
    case vase = "Vase"
    case sableVase = "Sable / vase"
    case roche = "Rocher"
    case gravier = "Gravier"

    var icon: String {
        switch self {
        case .sable, .gravier: return "circle.grid.3x3.fill"
        case .vase, .sableVase: return "drop.fill"
        case .roche:           return "mountain.2.fill"
        }
    }
}

struct ShellfishSpecies: Identifiable {
    let id: String
    let name: String               // nom FR (source)
    let nameEn: String             // nom EN (US)
    let latinName: String          // nom scientifique (universel)
    let group: String              // Bivalve / Gastéropode / Crustacé / Céphalopode / Échinoderme
    let emoji: String              // repli si l'image manque
    let imageName: String?         // asset du catalogue (banque d'images)
    let habitat: ShellfishHabitat
    let minSizeMm: Int?            // taille minimale légale (mm) — indicative
    let bestMonths: [Int]          // 1...12
    let regions: [String]          // pays où l'espèce est pêchée (FR, UK, ES…)
    let tip: String

    /// Nom selon la langue : FR en français, sinon EN (les noms ES/DE/IT ne sont pas
    /// dans la banque → repli sur l'anglais + le nom latin affiché à côté).
    var localizedName: String {
        let lang = Locale.current.language.languageCode?.identifier ?? "fr"
        return lang == "fr" ? name : nameEn
    }

    var minSizeLabel: String {
        guard let mm = minSizeMm else { return "Quota local" }
        return "≥ \(mm) mm"
    }

    /// Espèces en saison pour un mois donné
    static func inSeason(month: Int) -> [ShellfishSpecies] {
        all.filter { $0.bestMonths.contains(month) }
    }

    /// Base curée — tailles & saisons INDICATIVES (la réglementation varie selon
    /// le département / la préfecture maritime ; à vérifier localement).
    static let all: [ShellfishSpecies] = [
        ShellfishSpecies(
            id: "coque", name: "Coque", nameEn: "Common cockle",
            latinName: "Cerastoderma edule", group: "Bivalve", emoji: "🐚",
            imageName: "coque", habitat: .sableVase, minSizeMm: 30,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "BE", "NL", "ES", "PT"],
            tip: "Sous quelques cm de sable humide. Grattez à la griffe là où l'eau perle."
        ),
        ShellfishSpecies(
            id: "coque-glauque", name: "Coque glauque", nameEn: "Lagoon cockle",
            latinName: "Cerastoderma glaucum", group: "Bivalve", emoji: "🐚",
            imageName: "coque-glauque", habitat: .sableVase, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT", "UK"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "palourde-europeenne", name: "Palourde européenne", nameEn: "Grooved carpet shell",
            latinName: "Ruditapes decussatus", group: "Bivalve", emoji: "🐚",
            imageName: "palourde-europeenne", habitat: .sableVase, minSizeMm: 40,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT", "UK", "IE"],
            tip: "Repérez les deux petits trous (siphons), creusez à 10-15 cm."
        ),
        ShellfishSpecies(
            id: "palourde-japonaise", name: "Palourde japonaise", nameEn: "Manila clam",
            latinName: "Ruditapes philippinarum", group: "Bivalve", emoji: "🐚",
            imageName: "palourde-japonaise", habitat: .sableVase, minSizeMm: 40,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT", "US"],
            tip: "Très commune en parcs et estran : siphons en surface, 10 cm de profondeur."
        ),
        ShellfishSpecies(
            id: "palourde-rose", name: "Palourde rose", nameEn: "Banded carpet shell",
            latinName: "Polititapes rhomboides", group: "Bivalve", emoji: "🐚",
            imageName: "palourde-rose", habitat: .sableVase, minSizeMm: 40,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "clovisse", name: "Clovisse", nameEn: "Pullet carpet shell",
            latinName: "Venerupis corrugata", group: "Bivalve", emoji: "🐚",
            imageName: "clovisse", habitat: .sableVase, minSizeMm: 40,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "praire", name: "Praire", nameEn: "Warty venus",
            latinName: "Venus verrucosa", group: "Bivalve", emoji: "🐚",
            imageName: "praire", habitat: .gravier, minSizeMm: 43,
            bestMonths: [1, 2, 11, 12], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sable grossier / gravier du bas estran, sur les très grands coefficients."
        ),
        ShellfishSpecies(
            id: "venus-mactre", name: "Vénus / Mactre", nameEn: "Solid surf clam",
            latinName: "Spisula solida", group: "Bivalve", emoji: "🐚",
            imageName: "venus-mactre", habitat: .sable, minSizeMm: 25,
            bestMonths: [1, 2, 3, 10, 11, 12], regions: ["FR", "UK", "IE", "NL", "BE"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "vernis-(palourde-rouge)", name: "Vernis (palourde rouge)", nameEn: "Smooth callista",
            latinName: "Callista chione", group: "Bivalve", emoji: "🐚",
            imageName: "vernis-palourde-rouge", habitat: .sableVase, minSizeMm: 60,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "telline", name: "Telline", nameEn: "Wedge clam",
            latinName: "Donax trunculus", group: "Bivalve", emoji: "🐚",
            imageName: "telline", habitat: .sable, minSizeMm: 25,
            bestMonths: [5, 6, 7, 8, 9], regions: ["FR", "ES", "PT"],
            tip: "Sable fin en bas de plage, à la « tellinière ». Eau peu profonde."
        ),
        ShellfishSpecies(
            id: "flion-tronque", name: "Flion tronqué", nameEn: "Banded wedge shell",
            latinName: "Donax vittatus", group: "Bivalve", emoji: "🐚",
            imageName: "flion-tronque", habitat: .sable, minSizeMm: nil,
            bestMonths: [5, 6, 7, 8, 9], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "amande-de-mer", name: "Amande de mer", nameEn: "Dog cockle",
            latinName: "Glycymeris glycymeris", group: "Bivalve", emoji: "🐚",
            imageName: "amande-de-mer", habitat: .gravier, minSizeMm: nil,
            bestMonths: [1, 2, 3, 11, 12], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sable grossier et gravier du bas estran, sur les grands coefficients."
        ),
        ShellfishSpecies(
            id: "clam-americain", name: "Clam américain", nameEn: "Hard clam (quahog)",
            latinName: "Mercenaria mercenaria", group: "Bivalve", emoji: "🐚",
            imageName: "clam-americain", habitat: .sableVase, minSizeMm: 43,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["US", "CA", "UK", "FR"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "lavignon", name: "Lavignon", nameEn: "Peppery furrow shell",
            latinName: "Scrobicularia plana", group: "Bivalve", emoji: "🐚",
            imageName: "lavignon", habitat: .vase, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans la vase ferme de l'estran ; cherchez les siphons en surface."
        ),
        ShellfishSpecies(
            id: "petoncle-blanc", name: "Pétoncle blanc", nameEn: "Surf clam",
            latinName: "Spisula spp.", group: "Bivalve", emoji: "🦪",
            imageName: "petoncle-blanc", habitat: .gravier, minSizeMm: 28,
            bestMonths: [10, 11, 12, 1, 2, 3], regions: ["FR", "UK", "IE", "NL", "BE"],
            tip: "Sable grossier et gravier du bas estran, sur les grands coefficients."
        ),
        ShellfishSpecies(
            id: "moule-commune", name: "Moule commune", nameEn: "Blue mussel",
            latinName: "Mytilus edulis", group: "Bivalve", emoji: "🐚",
            imageName: "moule-commune", habitat: .roche, minSizeMm: 40,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "BE", "NL", "US", "CA"],
            tip: "Sur roches et bouchots. Privilégiez les mois en « R » (sept→avril)."
        ),
        ShellfishSpecies(
            id: "moule-mediterraneenne", name: "Moule méditerranéenne", nameEn: "Mediterranean mussel",
            latinName: "Mytilus galloprovincialis", group: "Bivalve", emoji: "🐚",
            imageName: "moule-mediterraneenne", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "huitre-creuse", name: "Huître creuse", nameEn: "Pacific oyster",
            latinName: "Magallana gigas", group: "Bivalve", emoji: "🦪",
            imageName: "huitre-creuse", habitat: .roche, minSizeMm: 50,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "NL", "US", "CA"],
            tip: "Détachez au couteau sur l'estran rocheux. Vérifiez les zones autorisées."
        ),
        ShellfishSpecies(
            id: "huitre-plate", name: "Huître plate", nameEn: "European flat oyster",
            latinName: "Ostrea edulis", group: "Bivalve", emoji: "🦪",
            imageName: "huitre-plate", habitat: .roche, minSizeMm: 60,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Plus rare, sur fonds durs. Taille et zones réglementées."
        ),
        ShellfishSpecies(
            id: "coquille-saint-jacques", name: "Coquille Saint-Jacques", nameEn: "King scallop",
            latinName: "Pecten maximus", group: "Bivalve", emoji: "🦪",
            imageName: "coquille-saint-jacques", habitat: .gravier, minSizeMm: 110,
            bestMonths: [10, 11, 12, 1, 2, 3], regions: ["FR", "UK", "IE", "ES"],
            tip: "Sable grossier et gravier du bas estran, sur les grands coefficients."
        ),
        ShellfishSpecies(
            id: "petoncle-vanneau", name: "Pétoncle / Vanneau", nameEn: "Variegated scallop",
            latinName: "Mimachlamys varia", group: "Bivalve", emoji: "🦪",
            imageName: "petoncle-vanneau", habitat: .gravier, minSizeMm: 40,
            bestMonths: [10, 11, 12, 1, 2, 3], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sable grossier et gravier du bas estran, sur les grands coefficients."
        ),
        ShellfishSpecies(
            id: "couteau", name: "Couteau", nameEn: "Razor clam",
            latinName: "Ensis ensis", group: "Bivalve", emoji: "🐚",
            imageName: "couteau", habitat: .sable, minSizeMm: 100,
            bestMonths: [10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "NL", "BE"],
            tip: "Trou en 8 dans le sable : versez du sel, il remonte. Tirez sans forcer."
        ),
        ShellfishSpecies(
            id: "couteau-silique", name: "Couteau silique", nameEn: "Grooved razor shell",
            latinName: "Solen marginatus", group: "Bivalve", emoji: "🐚",
            imageName: "couteau-silique", habitat: .sable, minSizeMm: 100,
            bestMonths: [10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "bigorneau", name: "Bigorneau", nameEn: "Common periwinkle",
            latinName: "Littorina littorea", group: "Gasteropode", emoji: "🐚",
            imageName: "bigorneau", habitat: .roche, minSizeMm: nil,
            bestMonths: [1, 2, 3, 10, 11, 12], regions: ["FR", "UK", "IE", "BE", "NL", "US", "CA"],
            tip: "Sous les algues et dans les flaques. Ramassage facile, idéal débutants."
        ),
        ShellfishSpecies(
            id: "littorine-obtuse", name: "Littorine obtuse", nameEn: "Flat periwinkle",
            latinName: "Littorina obtusata", group: "Gasteropode", emoji: "🐚",
            imageName: "littorine-obtuse", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "troque-gibbule", name: "Troque / Gibbule", nameEn: "Toothed topshell",
            latinName: "Phorcus lineatus", group: "Gasteropode", emoji: "🐚",
            imageName: "troque-gibbule", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "bulot-buccin", name: "Bulot / Buccin", nameEn: "Common whelk",
            latinName: "Buccinum undatum", group: "Gasteropode", emoji: "🐚",
            imageName: "bulot-buccin", habitat: .sableVase, minSizeMm: 45,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "BE", "NL", "US", "CA"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "nasse-reticulee", name: "Nasse réticulée", nameEn: "Netted dog whelk",
            latinName: "Tritia reticulata", group: "Gasteropode", emoji: "🐚",
            imageName: "nasse-reticulee", habitat: .sableVase, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "pourpre", name: "Pourpre", nameEn: "Dog whelk",
            latinName: "Nucella lapillus", group: "Gasteropode", emoji: "🐚",
            imageName: "pourpre", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "US", "CA"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "murex-rocher-epineux", name: "Murex / Rocher épineux", nameEn: "Banded dye-murex",
            latinName: "Hexaplex trunculus", group: "Gasteropode", emoji: "🐚",
            imageName: "murex-rocher-epineux", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "crepidule", name: "Crépidule", nameEn: "Common slipper shell",
            latinName: "Crepidula fornicata", group: "Gasteropode", emoji: "🐚",
            imageName: "crepidule", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "NL", "US"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "ormeau", name: "Ormeau", nameEn: "Green ormer (abalone)",
            latinName: "Haliotis tuberculata", group: "Gasteropode", emoji: "🐚",
            imageName: "ormeau", habitat: .roche, minSizeMm: 90,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "ES", "PT"],
            tip: "Sur roche, réglementation stricte (taille, période, quota). Détachez au crochet."
        ),
        ShellfishSpecies(
            id: "patelle-bernique", name: "Patelle / Bernique", nameEn: "Common limpet",
            latinName: "Patella vulgata", group: "Gasteropode", emoji: "🐚",
            imageName: "patelle-bernique", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "patelle-commune", name: "Patelle commune", nameEn: "Black-footed limpet",
            latinName: "Patella depressa", group: "Gasteropode", emoji: "🐚",
            imageName: "patelle-commune", habitat: .roche, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "crabe-vert", name: "Crabe vert", nameEn: "European green crab",
            latinName: "Carcinus maenas", group: "Crustace", emoji: "🐚",
            imageName: "crabe-vert", habitat: .roche, minSizeMm: nil,
            bestMonths: [6, 7, 8, 9, 10, 11], regions: ["FR", "UK", "IE", "BE", "NL", "US", "CA"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "etrille", name: "Étrille", nameEn: "Velvet swimming crab",
            latinName: "Necora puber", group: "Crustace", emoji: "🐚",
            imageName: "etrille", habitat: .roche, minSizeMm: 65,
            bestMonths: [1, 9, 10, 11, 12], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sous les pierres du bas de l'estran. Reposez les pierres après !"
        ),
        ShellfishSpecies(
            id: "tourteau-dormeur", name: "Tourteau / Dormeur", nameEn: "Brown (edible) crab",
            latinName: "Cancer pagurus", group: "Crustace", emoji: "🐚",
            imageName: "tourteau-dormeur", habitat: .roche, minSizeMm: 150,
            bestMonths: [6, 7, 8, 9, 10], regions: ["FR", "UK", "IE", "ES", "NO"],
            tip: "Dans les anfractuosités rocheuses du bas estran, à marée très basse."
        ),
        ShellfishSpecies(
            id: "araignee-de-mer", name: "Araignée de mer", nameEn: "Spinous spider crab",
            latinName: "Maja brachydactyla", group: "Crustace", emoji: "🐚",
            imageName: "araignee-de-mer", habitat: .roche, minSizeMm: 120,
            bestMonths: [4, 5, 6, 7, 8], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Au printemps sur fonds rocheux et herbiers. À la main à marée basse."
        ),
        ShellfishSpecies(
            id: "homard-europeen", name: "Homard européen", nameEn: "European lobster",
            latinName: "Homarus gammarus", group: "Crustace", emoji: "🦞",
            imageName: "homard-europeen", habitat: .roche, minSizeMm: 87,
            bestMonths: [6, 7, 8, 9, 10, 11], regions: ["FR", "UK", "IE", "ES", "NO"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "langouste-rouge", name: "Langouste rouge", nameEn: "European spiny lobster",
            latinName: "Palinurus elephas", group: "Crustace", emoji: "🦞",
            imageName: "langouste-rouge", habitat: .roche, minSizeMm: 110,
            bestMonths: [6, 7, 8, 9, 10], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "crevette-grise", name: "Crevette grise", nameEn: "Brown shrimp",
            latinName: "Crangon crangon", group: "Crustace", emoji: "🦐",
            imageName: "crevette-grise", habitat: .sable, minSizeMm: 30,
            bestMonths: [5, 6, 7, 8, 9, 10], regions: ["FR", "UK", "IE", "BE", "NL"],
            tip: "Au haveneau dans les herbiers et le long des roches, marée descendante."
        ),
        ShellfishSpecies(
            id: "bouquet-(crevette-rose)", name: "Bouquet (crevette rose)", nameEn: "Common prawn",
            latinName: "Palaemon serratus", group: "Crustace", emoji: "🦐",
            imageName: "bouquet-crevette-rose", habitat: .sable, minSizeMm: 50,
            bestMonths: [5, 6, 7, 8, 9, 10], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "pouce-pied", name: "Pouce-pied", nameEn: "Goose barnacle",
            latinName: "Pollicipes pollicipes", group: "Crustace", emoji: "🐚",
            imageName: "pouce-pied", habitat: .roche, minSizeMm: nil,
            bestMonths: [10, 11, 12, 1, 2, 3], regions: ["FR", "ES", "PT"],
            tip: "Sur les roches battues exposées : prudence, terrain dangereux."
        ),
        ShellfishSpecies(
            id: "bernard-l-ermite", name: "Bernard-l'ermite", nameEn: "Common hermit crab",
            latinName: "Pagurus bernhardus", group: "Crustace", emoji: "🐚",
            imageName: "bernard-l-ermite", habitat: .roche, minSizeMm: nil,
            bestMonths: [1, 2, 3, 9, 10, 11, 12], regions: ["FR", "UK", "IE", "US", "CA"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "oursin-violet", name: "Oursin violet", nameEn: "Purple sea urchin",
            latinName: "Paracentrotus lividus", group: "Echinoderme", emoji: "🐚",
            imageName: "oursin-violet", habitat: .roche, minSizeMm: 40,
            bestMonths: [11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT", "IE"],
            tip: "Sur roche, à la main gantée. Saison hivernale, fermé l'été en Méditerranée."
        ),
        ShellfishSpecies(
            id: "oursin-(variete-claire)", name: "Oursin (variété claire)", nameEn: "Violet sea urchin",
            latinName: "Sphaerechinus granularis", group: "Echinoderme", emoji: "🐚",
            imageName: "oursin-variete-claire", habitat: .roche, minSizeMm: nil,
            bestMonths: [11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "poulpe", name: "Poulpe", nameEn: "Common octopus",
            latinName: "Octopus vulgaris", group: "Cephalopode", emoji: "🐙",
            imageName: "poulpe", habitat: .roche, minSizeMm: nil,
            bestMonths: [10, 11, 12, 1, 2, 3], regions: ["FR", "ES", "PT", "UK"],
            tip: "Dans les trous de roche du bas estran. Souvent trahi par un tas de coquilles."
        ),
        ShellfishSpecies(
            id: "seiche", name: "Seiche", nameEn: "Common cuttlefish",
            latinName: "Sepia officinalis", group: "Cephalopode", emoji: "🦑",
            imageName: "seiche", habitat: .sable, minSizeMm: nil,
            bestMonths: [3, 4, 5, 6], regions: ["FR", "UK", "ES", "PT"],
            tip: "Au printemps près des herbiers. Os de seiche échoués = signe de présence."
        ),
        ShellfishSpecies(
            id: "coque-epineuse", name: "Coque épineuse", nameEn: "Prickly cockle",
            latinName: "Acanthocardia echinata", group: "Bivalve", emoji: "🐚",
            imageName: "coque-epineuse", habitat: .sable, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "bucarde", name: "Bucarde", nameEn: "Tuberculate cockle",
            latinName: "Acanthocardia tuberculata", group: "Bivalve", emoji: "🐚",
            imageName: "bucarde", habitat: .sableVase, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        ),
        ShellfishSpecies(
            id: "vanneau", name: "Vanneau", nameEn: "Queen scallop",
            latinName: "Aequipecten opercularis", group: "Bivalve", emoji: "🦪",
            imageName: "vanneau", habitat: .gravier, minSizeMm: nil,
            bestMonths: [10, 11, 12, 1, 2, 3], regions: ["FR", "UK", "IE", "ES"],
            tip: "Sable grossier et gravier du bas estran, sur les grands coefficients."
        ),
        ShellfishSpecies(
            id: "surf-clam-atlantique", name: "Surf clam atlantique", nameEn: "Atlantic surf clam",
            latinName: "Spisula solidissima", group: "Bivalve", emoji: "🐚",
            imageName: "surf-clam-atlantique", habitat: .sable, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["US", "CA"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "donace", name: "Donace", nameEn: "Variegated wedge shell",
            latinName: "Donax variegatus", group: "Bivalve", emoji: "🐚",
            imageName: "donace", habitat: .sable, minSizeMm: 25,
            bestMonths: [5, 6, 7, 8, 9], regions: ["FR", "ES", "PT"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "mye-des-sables", name: "Mye des sables", nameEn: "Soft-shell clam (steamer)",
            latinName: "Mya arenaria", group: "Bivalve", emoji: "🐚",
            imageName: "mye-des-sables", habitat: .sable, minSizeMm: nil,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "US", "CA"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "couteau-gaine", name: "Couteau gaine", nameEn: "Pod razor",
            latinName: "Ensis siliqua", group: "Bivalve", emoji: "🐚",
            imageName: "couteau-gaine", habitat: .sable, minSizeMm: 100,
            bestMonths: [10, 11, 12, 1, 2, 3, 4], regions: ["FR", "UK", "IE", "ES", "PT"],
            tip: "Dans le sable du bas estran à marée basse ; repérez les indices en surface."
        ),
        ShellfishSpecies(
            id: "huitre-portugaise", name: "Huître portugaise", nameEn: "Portuguese oyster",
            latinName: "Crassostrea angulata", group: "Bivalve", emoji: "🦪",
            imageName: "huitre-portugaise", habitat: .roche, minSizeMm: 50,
            bestMonths: [9, 10, 11, 12, 1, 2, 3, 4], regions: ["FR", "ES", "PT"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "homard-americain", name: "Homard américain", nameEn: "American lobster",
            latinName: "Homarus americanus", group: "Crustace", emoji: "🦞",
            imageName: "homard-americain", habitat: .roche, minSizeMm: nil,
            bestMonths: [6, 7, 8, 9, 10, 11], regions: ["US", "CA"],
            tip: "Sous les pierres et dans les anfractuosités du bas estran ; reposez les pierres."
        ),
        ShellfishSpecies(
            id: "crabe-bleu", name: "Crabe bleu", nameEn: "Blue crab",
            latinName: "Callinectes sapidus", group: "Crustace", emoji: "🐚",
            imageName: "crabe-bleu", habitat: .sableVase, minSizeMm: nil,
            bestMonths: [6, 7, 8, 9, 10], regions: ["US", "FR", "ES", "PT"],
            tip: "Dans le sable vaseux ; grattez là où l'eau perle, à quelques centimètres."
        )
    ]
}

// MARK: - Localisation des espèces (façade France)

/// Type de côte déduit des coordonnées du port. Sert à n'afficher que les espèces
/// réellement présentes localement — ex. pas de tourteau (roche) dans le Bassin
/// d'Arcachon, qui est sableux/vaseux.
enum CoastType {
    case basinArcachon      // sable / vase — pas de roche
    case sandyAtlanticSW    // côte landaise / aquitaine, sableuse
    case rockyAtlantic      // Bretagne / Vendée / Charente — estran rocheux + sable
    case channelNorth       // Manche — Normandie / Hauts-de-France
    case mediterranean      // micro-marée, pêche à pied limitée
    case generic            // hors France métropolitaine — pas de classification fine

    /// Habitats réellement praticables sur ce type de côte.
    var habitats: Set<ShellfishHabitat> {
        switch self {
        case .basinArcachon:   return [.sable, .vase, .sableVase]
        case .sandyAtlanticSW: return [.sable, .sableVase]
        case .rockyAtlantic:   return [.sable, .vase, .sableVase, .roche, .gravier]
        case .channelNorth:    return [.sable, .vase, .sableVase, .roche, .gravier]
        case .mediterranean:   return [.sable, .sableVase]
        case .generic:         return [.sable, .vase, .sableVase, .roche, .gravier] // tous
        }
    }

    /// Libellé court de la zone (affiché dans l'en-tête « Espèces »).
    var localLabel: String {
        switch self {
        case .basinArcachon:   return "Bassin d'Arcachon"
        case .sandyAtlanticSW: return "Côte sableuse"
        case .rockyAtlantic:   return "Côte atlantique"
        case .channelNorth:    return "Manche"
        case .mediterranean:   return "Méditerranée"
        case .generic:         return String(localized: "Littoral")
        }
    }

    /// Classifie une côte à partir de coordonnées (grossier mais utile).
    /// ⚠️ La classification fine n'a de sens qu'en FRANCE MÉTROPOLITAINE (les 58 espèces
    /// du catalogue sont façade France). Hors de cette boîte englobante → `.generic`,
    /// sinon un port de Boston (lat < 42.8) était étiqueté « Méditerranée ».
    static func at(latitude lat: Double, longitude lon: Double) -> CoastType {
        // Boîte englobante France métropolitaine + Corse (sinon : zone non classée).
        let inMetropolitanFrance = (41.0...51.6).contains(lat) && (-5.6...9.8).contains(lon)
        guard inMetropolitanFrance else { return .generic }

        // Bassin d'Arcachon (plan d'eau fermé sableux/vaseux)
        if (44.40...44.85).contains(lat) && (-1.62...(-1.00)).contains(lon) { return .basinArcachon }
        // Méditerranée (sud-est) + Corse
        if lat < 43.7 && lon > 3.0 { return .mediterranean }
        if lat < 42.8 { return .mediterranean }
        // Manche (Normandie / Hauts-de-France)
        if lat > 49.0 { return .channelNorth }
        // Côte sableuse SW (Landes / Aquitaine, au sud du Bassin)
        if lat < 44.40 && lon < -1.00 { return .sandyAtlanticSW }
        // Défaut : façade atlantique (Bretagne / Vendée / Charente) — rocheuse + sableuse
        return .rockyAtlantic
    }
}

extension ShellfishSpecies {
    /// Espèces en saison ET cohérentes avec la côte locale (habitat praticable).
    /// Repli sur `inSeason` si aucune espèce ne matche (zone non classée finement).
    static func localInSeason(month: Int, latitude: Double, longitude: Double) -> (species: [ShellfishSpecies], coast: CoastType) {
        let coast = CoastType.at(latitude: latitude, longitude: longitude)
        let local = all.filter { $0.bestMonths.contains(month) && coast.habitats.contains($0.habitat) }
        return (local.isEmpty ? inSeason(month: month) : local, coast)
    }
}

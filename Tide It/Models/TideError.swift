//
//  TideError.swift
//  Tide It
//
//  Erreurs structurées pour l'application
//

import Foundation

enum TideError: LocalizedError {
    case networkUnavailable
    case serverError(Int)
    case invalidData
    case portNotFound
    case parsingFailed
    case cacheExpired
    case unknown(Error)

    /// LOCALISÉ : ces messages sont les SEULS textes que voit un utilisateur quand l'app n'a rien
    /// à afficher. En français brut, 11 langues sur 12 tombaient sur un écran d'erreur illisible.
    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return String(localized: "Connexion internet indisponible")
        case .serverError(let code):
            return String(localized: "Erreur serveur (\(code))")
        case .invalidData:
            return String(localized: "Données invalides reçues")
        case .portNotFound:
            return String(localized: "Port introuvable")
        case .parsingFailed:
            return String(localized: "Impossible de lire les données")
        case .cacheExpired:
            return String(localized: "Données en cache expirées")
        case .unknown(let error):
            return error.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .networkUnavailable:
            return String(localized: "Vérifiez votre connexion Wi-Fi ou données mobiles.")
        case .serverError:
            return String(localized: "Réessayez dans quelques instants.")
        case .invalidData, .parsingFailed:
            return String(localized: "Le format des données a peut-être changé. Mettez à jour l'application.")
        case .portNotFound:
            return String(localized: "Sélectionnez un autre port.")
        case .cacheExpired:
            return String(localized: "Actualisez les données.")
        case .unknown:
            return String(localized: "Réessayez ou contactez le support.")
        }
    }

    var icon: String {
        switch self {
        case .networkUnavailable: return "wifi.slash"
        case .serverError: return "exclamationmark.icloud"
        case .invalidData, .parsingFailed: return "doc.questionmark"
        case .portNotFound: return "mappin.slash"
        case .cacheExpired: return "clock.arrow.circlepath"
        case .unknown: return "exclamationmark.triangle"
        }
    }
}

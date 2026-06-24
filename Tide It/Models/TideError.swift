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

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Connexion internet indisponible"
        case .serverError(let code):
            return "Erreur serveur (\(code))"
        case .invalidData:
            return "Données invalides reçues"
        case .portNotFound:
            return "Port introuvable"
        case .parsingFailed:
            return "Impossible de lire les données"
        case .cacheExpired:
            return "Données en cache expirées"
        case .unknown(let error):
            return error.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .networkUnavailable:
            return "Vérifiez votre connexion Wi-Fi ou données mobiles."
        case .serverError:
            return "Réessayez dans quelques instants."
        case .invalidData, .parsingFailed:
            return "Le format des données a peut-être changé. Mettez à jour l'application."
        case .portNotFound:
            return "Sélectionnez un autre port."
        case .cacheExpired:
            return "Actualisez les données."
        case .unknown:
            return "Réessayez ou contactez le support."
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

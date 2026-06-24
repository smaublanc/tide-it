//
//  WatchDataManager.swift
//  Tide Watch Watch App
//
//  Reçoit les données de marée depuis l'iPhone via WatchConnectivity
//  et les stocke dans UserDefaults local pour ContentView
//

import Foundation
import Combine
import WatchConnectivity
import WidgetKit
import os.log

private let watchLogger = Logger(subsystem: "seb.Tide-It.watchkitapp", category: "WatchData")

@MainActor
final class WatchDataManager: NSObject, ObservableObject {

    static let shared = WatchDataManager()

    @Published var tideData: WidgetSharedData?
    /// Favoris (clé séparée) pour le carrousel — décodage ISOLÉ de tideData (ne peut pas le casser).
    @Published var favorites: [WidgetSharedData] = []

    /// Clé UserDefaults dans l'App Group (partagée avec le widget watchOS)
    private static let localKey = "watch_tide_data"
    private static let sharedDefaults = UserDefaults(suiteName: WidgetSharedKeys.appGroupId)

    private override init() {
        super.init()
        // Charger les données sauvegardées localement
        loadLocal()
        // Activer WatchConnectivity
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Lecture locale

    func loadLocal() {
        let defaults = Self.sharedDefaults ?? UserDefaults.standard
        guard let encoded = defaults.data(forKey: Self.localKey),
              let decoded = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded),
              !decoded.portName.isEmpty
        else {
            tideData = nil
            return
        }
        tideData = decoded
    }

    // MARK: - Sauvegarde locale

    private func saveLocal(_ data: WidgetSharedData) {
        // Système d'unités reçu de l'iPhone (les App Groups ne se synchronisent pas
        // entre appareils) → écrit localement pour que SharedUnitFormatter affiche
        // les bonnes unités dans l'app ET dans la complication (même App Group).
        if let unit = data.measureSystemRaw {
            Self.sharedDefaults?.set(unit, forKey: "measureSystem")
            UserDefaults.standard.set(unit, forKey: "measureSystem")
        }
        if let windUnit = data.windSpeedUnitRaw {
            Self.sharedDefaults?.set(windUnit, forKey: "windSpeedUnit")
            UserDefaults.standard.set(windUnit, forKey: "windSpeedUnit")
        }
        if let encoded = try? JSONEncoder().encode(data) {
            // Écrire dans le shared container ET dans standard pour garantir l'accès
            if let shared = Self.sharedDefaults {
                shared.set(encoded, forKey: Self.localKey)
                watchLogger.info("WatchData: sauvegardé dans App Group (\(encoded.count) bytes)")
            } else {
                watchLogger.error("WatchData: App Group indisponible, fallback UserDefaults.standard")
            }
            UserDefaults.standard.set(encoded, forKey: Self.localKey)
        }
        tideData = data
        // Rafraîchir la complication watchOS (la seule de ce target)
        WidgetCenter.shared.reloadTimelines(ofKind: "TideWatchComplication")
    }

    // MARK: - Traitement des données reçues

    nonisolated private func processReceivedContext(_ context: [String: Any]) {
        let encoded = context["tideData"] as? Data
        let favEncoded = context["favoritesData"] as? Data

        Task { @MainActor in
            // Marée : chemin INCHANGÉ (struct WidgetSharedData intact) → ne peut pas être cassé par
            // les favoris. On traite chaque clé indépendamment.
            if let encoded,
               let decoded = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded),
               !decoded.portName.isEmpty {
                watchLogger.info("WatchData: données reçues → \(decoded.portName)")
                self.saveLocal(decoded)
            } else if encoded != nil {
                watchLogger.error("WatchData: impossible de décoder les données reçues")
            }
            // Favoris : décodage ISOLÉ (try?) → un favori malformé n'affecte JAMAIS la marée.
            if let favEncoded,
               let favs = try? JSONDecoder().decode([WidgetSharedData].self, from: favEncoded) {
                self.favorites = favs
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchDataManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let activationError = error
        let pendingContext = session.receivedApplicationContext

        Task { @MainActor in
            if let err = activationError {
                watchLogger.error("WatchConnectivity: activation échouée → \(err.localizedDescription)")
            } else {
                watchLogger.info("WatchConnectivity: activation réussie")
            }
        }

        if activationError == nil, !pendingContext.isEmpty {
            processReceivedContext(pendingContext)
        }
    }

    /// Appelé quand l'iPhone envoie un nouveau applicationContext
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        processReceivedContext(applicationContext)
    }

    /// Appelé quand l'iPhone envoie des userInfo
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        processReceivedContext(userInfo)
    }
}

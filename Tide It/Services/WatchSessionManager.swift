//
//  WatchSessionManager.swift
//  Tide It
//
//  Gère l'envoi des données de marée vers l'Apple Watch via WatchConnectivity
//

import Foundation
import WatchConnectivity
import os.log

// @MainActor : tout l'état mutable (throttles + pendingData) n'est touché QUE sur le main actor.
// Les callbacks WCSessionDelegate arrivent sur une file de fond → `nonisolated` + saut explicite
// sur le main (cf. ci-dessous). Évite la course de données relevée à l'audit (sendTideData tourne
// sur le main via TideService, tandis que activationDidCompleteWith écrivait pendingData hors-main).
@MainActor
final class WatchSessionManager: NSObject, WCSessionDelegate {

    static let shared = WatchSessionManager()

    /// Throttle : n'envoyer qu'une fois toutes les 60 s pour le même port
    private var lastSendDate: Date = .distantPast
    private var lastPortName: String = ""
    private let minimumSendInterval: TimeInterval = 60

    /// Dernière donnée reçue AVANT activation de la session (sinon, au lancement à froid,
    /// le tout premier envoi était silencieusement jeté et jamais retenté → la Watch
    /// restait sur d'anciennes données jusqu'au prochain changement de port).
    private var pendingData: WidgetSharedData?
    /// Favoris (clé séparée) en attente avant activation, renvoyés avec `pendingData`.
    private var pendingFavorites: Data?

    /// Dernier push complication (budget watchOS ~50/jour) → throttle séparé.
    private var lastComplicationPush: Date = .distantPast

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        appLogger.info("WatchConnectivity: session activée")
    }

    // MARK: - Envoi des données vers la Watch

    /// Envoie les données de marée à la Watch via applicationContext (dernière valeur gagne).
    /// Throttle intégré : ignore les appels trop fréquents pour le même port.
    func sendTideData(_ data: WidgetSharedData, favoritesData: Data? = nil) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default

        guard session.activationState == .activated else {
            pendingData = data; pendingFavorites = favoritesData   // différé : flush à l'activation
            appLogger.info("WatchConnectivity: session pas encore activée, envoi différé")
            return
        }

        #if os(iOS)
        guard session.isPaired else {
            appLogger.info("WatchConnectivity: pas de Watch appairée")
            return
        }
        // App Watch non installée → updateApplicationContext lèverait à CHAQUE envoi
        // (« Watch app is not installed »), polluant les logs. On sort proprement.
        // (isWatchAppInstalled peut être faux juste après activation → le retry passe
        // par pendingData/activationDidCompleteWith.)
        guard session.isWatchAppInstalled else {
            appLogger.info("WatchConnectivity: app Watch non installée, envoi ignoré")
            return
        }
        #endif

        // Throttle : skip si même port et intervalle trop court. Clé = portId (stable) plutôt que
        // le nom, sinon deux ports homonymes battaient le throttle 60 s.
        let now = Date()
        let portKey = data.portId ?? data.portName
        let portChanged = portKey != lastPortName
        if !portChanged && now.timeIntervalSince(lastSendDate) < minimumSendInterval {
            return
        }

        guard let encoded = try? JSONEncoder().encode(data) else {
            appLogger.error("WatchConnectivity: erreur encodage données")
            return
        }

        do {
            // Favoris (carrousel Watch) sous une clé SÉPARÉE → le décodage de `tideData` n'est
            // jamais affecté par eux (un favori malformé ne peut plus figer la Watch).
            var ctx: [String: Any] = ["tideData": encoded, "timestamp": now.timeIntervalSince1970]
            if let favoritesData { ctx["favoritesData"] = favoritesData }
            try session.updateApplicationContext(ctx)
            lastSendDate = now
            lastPortName = portKey   // mémorise la clé portId (cf. throttle ci-dessus)
            appLogger.info("WatchConnectivity: données envoyées → \(data.portName)")

            // applicationContext ne réveille PAS une complication suspendue → données
            // figées au poignet tant que l'app Watch n'est pas ouverte. On pousse donc
            // aussi via transferCurrentComplicationUserInfo (budget garanti ~50/j), au
            // changement de port ou au plus une fois / 20 min pour rester dans le budget.
            if session.isComplicationEnabled,
               portChanged || now.timeIntervalSince(lastComplicationPush) > 20 * 60 {
                session.transferCurrentComplicationUserInfo([
                    "tideData": encoded,
                    "timestamp": now.timeIntervalSince1970
                ])
                lastComplicationPush = now
            }
        } catch {
            appLogger.error("WatchConnectivity: erreur envoi → \(error.localizedDescription)")
        }
    }

    // MARK: - WCSessionDelegate (appelés sur une FILE DE FOND → nonisolated + saut sur le main)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let errDesc = error?.localizedDescription
        let isActivated = activationState == .activated
        let stateRaw = activationState.rawValue
        Task { @MainActor in
            if let errDesc {
                appLogger.error("WatchConnectivity: activation échouée → \(errDesc)")
            } else {
                appLogger.info("WatchConnectivity: activation réussie (\(stateRaw))")
                // Flusher l'envoi mis en attente avant l'activation (sur le main actor).
                if isActivated, let pending = self.pendingData {
                    let pendingFavs = self.pendingFavorites
                    self.pendingData = nil
                    self.pendingFavorites = nil
                    self.sendTideData(pending, favoritesData: pendingFavs)
                }
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        appLogger.info("WatchConnectivity: session inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        appLogger.info("WatchConnectivity: session désactivée, réactivation...")
        WCSession.default.activate()
    }
    #endif
}

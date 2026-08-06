//
//  SourceBlocklistService.swift
//  Tide It
//
//  Liste de RETRAIT distante, lue sur le site de l'app.
//
//  Pourquoi ce fichier existe : Tide It affiche des balises tierces (et bientôt des webcams)
//  sans accord préalable — la mesure d'un anémomètre est un fait, pas une œuvre. La contrepartie
//  de ce choix, c'est une promesse écrite dans chaque courrier envoyé aux exploitants :
//  « si vous préférez ne pas y figurer, un mot suffit et je vous retire IMMÉDIATEMENT ».
//
//  Sans cette liste, « immédiatement » voudrait dire « après une mise à jour, une archive, une
//  revue Apple et le déploiement » — deux semaines au mieux. La promesse serait fausse, et un
//  courrier qui promet faux vaut moins que pas de courrier du tout.
//
//  Un identifiant ajouté à docs/blocklist.json et la source disparaît de tous les téléphones au
//  prochain lancement. Rien à compiler, rien à soumettre.
//

import Foundation
import Combine
import os.log

@MainActor
final class SourceBlocklistService: ObservableObject {
    static let shared = SourceBlocklistService()

    private static let url = URL(string: "https://smaublanc.github.io/tide-it/blocklist.json")!
    private static let cacheKey = "sourceBlocklist_v1"
    private static let fetchedAtKey = "sourceBlocklistFetchedAt_v1"
    /// Une liste de retrait n'a d'intérêt que si elle arrive vite. 6 h = au moins un passage par
    /// jour pour un usage normal, sans peser (un fichier de quelques centaines d'octets).
    private static let ttl: TimeInterval = 6 * 3600

    /// Republié quand la liste change → les consommateurs se reconstruisent.
    @Published private(set) var blockedStationIDs: Set<String> = []
    @Published private(set) var blockedSources: Set<String> = []
    @Published private(set) var blockedWebcamIDs: Set<String> = []

    private init() {
        // AMORÇAGE SYNCHRONE depuis le cache. Un chargement asynchrone laisserait la première
        // reconstruction de `allStations` afficher une balise retirée : elle apparaîtrait puis
        // disparaîtrait sous les yeux de l'utilisateur, et surtout elle serait bel et bien
        // affichée à quelqu'un qui a demandé son retrait. Même leçon que le droit premium
        // (`paidEntitlementUntil_v1`) : ce qui décide de ce qu'on montre doit être lu AVANT
        // le premier rendu.
        applyCached()
    }

    // MARK: - Lecture

    /// La source est-elle retirée ? Un seul point de décision pour toute l'app.
    func isBlocked(stationID: String, source: String) -> Bool {
        blockedSources.contains(source) || blockedStationIDs.contains(stationID)
    }

    func isBlocked(webcamID: String) -> Bool { blockedWebcamIDs.contains(webcamID) }

    // MARK: - Rafraîchissement

    func refreshIfNeeded(force: Bool = false) async {
        let last = UserDefaults.standard.double(forKey: Self.fetchedAtKey)
        if !force, last > 0, Date().timeIntervalSince1970 - last < Self.ttl { return }

        guard let payload = await Self.fetch() else { return }   // réseau muet → on garde le cache
        UserDefaults.standard.set(payload, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.fetchedAtKey)
        applyCached()
        appLogger.info("[Blocklist] \(self.blockedStationIDs.count) balises, \(self.blockedSources.count) sources, \(self.blockedWebcamIDs.count) webcams retirées")
    }

    private func applyCached() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.cacheKey) else { return }
        let stations = Set((dict["stations"] as? [String]) ?? [])
        let sources  = Set((dict["sources"]  as? [String]) ?? [])
        let webcams  = Set((dict["webcams"]  as? [String]) ?? [])
        // Ne republier que sur un vrai changement : @Published → rebuild de l'agrégateur.
        if stations != blockedStationIDs { blockedStationIDs = stations }
        if sources  != blockedSources    { blockedSources    = sources }
        if webcams  != blockedWebcamIDs  { blockedWebcamIDs  = webcams }
    }

    // MARK: - Réseau (nonisolated : hors du main thread)

    private nonisolated static func fetch() async -> [String: Any]? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        // Un 304 sur le cache HTTP renverrait la copie locale sans nous dire qu'elle a changé.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession(configuration: config).data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // On ne garde QUE les trois tableaux : le fichier porte aussi des clés « _lisezmoi »
            // de documentation, inutiles à embarquer dans les préférences.
            return [
                "stations": (root["stations"] as? [String]) ?? [],
                "sources":  (root["sources"]  as? [String]) ?? [],
                "webcams":  (root["webcams"]  as? [String]) ?? []
            ]
        } catch {
            return nil   // hors ligne ou site injoignable → la dernière liste connue reste en vigueur
        }
    }
}

//
//  WatchSourceBlocklist.swift
//  Tide Watch Watch App
//
//  Liste de RETRAIT distante, côté Watch. Jumelle minimale de `SourceBlocklistService` (iOS).
//
//  POURQUOI ELLE EXISTE
//  Chaque courrier envoyé aux exploitants de balises porte cette phrase : « si vous préférez ne
//  pas y figurer, un mot suffit et je vous retire IMMÉDIATEMENT ». L'iPhone tenait la promesse
//  (`WindStationAggregator.rebuildDedup` filtre par `isBlocked`) — la Watch, elle, interrogeait
//  winds.mobi en direct et n'appliquait AUCUN filtre. Un exploitant qui disait non disparaissait
//  du téléphone et restait sur la montre : la promesse était rompue sur une surface, ce qui est
//  pire que de ne pas l'avoir faite.
//
//  Elle ne duplique PAS le service iOS : la Watch est une cible FS-synced, séparée, qui ne
//  partage pas les fichiers de `Tide It/Services`. Le contrat commun est le FICHIER DISTANT —
//  même URL, mêmes clés. Un identifiant ajouté à `docs/blocklist.json` retire la source des
//  deux appareils au prochain lancement, sans rien recompiler.
//
//  Volontairement réduite : la Watch n'affiche ni webcam ni carte, donc seules `stations` et
//  `sources` sont lues. Pas de `@Published` — le seul consommateur (`WatchWindService`) la lit
//  au moment de filtrer, il n'a pas besoin d'être notifié.
//

import Foundation

actor WatchSourceBlocklist {
    static let shared = WatchSourceBlocklist()

    private static let url = URL(string: "https://smaublanc.github.io/tide-it/blocklist.json")!
    private static let cacheKey = "watchSourceBlocklist_v1"
    private static let fetchedAtKey = "watchSourceBlocklistFetchedAt_v1"
    /// 6 h, comme sur iOS : au moins un passage par jour en usage normal, pour quelques
    /// centaines d'octets. Une liste de retrait n'a d'intérêt que si elle arrive vite.
    private static let ttl: TimeInterval = 6 * 3600

    private var blockedStationIDs: Set<String> = []
    private var blockedSources: Set<String> = []

    private init() {
        // AMORÇAGE SYNCHRONE depuis le cache, même raison que sur iOS : ce qui décide de ce
        // qu'on MONTRE doit être lu avant le premier affichage. Sinon une balise retirée
        // apparaît puis disparaît — et elle aura bel et bien été montrée à quelqu'un qui
        // avait demandé son retrait.
        //
        // On AFFECTE les propriétés au lieu d'appeler une méthode : l'`init` d'un acteur est
        // nonisolated, donc il ne peut pas appeler une méthode isolée (avertissement
        // aujourd'hui, ERREUR en Swift 6). D'où `readCache()`, `nonisolated` et sans effet
        // de bord. Quatrième variante de ce piège dans ce dépôt — cf. CLAUDE.md.
        let cached = Self.readCache()
        blockedStationIDs = cached.stations
        blockedSources = cached.sources
    }

    /// La source est-elle retirée ? `source` vaut `windsMobi` côté Watch (seul fournisseur
    /// interrogé en direct), ce qui permet de couper le fournisseur ENTIER depuis le fichier.
    func isBlocked(stationID: String, source: String) -> Bool {
        blockedSources.contains(source) || blockedStationIDs.contains(stationID)
    }

    /// Les deux ensembles d'un coup, pour filtrer une liste SANS un `await` par balise.
    /// `WatchWindService` trie une trentaine de candidates dans un `compactMap` synchrone :
    /// un acteur y imposerait une suspension par élément.
    func snapshot() -> (stations: Set<String>, sources: Set<String>) {
        (blockedStationIDs, blockedSources)
    }

    /// Rafraîchit au plus une fois par TTL. Réseau muet → la dernière liste connue reste en
    /// vigueur : hors ligne, on ne réaffiche JAMAIS une source retirée.
    func refreshIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: Self.fetchedAtKey)
        if last > 0, Date().timeIntervalSince1970 - last < Self.ttl { return }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        // Un 304 sur le cache HTTP renverrait la copie locale sans dire qu'elle a changé.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession(configuration: config).data(from: Self.url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Seuls les deux tableaux utiles : le fichier porte aussi des clés « _lisezmoi ».
        let payload: [String: Any] = [
            "stations": (root["stations"] as? [String]) ?? [],
            "sources":  (root["sources"]  as? [String]) ?? []
        ]
        UserDefaults.standard.set(payload, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.fetchedAtKey)
        let cached = Self.readCache()
        blockedStationIDs = cached.stations
        blockedSources = cached.sources
    }

    /// `nonisolated` : lue aussi depuis l'`init`, qui ne l'est pas. Sans effet de bord — elle
    /// RENVOIE les ensembles au lieu de les affecter, ce qui est précisément ce qui la rend
    /// appelable des deux côtés.
    private nonisolated static func readCache() -> (stations: Set<String>, sources: Set<String>) {
        guard let dict = UserDefaults.standard.dictionary(forKey: cacheKey) else { return ([], []) }
        return (Set((dict["stations"] as? [String]) ?? []),
                Set((dict["sources"]  as? [String]) ?? []))
    }
}

import Foundation
import CoreLocation
import UserNotifications
import UIKit
import os.log

@MainActor
class TideService: ObservableObject {
    @Published var tideData: [TideData] = []
    @Published var isLoading = false
    @Published var error: Error?
    @Published var ports: [Port] = []
    @Published var selectedPort: Port? {
        didSet {
            // Tout port consulté alimente la liste « récents » (MRU) du menu central.
            if let id = selectedPort?.id, id != oldValue?.id { recordRecentPort(id) }
        }
    }
    /// IDs des ports/spots récemment consultés (MRU, le plus récent en tête), persistés.
    @Published private(set) var recentPortIDs: [String] = UserDefaults.standard.stringArray(forKey: "recentPortIDs") ?? []
    @Published var userLocation: CLLocation?
    @Published var displayMode: PortDisplayMode = .alphabetical
    @Published var searchText: String = ""
    @Published var triggeredAlerts: [TideAlert] = []
    @Published var extendedTideData: [TideData] = []
    @Published var isLoadingExtended = false
    @Published var predictionAccuracy: HarmonicTideEngine.PredictionAccuracy = .uncalibrated
    /// Données combinées SHOM + prédictions, dédupliquées et triées — cache matérialisé
    @Published private(set) var allTideData: [TideData] = []
    /// État de marée courant, rafraîchi à chaque mutation de tideData et par timer externe
    @Published private(set) var cachedTideState: TideCalculator.TideState?

    // Injecté depuis l'UI (ContentView)
    var alertService: AlertService?
    
    // Les appels réseau sont maintenant délégués à TideRepository.
    private let favoritesKey = "favoritePorts"
    private let customPortsKey = "customPorts"
    
    // Constantes
    private struct Constants {
        static let defaultPortID = "ARCACHON_EYRAC"
    }

    enum PortDisplayMode {
        case alphabetical
        case nearest
        case favorites
        case search
        case custom
    }
    
    // MARK: - Timer de vérification des alertes
    private var alertCheckTimer: Timer?
    private let alertCheckInterval: TimeInterval = 300 // 5 min

    func startAlertMonitoring() {
        stopAlertMonitoring()
        alertCheckTimer = Timer.scheduledTimer(withTimeInterval: alertCheckInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateWidgetData()
                self.updateLiveActivity()
                await self.checkAlerts()
            }
        }
        appLogger.info("Monitoring des alertes démarré (toutes les \(Int(self.alertCheckInterval))s)")
    }

    func stopAlertMonitoring() {
        alertCheckTimer?.invalidate()
        alertCheckTimer = nil
    }

    // MARK: - Propriétés internes optimisées
    // Cache pour les résultats de recherche
    private var searchCache = [String: [Port]]()
    private var lastSearchQuery = ""
    private var searchQueryMinLength = 2
    private let maxSearchCacheEntries = 100
    
    // MARK: - Computed Properties

    // Note: `displayedPorts`, `groupedTides`, `nearestPorts` ont été supprimés —
    // ils étaient définis mais jamais consommés. Re-créer à la demande si besoin
    // en pensant à mémoïser (ports.count > 3500 → tri O(n log n) coûteux par body).

    var customPorts: [Port] {
        return ports.filter { $0.isCustom }.sorted { $0.name < $1.name }
    }

    /// Les 3 derniers ports/spots consultés, HORS port courant (déjà affiché dans le menu),
    /// résolus depuis le catalogue (un id orphelin — port supprimé — est simplement ignoré).
    var recentPorts: [Port] {
        let currentID = selectedPort?.id
        return Array(
            recentPortIDs
                .filter { $0 != currentID }
                .compactMap { id in ports.first { $0.id == id } }
                .prefix(3)
        )
    }

    /// Pousse un port en tête de la liste « récents » (dédup, borné), et persiste.
    private func recordRecentPort(_ id: String) {
        var list = recentPortIDs
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentPortIDs = list
        UserDefaults.standard.set(list, forKey: "recentPortIDs")
    }

    // MARK: - Initialization

    private var alertsObserver: NSObjectProtocol?
    /// Rattachement FR→TICON en cours au lancement (awaité avant le 1er fetch français).
    private var frenchHarmonicsTask: Task<Void, Never>?
    /// Vrai au TOUT PREMIER lancement (aucun port jamais choisi) → dès que la localisation
    /// arrive, on se cale sur le port le plus proche. Sinon on reste sur Arcachon par défaut.
    /// Consommé une seule fois (un choix manuel ou la première localisation l'éteint).
    private var awaitingInitialLocationPort = false

    init() {
        // Lancement rapide : on ne charge de façon synchrone que les ports français
        // (SHOM, ≈17 Ko). Le port par défaut/sauvegardé étant français dans l'immense
        // majorité des cas, l'app est immédiatement utilisable.
        self.ports = PortCatalog.shared.loadFrenchPorts()
        // Capté AVANT toute persistance : aucun port sauvegardé = tout premier lancement
        // → on attend la localisation pour choisir le port le plus proche.
        awaitingInitialLocationPort = UserDefaults.standard.string(forKey: "selectedPortId") == nil
        loadFavorites()
        loadCustomPorts()
        restoreSelectedPort()

        // Migration v3 du moteur harmonique : purge unique du cache marées ET des
        // calibrations persistées de l'époque SHOM (ajustées avec l'ancienne formule
        // V₀ buggée — `bestHarmonics` les préférait aux harmoniques TICON fraîches,
        // d'où des horaires décalés de ~3 h malgré le fix de formule).
        // v6 : corrections V₀ (MU2/NU2/L2/LAM2), facteur nodal f(L2), constituants
        // longue période (SA/SSA/MM/MF/MSF) réintégrés (casse), Z₀ international dérivé.
        // v7 : coefficient de marée NATIONAL (calculé à Brest, convention SHOM, marnage
        // montant ×94.4) pour les ports FR + coefficient par-port calibré pour le monde.
        // v8 : retrait du clamp `max(0, h)` (les BM sous le datum réapparaissent) + dérivation
        // Z₀ synchrone garantie avant prédiction. Le cache DISQUE pouvait contenir des marées
        // mondiales calculées avec Z₀=0 / clamp (ex. Ballycotton J0-J7 : 2 PM, aucune BM,
        // hauteurs ~1,7 m) → purge OBLIGATOIRE pour recalcul avec le moteur corrigé.
        // → purge OBLIGATOIRE du cache disque (il contenait les anciens coefficients faux).
        // Purge FORCÉE liée à la VERSION du moteur (et non plus une seule fois via un flag figé).
        // Le filename versionné du cache disque ne suffisait pas : une correction de HAUTEUR livrée
        // sans purge laissait un blob FAUX survivre sous la même version (curve figée sur l'ancienne
        // hauteur pendant que le calendrier recalculait juste). En liant le nettoyage à
        // `tideEnginePredictionVersion`, TOUTE hausse force un repart 100 % propre : cache disque,
        // calibrations réseau héritées, et fausses grandes marées. → curve et calendrier toujours
        // recalculés ensemble depuis le moteur courant.
        let engineCleanFlag = "engineCleanWipe_v\(tideEnginePredictionVersion)"
        if !UserDefaults.standard.bool(forKey: engineCleanFlag) {
            TideCache.shared.clearAll()
            HarmonicTideEngine.shared.clearAllCalibrations()
            SpringTideTracker.shared.clearAll()   // fausses grandes marées (anciens coefs)
            UserDefaults.standard.set(true, forKey: engineCleanFlag)
            appLogger.info("[TideService] Nettoyage moteur v\(tideEnginePredictionVersion) : cache disque + calibrations purgés")
        }

        // Harmoniques des ports FRANÇAIS (rattachement TICON + Z₀, hors main thread).
        // Remplace l'ancienne source SHOM — prédictions 100 % maison dès que prêt.
        let frenchPorts = self.ports.filter { $0.source == .shom }
        frenchHarmonicsTask = Task { [weak self] in
            let harmonics = await PortCatalog.shared.linkFrenchHarmonicsInBackground(frenchPorts: frenchPorts)
            guard self != nil else { return }
            PortCatalog.shared.register(harmonics)
            // Les ports français suivent le coefficient SHOM national (calculé à Brest).
            // L'ancrage coef-95 de Brest est pré-calculé ICI, hors-main, AVANT de déclarer les
            // ports → prêt dès la première prédiction (coefficient déterministe, pas de repli).
            let brestAnchor: Double? = await Task.detached(priority: .userInitiated) {
                harmonics.first { $0.id == "BREST" }.map { HarmonicTideEngine.computeSpringSemiRange($0) }
            }.value
            // Le coefficient national (Brest) ne vaut QU'EN MÉTROPOLE : on isole les ports
            // d'outre-mer (Polynésie, Nouvelle-Calédonie, Réunion, Antilles…) → aucun coef chez eux.
            let overseasFrenchIds = PortCatalog.overseasFrenchIds(frenchPorts)
            HarmonicTideEngine.shared.setFrenchPortIds(Set(frenchPorts.map(\.id)),
                                                       overseas: overseasFrenchIds,
                                                       brestAnchor: brestAnchor)
            // Recharger les recalages fins persistés — UNIQUEMENT pour les ports FRANÇAIS
            // rattachés loin. Les offsets de ports MONDIAUX (NOAA/TICON) sont désormais
            // erronés (cf. recalage OM désactivé) → on les PURGE pour neutraliser les
            // décalages hérités des anciennes installs.
            let frenchIds = Set(frenchPorts.map(\.id))
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("omCalib_") {
                let portId = String(key.dropFirst("omCalib_".count))
                guard frenchIds.contains(portId) else {
                    UserDefaults.standard.removeObject(forKey: key)
                    continue
                }
                if let dict = value as? [String: Any], let off = dict["offset"] as? Double, off != 0 {
                    HarmonicTideEngine.shared.registerTimeOffset(off, for: portId)
                }
            }
        }

        // Les ports mondiaux (NOAA + TICON, ≈5 Mo de JSON) sont décodés hors du thread
        // principal puis fusionnés, pour ne pas bloquer le premier rendu.
        Task { [weak self] in
            let world = await PortCatalog.shared.loadWorldPortsInBackground()
            guard let self else { return }
            PortCatalog.shared.register(world.harmonics)
            self.ports.append(contentsOf: world.ports)
            // RÉAPPLIQUER les favoris aux ports mondiaux fraîchement ajoutés : `loadFavorites()`
            // ne voyait que les ports FR au lancement, donc un favori étranger (NOAA/TICON)
            // perdait son drapeau à CHAQUE lancement (« les favoris sautent »). Purement additif
            // (source de vérité = liste persistée), aucun favori effacé.
            let favIDs = Set(UserDefaults.standard.stringArray(forKey: self.favoritesKey) ?? [])
            if !favIDs.isEmpty {
                for i in 0..<self.ports.count where favIDs.contains(self.ports[i].id) && !self.ports[i].isFavorite {
                    self.ports[i].isFavorite = true
                }
            }
            // Si le port sauvegardé n'était pas encore chargé (port étranger), on le
            // restaure maintenant que la liste est complète.
            if let savedID = UserDefaults.standard.string(forKey: "selectedPortId"),
               self.selectedPort?.id != savedID,
               let savedPort = self.ports.first(where: { $0.id == savedID }) {
                self.selectedPort = savedPort
                appLogger.info("[TideService] Port étranger restauré après chargement mondial: \(savedPort.name)")
            }
        }

        alertsObserver = NotificationCenter.default.addObserver(
            forName: AlertService.alertsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.scheduleBackgroundNotifications()
            }
        }
    }

    deinit {
        if let obs = alertsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        alertCheckTimer?.invalidate()
    }

    // MARK: - Private Methods

    /// Restaure le port sélectionné depuis UserDefaults, ou tombe sur le port
    /// par défaut si aucun port sauvegardé n'est trouvé dans la liste actuelle.
    private func restoreSelectedPort() {
        if let savedID = UserDefaults.standard.string(forKey: "selectedPortId"),
           let savedPort = ports.first(where: { $0.id == savedID }) {
            selectedPort = savedPort
            appLogger.info("[TideService] Port restauré depuis UserDefaults: \(savedPort.name)")
            return
        }
        selectedPort = ports.first { $0.id == Constants.defaultPortID }
        if let port = selectedPort {
            appLogger.info("[TideService] Port par défaut utilisé: \(port.name)")
        }
    }

    private func loadFavorites() {
        let localFavorites = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        // Fusionner avec iCloud
        let merged = CloudSyncService.shared.mergeInitialFavorites(localFavorites: localFavorites)
        for i in 0..<ports.count {
            if merged.contains(ports[i].id) {
                ports[i].isFavorite = true
            }
        }
        // Persister la fusion localement
        UserDefaults.standard.set(merged, forKey: favoritesKey)

        // Écouter les changements iCloud
        CloudSyncService.shared.onFavoritesChanged = { [weak self] cloudFavorites in
            guard let self else { return }
            for i in 0..<self.ports.count {
                self.ports[i].isFavorite = cloudFavorites.contains(self.ports[i].id)
            }
            UserDefaults.standard.set(cloudFavorites, forKey: self.favoritesKey)
            // objectWillChange.send() supprimé : @Published `ports` notifie déjà
        }
    }
    
    private func loadCustomPorts() {
        // 1) Ports perso locaux (UserDefaults).
        var customById: [String: Port] = [:]
        if let data = UserDefaults.standard.data(forKey: customPortsKey),
           let local = try? JSONDecoder().decode([Port].self, from: data) {
            for p in local { customById[p.id] = p }
        }
        // 2) Fusion avec iCloud (union par id) → récupère les spots perdus à la
        //    réinstallation ou créés sur un autre appareil. (Cf. favoris.)
        if let cloudData = CloudSyncService.shared.loadCustomPorts(),
           let cloud = try? JSONDecoder().decode([Port].self, from: cloudData) {
            for p in cloud where customById[p.id] == nil { customById[p.id] = p }
        }
        // 3) Injecter dans la liste des ports (dedup par id).
        for (_, port) in customById where !ports.contains(where: { $0.id == port.id }) {
            ports.append(port)
        }
        // 4) Re-persister la fusion (local + iCloud) pour que les deux soient à jour.
        if !customById.isEmpty { saveCustomPorts() }

        // 5) Écouter les changements iCloud (comme onFavoritesChanged) : on AJOUTE
        //    les ports entrants ; pas de re-push vers iCloud → pas de boucle.
        CloudSyncService.shared.onCustomPortsChanged = { [weak self] data in
            guard let self,
                  let incoming = try? JSONDecoder().decode([Port].self, from: data) else { return }
            var changed = false
            for p in incoming where !self.ports.contains(where: { $0.id == p.id }) {
                self.ports.append(p)
                changed = true
            }
            if changed, let d = try? JSONEncoder().encode(self.ports.filter { $0.isCustom }) {
                UserDefaults.standard.set(d, forKey: self.customPortsKey)
            }
        }
    }

    private func saveCustomPorts() {
        let customPorts = ports.filter { $0.isCustom }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(customPorts)
            UserDefaults.standard.set(data, forKey: customPortsKey)   // local : tout, sans limite
            // iCloud KVS est plafonné (~1 Mo) : on borne ce qu'on pousse (nombre + taille) pour ne
            // jamais saturer le store et casser TOUTE la sync. Le surplus reste disponible en local.
            let bounded = Array(customPorts.suffix(300))
            let cloudData = try encoder.encode(bounded)
            if cloudData.count <= 700_000 {
                CloudSyncService.shared.saveCustomPorts(cloudData)
            } else {
                appLogger.warning("[TideService] Ports perso trop volumineux pour iCloud (\(cloudData.count) o) — push ignoré, données conservées en local.")
            }
        } catch {
            appLogger.error("Erreur lors de la sauvegarde des ports personnalisés: \(error)")
        }
    }
    
    // MARK: - Public Methods
    
    @discardableResult
    func addCustomPort(name: String, latitude: Double, longitude: Double, referencePortId: String, timeOffset: Int) -> Port? {
        // Validation : nom non vide, coordonnées dans les bornes, décalage raisonnable
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 60 else {
            appLogger.warning("[TideService] addCustomPort refusé: nom vide ou trop long")
            return nil
        }
        guard (-90.0...90.0).contains(latitude) else {
            appLogger.warning("[TideService] addCustomPort refusé: latitude hors bornes (\(latitude))")
            return nil
        }
        guard (-180.0...180.0).contains(longitude) else {
            appLogger.warning("[TideService] addCustomPort refusé: longitude hors bornes (\(longitude))")
            return nil
        }
        // Décalage horaire : max ±12h (en minutes)
        guard (-720...720).contains(timeOffset) else {
            appLogger.warning("[TideService] addCustomPort refusé: décalage hors bornes (\(timeOffset) min)")
            return nil
        }
        // Le port de référence doit exister
        guard let referencePort = ports.first(where: { $0.id == referencePortId }) else {
            appLogger.warning("[TideService] addCustomPort refusé: port de référence introuvable (\(referencePortId))")
            return nil
        }

        let customPort = Port.createCustomPort(
            name: trimmedName,
            latitude: latitude,
            longitude: longitude,
            referencePortId: referencePortId,
            timeOffset: timeOffset,
            timeZoneIdentifier: referencePort.portTimeZoneIdentifier
        )

        ports.append(customPort)
        saveCustomPorts()
        return customPort
    }

    /// Matérialise un SPOT DE SURF en port custom (rattaché au port de référence le plus proche)
    /// pour pouvoir l'OUVRIR comme un port : marée (du port de réf), prévision houle (aux coords
    /// du spot) et score surf (via sa SpotConfig). Idempotent — réutilise le port existant de même
    /// id. NON favori → ne pollue pas les favoris. L'appelant écrit la SpotConfig (orientation/break).
    @discardableResult
    func materializeSurfSpot(id: String, name: String, latitude: Double, longitude: Double, country: String) -> Port? {
        if let existing = ports.first(where: { $0.id == id }) { return existing }
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude),
              let ref = nearestReferencePort(to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        else {
            appLogger.warning("[TideService] materializeSurfSpot refusé: coords hors bornes ou aucun port de référence")
            return nil
        }
        let port = Port(id: id, name: name, latitude: latitude, longitude: longitude,
                        isFavorite: false, isCustom: true, referencePortId: ref.id, timeOffset: 0,
                        portTimeZoneIdentifier: ref.portTimeZoneIdentifier, source: ref.source, country: country)
        ports.append(port)
        saveCustomPorts()
        return port
    }

    /// Port officiel (SHOM/NOAA/TICON) le plus proche d'une coordonnée — sert de
    /// référence de marée pour un spot custom créé sur la carte.
    func nearestReferencePort(to coordinate: CLLocationCoordinate2D) -> Port? {
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return ports.filter { !$0.isCustom }
            .min { loc.distance(from: $0.location) < loc.distance(from: $1.location) }
    }

    func removeCustomPort(portId: String) {
        if let index = ports.firstIndex(where: { $0.id == portId && $0.isCustom }) {
            ports.remove(at: index)
            saveCustomPorts()
            purgePortState(portId: portId)
        }
    }

    func updateCustomPort(_ port: Port) {
        // Vérifier que c'est bien un port personnalisé
        guard port.isCustom else { return }

        // Mettre à jour le port si l'index existe
        if let index = ports.firstIndex(where: { $0.id == port.id }) {
            ports[index] = port
            saveCustomPorts()
        }
    }
    
    func saveFavorites() {
        let favoriteIDs = ports.filter { $0.isFavorite }.map { $0.id }
        UserDefaults.standard.set(favoriteIDs, forKey: favoritesKey)
        CloudSyncService.shared.saveFavorites(favoriteIDs)
    }
    
    func toggleFavorite(port: Port) {
        if let index = ports.firstIndex(where: { $0.id == port.id }) {
            ports[index].isFavorite.toggle()
            let stillFavorite = ports[index].isFavorite
            saveFavorites()
            // Retiré des favoris = retiré de « mes spots » → on purge ses notifs + état par-spot.
            // (Un spot peut être abonné aux notifs « fenêtre GO » sans être favori : on clé sur l'id.)
            if !stillFavorite { purgePortState(portId: port.id) }
        }
    }

    /// Purge SYNCHRONE de TOUT l'état par-spot quand un port est supprimé / retiré des favoris.
    /// La notif « fenêtre de GO » se rejoue en arrière-plan depuis cet état (`SportSetupStore`
    /// + `goWindow.portCoords`) : la supprimer ne suffit pas — il faut tuer ce qui la régénère.
    /// Clé sur portId, indépendamment du statut favori/custom.
    func purgePortState(portId: String) {
        // 1. Alertes liées au port (vent s'établit / forecast / marée) → récupère leurs id.
        let removedAlertIds = (alertService?.removeAlerts(forPort: portId) ?? []).map { $0.uuidString }
        // 2. Sports + abonnement « fenêtre GO » (sort le spot de notifyEnabledPortIDs).
        SportSetupStore.shared.removePort(portId)
        // 3. Machines à états background (GO + vent s'établit) + snapshot coords.
        WindEstablishingService.shared.purge(portId: portId, alertIds: removedAlertIds)
        // 4. Config spot (orientation…) + cache marée + buffer de biais (jauge de confiance).
        SpotConfigStore.shared.remove(for: portId)
        TideCache.shared.invalidate(portId: portId)
        ForecastBiasService.shared.purge(portId: portId)
        // 5. Données widget par-port + registre des ports disponibles.
        WidgetDataWriter.removePort(portId: portId)
        // 6. Notifs marée/forecast PROGRAMMÉES de ces alertes (annulables par id) + cooldowns forecast.
        NotificationScheduler.cancelPending(forAlertIds: removedAlertIds)
        for id in removedAlertIds { UserDefaults.standard.removeObject(forKey: "forecastAlert_\(id)") }
        // 7. / 7b. UNIQUEMENT si le port n'existe PLUS dans `ports` (= suppression d'un port
        //    custom, retiré par l'appelant AVANT la purge). RETIRER DES FAVORIS un port du
        //    catalogue (toggleFavorite) passe aussi par ici, mais le port reste consultable —
        //    détourner la sélection sous l'utilisateur (rebasculer sur le port le plus proche
        //    alors qu'il regarde ce port) était un vrai bug d'UX.
        let portStillExists = ports.contains { $0.id == portId }
        // 7. Si le port supprimé était le port sélectionné persisté → on nettoie.
        if !portStillExists, UserDefaults.standard.string(forKey: "selectedPortId") == portId {
            UserDefaults.standard.removeObject(forKey: "selectedPortId")
            UserDefaults.standard.removeObject(forKey: "selectedPortName")
        }
        // 7b. … ET s'il était le port sélectionné EN MÉMOIRE → rebascule tout de suite sur un port
        //     valide (le plus proche non-custom, sinon le port par défaut) + refetch. Sans ça, l'UI /
        //     widget / Live Activity restaient sur un port fantôme et l'app sautait silencieusement
        //     au défaut au prochain lancement.
        if !portStillExists, selectedPort?.id == portId {
            let fallback = (userLocation.flatMap { nearestReferencePort(to: $0.coordinate) })
                ?? ports.first { $0.id == Constants.defaultPortID }
                ?? ports.first { !$0.isCustom }
            selectedPort = fallback
            if fallback != nil { Task { await fetchTideData() } }
        }
        // 8. Retire le port de la liste « récents » du menu (déjà filtré à l'affichage, on borne le store).
        if recentPortIDs.contains(portId) {
            recentPortIDs.removeAll { $0 == portId }
            UserDefaults.standard.set(recentPortIDs, forKey: "recentPortIDs")
        }
        // 9. Re-snapshot immédiat des coords → le spot disparaît tout de suite du background.
        refreshGoNotifyCoords()
    }

    func updateUserLocation(_ location: CLLocation) {
        self.userLocation = location
        // Tout premier lancement + localisation accordée → se caler sur le port le plus
        // proche de l'iPhone (sauf si l'utilisateur a déjà choisi un port entre-temps :
        // on ne touche alors qu'au cas « encore sur Arcachon par défaut »).
        if awaitingInitialLocationPort {
            awaitingInitialLocationPort = false
            if selectedPort?.id == Constants.defaultPortID,
               let nearest = nearestReferencePort(to: location.coordinate),
               nearest.id != selectedPort?.id {
                appLogger.info("[TideService] Port initial = plus proche de l'iPhone : \(nearest.name)")
                selectedPort = nearest
                // Charger explicitement ses marées : l'observateur de TodayView ne refetch
                // QUE pour les spots custom → sans ça, on afficherait les marées d'Arcachon
                // sous le nom du port proche. fetchTideData lit le cache d'abord (quasi gratuit).
                Task { await fetchTideData() }
            }
        }
    }
    
    // Méthode de recherche optimisée avec cache
    func optimizedSearchPorts(query: String) -> [Port] {
        if query.isEmpty || query.count < searchQueryMinLength {
            return []
        }

        // Normalise la requête ET la clé de cache : "Arcachon", "arcachon", "ARCACHON"
        // partagent désormais la même entrée.
        let normalizedQuery = Self.normalizedSearch(query)
        if let cached = searchCache[normalizedQuery] { return cached }

        let results = ports.filter { port in
            Self.normalizedSearch(port.name).contains(normalizedQuery)
        }.sorted { $0.name < $1.name }

        lastSearchQuery = normalizedQuery
        searchCache[normalizedQuery] = results
        trimSearchCacheIfNeeded(keeping: normalizedQuery)

        return results
    }

    private static func normalizedSearch(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    }

    private func trimSearchCacheIfNeeded(keeping query: String) {
        guard searchCache.count > maxSearchCacheEntries else { return }
        // Garder la moitié des entrées les plus récentes plutôt que tout supprimer
        let keysToRemove = searchCache.keys.filter { $0 != query }.prefix(searchCache.count / 2)
        for key in keysToRemove {
            searchCache.removeValue(forKey: key)
        }
    }
    
    // Conserver l'ancienne méthode pour des raisons de compatibilité
    func searchPorts(query: String) -> [Port] {
        return optimizedSearchPorts(query: query)
    }
    
    /// Fetch tide data for an arbitrary port without changing selectedPort
    func fetchTideDataForPort(_ portId: String) async -> [TideData] {
        // Check cache first
        if let cached = TideCache.shared.get(portId: portId) {
            return cached
        }
        let port = ports.first { $0.id == portId }
        // Port personnalisé : marées du port de référence décalées (sinon l'API ne connaît
        // pas l'id custom → 0 donnée sur la carte / la fiche).
        if let port, port.isCustom, let referenceId = port.referencePortId {
            let resolved = await resolveCustomPortTides(port, referencePortId: referenceId)
            if !resolved.isEmpty { TideCache.shared.set(portId: portId, tides: resolved) }
            return resolved
        }
        do {
            let tides = try await fetchTideDataFromAnySource(portId: portId, source: port?.source ?? .shom)
            let sorted = tides.sorted { $0.date < $1.date }
            TideCache.shared.set(portId: portId, tides: sorted)
            return sorted
        } catch {
            appLogger.error("fetchTideDataForPort(\(portId)) failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Marées résolues d'un port custom = marées d'un port de référence + décalage horaire.
    /// Robustesse : certains ports SHOM voisins (ports secondaires) n'ont pas d'endpoint
    /// API et renvoient 0 donnée. On essaie d'abord la référence stockée, puis on retombe
    /// sur les ports officiels les plus proches jusqu'à en trouver un qui répond.
    /// Utilise `fetchTideDataFromAnySource` → SHOM / NOAA / TICON indifféremment.
    func resolveCustomPortTides(_ customPort: Port, referencePortId: String) async -> [TideData] {
        let offsetSeconds = TimeInterval(customPort.timeOffset * 60)
        let here = CLLocation(latitude: customPort.latitude, longitude: customPort.longitude)

        // Candidats : la référence stockée d'abord, puis les officiels les plus proches.
        var candidates: [Port] = []
        if let stored = ports.first(where: { $0.id == referencePortId }) { candidates.append(stored) }
        let nearby = ports.filter { !$0.isCustom && $0.id != referencePortId }
            .sorted { here.distance(from: $0.location) < here.distance(from: $1.location) }
            .prefix(6)
        candidates.append(contentsOf: nearby)

        // Robustesse : jusqu'à 3 passes avec backoff. Un échec SHOM transitoire (réseau
        // froid, station momentanément indisponible) ne doit pas laisser le spot sans
        // marées jusqu'à la prochaine navigation.
        for attempt in 0..<3 {
            if Task.isCancelled { return [] }
            for ref in candidates {
                guard let tides = try? await fetchTideDataFromAnySource(portId: ref.id, source: ref.source),
                      !tides.isEmpty else { continue }
                if ref.id != referencePortId {
                    appLogger.info("[TideService] Spot \(customPort.name): référence \(referencePortId) sans données → repli sur \(ref.name)")
                }
                return tides.map {
                    TideData(date: $0.date.addingTimeInterval(offsetSeconds),
                             height: $0.height, isHighTide: $0.isHighTide, coefficient: $0.coefficient)
                }.sorted { $0.date < $1.date }
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }
        appLogger.error("resolveCustomPortTides(\(customPort.name)): aucune référence proche avec données après 3 essais")
        return []
    }

    /// Route la récupération des données selon la source du port.
    /// Délègue à TideRepository ; TideService ne garde que la logique d'état.
    private func fetchTideDataFromAnySource(portId: String, source: PortSource) async throws -> [TideData] {
        // Ports français : prédiction harmonique maison. Au premier lancement, le
        // rattachement FR→TICON peut être encore en cours (≈1-3 s) → on l'attend.
        if source == .shom, !HarmonicTideEngine.shared.hasHarmonics(for: portId) {
            await frenchHarmonicsTask?.value
        }
        let port = ports.first(where: { $0.id == portId })
        return try await TideRepository.shared.fetchTideData(portId: portId, source: source, port: port)
    }
    
    func fetchTideData(forceRefresh: Bool = false) async {
        guard let port = selectedPort else {
            return
        }

        isLoading = true
        error = nil
        // Port suivi pour l'alerte « le vent s'établit » en arrière-plan (BGTask).
        WindEstablishingService.setMonitoredPort(
            id: port.id, name: port.name, latitude: port.latitude, longitude: port.longitude)
        refreshGoNotifyCoords()   // snapshot coordonnées des spots à notifier (résolution background)

        // Ports NOAA/TICON : dériver le zéro hydrographique (Z₀) avant toute prédiction
        // harmonique (les JSON bundlés ne fournissent qu'un niveau moyen nul). Idempotent
        // et payé une seule fois par port.
        if port.source == .noaa || port.source == .ticon {
            await HarmonicTideEngine.shared.ensureChartDatum(for: port.id)
        }

        // Garde « in-flight » : le port a pu changer pendant les await ci-dessus (switch
        // rapide de port). On ne diffuse jamais les données d'un port qui n'est plus
        // sélectionné — sinon l'UI / le widget / la Live Activity affichent le mauvais port.
        guard selectedPort?.id == port.id else {
            self.isLoading = false
            return
        }

        // Vérifier le cache d'abord (sauf si forceRefresh)
        if !forceRefresh {
            if let cachedTides = TideCache.shared.get(portId: port.id) {
                self.tideData = cachedTides
                self.isLoading = false
                updateDerivedState()
                updateWidgetData()
                updateLiveActivity()
                await checkAlerts()
                await scheduleBackgroundNotifications()
                return
            }
        }
        
        do {
            // Si c'est un port personnalisé, utiliser les données du port de référence avec décalage
            if port.isCustom, let referencePortId = port.referencePortId {
                await fetchCustomPortTideData(customPort: port, referencePortId: referencePortId)
                return
            }

            let tides = try await fetchTideDataFromAnySource(portId: port.id, source: port.source)
            let sorted = tides.sorted { $0.date < $1.date }

            // Le cache est indexé par port : on l'écrit même si l'utilisateur a changé de
            // port entre-temps (utile au prochain accès).
            TideCache.shared.set(portId: port.id, tides: sorted)

            // … mais on ne diffuse l'état UI/widget/Live Activity que si ce port est
            // toujours le port sélectionné (garde « in-flight » après l'await réseau).
            guard selectedPort?.id == port.id else {
                self.isLoading = false
                return
            }

            self.tideData = sorted
            self.isLoading = false
            updateDerivedState()

            // Pour les ports NOAA, récupérer les constantes harmoniques en arrière-plan
            if port.source == .noaa {
                Task {
                    await fetchAndCacheNOAAHarmonics(portId: port.id)
                }
            }
            // Recalage temporel vs Open-Meteo (arrière-plan, throttlé 14 j). La fonction
            // s'auto-filtre : FR rattachés loin (>25 km) + TOUS les ports mondiaux NOAA/TICON
            // (leur principal recalage d'horaire) → corrige les « gros soucis d'horaire ».
            Task { await self.fineTunePortOffset(port: port) }

            // Tracker les grandes marées
            SpringTideTracker.shared.trackSpringTides(
                from: self.tideData, portId: port.id,
                portName: port.name, source: port.source.rawValue
            )

            // Mettre à jour le widget + Live Activity
            updateWidgetData()
            updateLiveActivity()
            await checkAlerts()
            await scheduleBackgroundNotifications()
        } catch {
            // Même garde « in-flight » sur les chemins de repli : ne pas écrire les
            // données d'un port qui n'est plus sélectionné.
            guard selectedPort?.id == port.id else {
                self.isLoading = false
                return
            }
            // En cas d'erreur réseau, tenter les prédictions harmoniques (fallback)
            if port.source == .noaa || port.source == .ticon {
                let harmonicFallback = TideRepository.shared.fetchFromHarmonics(portId: port.id)
                if !harmonicFallback.isEmpty {
                    self.tideData = harmonicFallback
                    self.isLoading = false
                    updateDerivedState()
                    updateWidgetData()
                    return
                }
            }

            // En cas d'erreur, essayer le cache même expiré
            if let cachedTides = TideCache.shared.get(portId: port.id) {
                self.tideData = cachedTides
                self.isLoading = false
                updateDerivedState()
                updateWidgetData()
                return
            }

            self.isLoading = false
            self.error = error
        }
    }
    
    private func fetchCustomPortTideData(customPort: Port, referencePortId: String) async {
        guard ports.contains(where: { $0.id == referencePortId }) else {
            self.isLoading = false
            self.error = NSError(domain: "TideService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Port de référence introuvable"])
            return
        }

        let resolved = await resolveCustomPortTides(customPort, referencePortId: referencePortId)
        self.isLoading = false

        // Cache port-keyé conservé même si l'utilisateur a changé de port pendant l'await…
        if !resolved.isEmpty {
            TideCache.shared.set(portId: customPort.id, tides: resolved)
        }
        // … mais on ne diffuse rien si ce spot n'est plus sélectionné (garde « in-flight »).
        guard selectedPort?.id == customPort.id else { return }

        if resolved.isEmpty {
            self.error = NSError(domain: "TideService", code: 500,
                                 userInfo: [NSLocalizedDescriptionKey: "Marées indisponibles pour ce spot"])
            return
        }
        self.tideData = resolved
        updateDerivedState()
        updateWidgetData()
    }
    
    // MARK: - NOAA Harmonics

    /// Récupère et met en cache les constantes harmoniques d'un port NOAA
    private func fetchAndCacheNOAAHarmonics(portId: String) async {
        let engine = HarmonicTideEngine.shared
        guard !engine.hasHarmonics(for: portId) else { return }

        do {
            let harmonics = try await NOAAService.shared.fetchHarmonicConstituents(stationId: portId)
            if harmonics.isValid {
                engine.registerHarmonics(harmonics)
                appLogger.debug("[TideService] Harmoniques NOAA chargées pour \(portId): \(harmonics.constituents.count) constituants")
            }
        } catch {
            appLogger.warning("[TideService] Impossible de charger les harmoniques NOAA pour \(portId): \(error.localizedDescription)")
        }
    }

    // MARK: - Recalage fin vs Open-Meteo (ports rattachés loin de leur station)

    /// Recale le décalage temporel d'un port en comparant les extrema prédits au niveau d'eau
    /// Open-Meteo (FES2014, MONDIAL). Ports FR : réservé aux rattachements lointains (> 25 km,
    /// les marégraphes locaux sont déjà précis). Ports MONDIAUX (NOAA/TICON) : c'est LEUR
    /// recalage temporel principal (corrige les « gros soucis d'horaire ») → appliqué
    /// systématiquement, gardé par une PORTE D'AMPLITUDE (si le marnage OM diverge trop du
    /// prédit, la maille large d'OM ne représente pas ce port — estuaire/lagune — on s'abstient
    /// plutôt que de dégrader un port dont le marégraphe local capte déjà son retard propre).
    /// L'offset s'applique UNIFORMÉMENT au proche ET à l'étendu → pas de jonction J7/J8.
    private func fineTunePortOffset(port: Port) async {
        let key = "omCalib_\(port.id)"
        // Throttle : une calibration tous les 14 jours par port.
        if let saved = UserDefaults.standard.dictionary(forKey: key),
           let ts = saved["date"] as? TimeInterval,
           Date().timeIntervalSince1970 - ts < 14 * 86400 {
            return
        }
        // Éligibilité selon la source.
        switch port.source {
        case .shom:
            // Ports FR rattachés loin de leur station (> 25 km) : OM peut capter un retard
            // spatial local que la station distante ne voit pas. Les marégraphes proches
            // sont déjà précis → on ne recale pas.
            guard let d = PortCatalog.shared.frenchLinkDistanceKm[port.id], d > 25 else { return }
        case .noaa, .ticon:
            // Recalage Open-Meteo DÉSACTIVÉ pour les ports mondiaux. La grille FES2014 d'OM
            // est systématiquement ~40-70 min EN AVANCE sur le littoral (vérifié numériquement
            // vs vérité NOAA et marées publiées) : elle tirait des prédictions pourtant
            // correctes trop tôt (ex. Ballycotton ~40 min, San Francisco ~63 min). L'harmonique
            // brut (phases Greenwich) colle à la vérité terrain à ~quelques minutes → on le garde.
            return
        }

        let omExtrema = await MarineWeatherService.shared.fetchSeaLevelExtrema(
            latitude: port.latitude, longitude: port.longitude
        )
        guard omExtrema.count >= 4 else { return }

        let engine = HarmonicTideEngine.shared
        let now = Date()
        let predicted = engine.predictTides(
            from: now.addingTimeInterval(-86_400),
            to: now.addingTimeInterval(3 * 86_400),   // fenêtre 4 j → plus d'extrema, médiane robuste
            portId: port.id
        )
        guard predicted.count >= 4 else { return }

        // PORTE D'AMPLITUDE : marnage OM vs marnage prédit. Ratio < 0,70 → maille OM inadaptée
        // (estuaire/lagune) → on ne recale pas (mais on marque la tentative pour ne pas boucler).
        func span(_ highs: [Double], _ lows: [Double]) -> Double? {
            guard let hi = highs.max(), let lo = lows.min(), hi > lo else { return nil }
            return hi - lo
        }
        let omSpan = span(omExtrema.filter { $0.isHigh }.map { $0.height },
                          omExtrema.filter { !$0.isHigh }.map { $0.height })
        let predSpan = span(predicted.filter { $0.isHighTide }.map { $0.height },
                            predicted.filter { !$0.isHighTide }.map { $0.height })
        if let o = omSpan, let p = predSpan, min(o, p) / max(o, p) < 0.70 {
            appLogger.info("[TideService] Recalage \(port.name) ANNULÉ : marnage OM/prédit divergent")
            UserDefaults.standard.set(["offset": engine.timeOffset(for: port.id),
                                       "date": Date().timeIntervalSince1970], forKey: key)
            return
        }

        // Appariement type-à-type, médiane des deltas (OM − prédit).
        var deltas: [Double] = []
        for ext in omExtrema {
            guard let match = predicted
                .filter({ $0.isHighTide == ext.isHigh })
                .min(by: { abs($0.date.timeIntervalSince(ext.date)) < abs($1.date.timeIntervalSince(ext.date)) }),
                abs(match.date.timeIntervalSince(ext.date)) < 3 * 3600 else { continue }
            deltas.append(ext.date.timeIntervalSince(match.date))
        }
        guard deltas.count >= 4 else { return }
        let median = deltas.sorted()[deltas.count / 2]

        // Marquer la calibration (avant tout refetch → pas de boucle).
        let newOffset = max(-4500, min(4500, engine.timeOffset(for: port.id) + median))
        UserDefaults.standard.set(["offset": newOffset, "date": Date().timeIntervalSince1970], forKey: key)

        // < 4 min d'écart → rien à changer.
        guard abs(median) > 240 else { return }

        engine.registerTimeOffset(newOffset, for: port.id)
        appLogger.info("[TideService] Recalage \(port.name) : médiane \(Int(median))s → offset \(Int(newOffset))s")

        // Rafraîchir l'affichage : marées PROCHES *et* ÉTENDUES (sinon la jonction J7/J8 reste
        // décalée car l'étendu garderait l'ancien offset).
        TideCache.shared.invalidate(portId: port.id)
        if selectedPort?.id == port.id {
            await fetchTideData(forceRefresh: true)
            await fetchExtendedPredictions()
        }
    }

    // MARK: - Prédictions étendues (J8 à J30+)

    /// Charge les prédictions au-delà de la fenêtre courante — prédictions harmoniques
    /// maison pour TOUS les ports (FR = constituants TICON, NOAA/TICON = idem).
    /// Plus aucune source scrappée (SHOM / maree.info débranchés).
    func fetchExtendedPredictions(days: Int = 30) async {
        guard let port = selectedPort else { return }
        isLoadingExtended = true
        // Repart PROPRE : on vide l'étendu de l'ANCIEN port → le calendrier retombe immédiatement
        // sur le proche du NOUVEAU port (today..+7) le temps du recalcul, jamais sur les marées
        // d'un autre port (corrige « ne se rafraîchit pas au changement de port »).
        if !extendedTideData.isEmpty { extendedTideData = []; updateDerivedState() }

        let engine = HarmonicTideEngine.shared
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // L'étendu démarre AUJOURD'HUI (et non le 1er du mois) : afficher les marées PASSÉES ne sert
        // à rien. Les jours déjà écoulés du mois restent donc sans donnée (grisés dans la grille).
        // Prédiction harmonique CONTINUE today→+30, source UNIQUE du calendrier (updateDerivedState).
        let startDate = today
        guard let endDate = calendar.date(byAdding: .day, value: days, to: today) else {
            isLoadingExtended = false
            return
        }

        // Attendre le rattachement FR si nécessaire (premier lancement).
        if port.source == .shom, !engine.hasHarmonics(for: port.id) {
            await frenchHarmonicsTask?.value
        }
        // Ports mondiaux : DÉRIVER LE Z₀ avant de prédire l'étendu. Sans ça, J8-J30 était
        // calculé autour de Z₀=0 (course async) alors que J0-J7 utilisait le Z₀ résolu →
        // marche d'escalier de hauteur à la jonction J7/J8.
        if port.source == .noaa || port.source == .ticon {
            await engine.ensureChartDatum(for: port.id)
        }

        var harmonicData: [TideData] = []
        if engine.hasHarmonics(for: port.id) || engine.isCalibrated(for: port.id) {
            // Calcul harmonique (~14 400 itérations trig pour 30j) déplacé sur
            // un thread de fond pour ne pas freezer l'UI.
            harmonicData = await engine.predictTidesAsync(from: startDate, to: endDate, portId: port.id)
        }

        extendedTideData = harmonicData.sorted { $0.date < $1.date }
        updateDerivedState()
        predictionAccuracy = harmonicData.isEmpty ? engine.predictionAccuracy : .high
        isLoadingExtended = false
    }

    /// Recalcule allTideData (combiné + dédupliqué) — appelé après chaque mutation de tideData ou extendedTideData
    private func updateDerivedState() {
        // 1. Recompute allTideData depuis une SOURCE UNIQUE par plage — évite toute couture
        //    inter-sources. L'ÉTENDU (1er du mois → +30 j) couvre déjà tout le calendrier visible
        //    d'un seul tracé cohérent ; on n'ajoute le proche QUE hors de la plage de l'étendu
        //    (ex. étendu pas encore chargé → on retombe sur le proche, lui-même continu).
        //    ⚠️ Bug 15-21 juin (SF) : fusionner proche+étendu DANS leur zone de chevauchement
        //    (today→+7) réunissait deux jeux d'extrema filtrés différemment — le filtre « 3 h » du
        //    moteur est À ÉTAT et dépend de la date de départ du run, donc le proche gardait une BM
        //    que l'étendu jetait → deux « Basse mer » d'affilée sur une pente descendante. Une seule
        //    source par plage supprime la cause à la racine.
        let base: [TideData]
        if let lo = extendedTideData.first?.date, let hi = extendedTideData.last?.date {
            base = (extendedTideData + tideData.filter { $0.date < lo || $0.date > hi })
                .sorted { $0.date < $1.date }
        } else {
            base = tideData.sorted { $0.date < $1.date }
        }
        // FILET DE SÉCURITÉ : une marée alterne TOUJOURS PM/BM. On écarte
        //   (a) tout extremum à < 3 h du précédent retenu (doublon de couture résiduel) ;
        //   (b) deux extrema de MÊME type consécutifs (impossible physiquement) en gardant le plus
        //       marqué — la PM la plus haute, la BM la plus basse.
        var deduped: [TideData] = []
        for tide in base {
            if let last = deduped.last {
                if tide.date.timeIntervalSince(last.date) < 3 * 3600 { continue }
                if tide.isHighTide == last.isHighTide {
                    let keepNew = tide.isHighTide ? (tide.height > last.height) : (tide.height < last.height)
                    if keepNew { deduped[deduped.count - 1] = tide }
                    continue
                }
            }
            deduped.append(tide)
        }
        allTideData = deduped
        // 2. Refresh cached tide state (tideData is already sorted)
        cachedTideState = TideCalculator.currentState(at: Date(), sortedTides: tideData)
    }

    /// Rafraîchit l'état de marée courant — appelé par le timer externe (TodayView)
    func refreshTideState() {
        cachedTideState = TideCalculator.currentState(at: Date(), sortedTides: tideData)
    }

    // MARK: - Notifications en arrière-plan
    private func scheduleBackgroundNotifications() async {
        guard let alertService = alertService else { return }
        let portLocation: CLLocation? = selectedPort.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        await NotificationScheduler.reschedule(
            alerts: alertService.alerts,
            tideData: allTideData,
            portId: selectedPort?.id,
            portLocation: portLocation
        )
    }

    // MARK: - Live Activity
    func updateLiveActivity() {
        let manager = LiveActivityManager.shared
        guard manager.isActive, !tideData.isEmpty else { return }

        guard let state = cachedTideState ?? TideCalculator.currentState(at: Date(), sortedTides: tideData) else { return }

        let trendString: String
        switch state.trend {
        case .rising: trendString = "rising"
        case .falling: trendString = "falling"
        case .highSlack: trendString = "highSlack"
        case .lowSlack: trendString = "lowSlack"
        }

        // Vent pour la DA « mini mode vent » : balise observée (premium + fraîche) sinon prévu.
        var windKmh: Double?, windGust: Double?, windDir: Double?, windIsLive = false
        var goSport: String?
        var sunriseToday: Date?, sunsetToday: Date?
        let now = Date()
        if let port = selectedPort {
            let forecasts = MarineWeatherService.shared.cachedForecast(for: port) ?? []
            if let near = WindStationAggregator.shared.nearestReading(for: port),
               PremiumManager.shared.canUseRealtimeWind {
                windKmh = near.reading.speedAvgKmh
                windGust = near.reading.gustKmh
                windDir = near.reading.directionDegrees
                windIsLive = true
            } else if let fc = forecasts.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }) {
                windKmh = fc.windSpeedKmh
                windGust = fc.windGustKmh
                windDir = fc.windDirection
            }
            // (windCurve n'est plus rendu nulle part — la Live Activity affiche la courbe
            //  MARÉE + soleil — donc on ne le calcule plus : payload ActivityKit allégé.)

            // Soleil du jour (indépendant de la météo → l'arc solaire s'affiche toujours).
            let cal = Calendar.inTimeZone(port.portTimeZone)
            var sun: [(sunrise: Date, sunset: Date)] = []
            let startDay = cal.startOfDay(for: now)
            for d in 0...1 {
                if let day = cal.date(byAdding: .day, value: d, to: startDay),
                   let s = SolarCalculator.sunriseSunset(latitude: port.latitude, longitude: port.longitude, date: day) {
                    sun.append(s)
                }
            }
            sunriseToday = sun.first?.sunrise
            sunsetToday = sun.first?.sunset

            // Un sport est-il GO MAINTENANT ? (premier sport activé dont une fenêtre couvre l'instant)
            if !forecasts.isEmpty {
                let spot = SpotConfigStore.shared.config(for: port.id)
                let tide = tideData   // capture LOCALE → évite self.tideData dans la closure scorer (classe)
                for setup in SportSetupStore.shared.enabledSetups(for: port.id) where setup.sport.isSurf || setup.auto || !setup.conditions.isEmpty {
                    let wins = ActivityGoPlanner.windows(for: setup, forecasts: forecasts, sunTimes: sun, tideData: tide,
                                                         scorer: { sp, f, lvl in ActivityScoreService.shared.scoreHour(sport: sp, at: f, tideData: tide, spot: spot, riderLevel: lvl) })
                    if wins.contains(where: { $0.start <= now && $0.end >= now }) {
                        goSport = setup.sport.localizedName
                        break
                    }
                }
            }
        }

        let contentState = TideLiveActivityAttributes.ContentState(
            currentHeight: state.currentHeight,
            trend: trendString,
            nextTideDate: state.nextTide?.date ?? Date(),
            nextTideHeight: state.nextTide?.height ?? 0,
            nextTideIsHigh: state.nextTide?.isHighTide ?? true,
            nextTideCoef: state.nextTide?.coefficient,
            tideProgress: state.percentToNextTide,
            curve: LiveActivityManager.curvePoints(from: tideData),
            windKmh: windKmh,
            windGustKmh: windGust,
            windDirDeg: windDir,
            windIsLive: windIsLive,
            windCurve: [],
            goSport: goSport,
            sunrise: sunriseToday,
            sunset: sunsetToday
        )

        // Le nom du port est FIGÉ dans les attributs de l'activité. Si le port a changé,
        // pousser le nouvel état dans l'ancienne activité afficherait « Arcachon » avec les
        // marées de « Saint-Malo » → on redémarre avec les bons attributs.
        if let port = selectedPort, manager.currentPortName != port.name {
            manager.start(portName: port.name, state: contentState)
            return
        }

        Task {
            await manager.update(state: contentState)
        }
    }

    /// Délégué à TideAlertEvaluator — ne conserve ici que la mise à jour d'état.
    /// Snapshot léger portId → coordonnées des spots susceptibles d'être notifiés « fenêtre GO »
    /// (abonnés + favoris + sélectionné). lat/lon sont constants → permet à `WindEstablishingService`
    /// de résoudre un spot en arrière-plan sans recharger le catalogue.
    private func refreshGoNotifyCoords() {
        var map: [String: (name: String, lat: Double, lon: Double)] = [:]
        let subscribed = Set(SportSetupStore.shared.notifyEnabledPortIDs)
        for p in ports where p.isFavorite || subscribed.contains(p.id) {
            map[p.id] = (p.name, p.latitude, p.longitude)
        }
        if let s = selectedPort { map[s.id] = (s.name, s.latitude, s.longitude) }
        WindEstablishingService.setGoNotifyPortCoords(map)
    }

    private func checkAlerts() async {
        guard let alertService = alertService, let port = selectedPort else { return }
        let triggered = await TideAlertEvaluator.shared.evaluate(
            alertService: alertService,
            port: port,
            tideData: tideData
        )
        if !triggered.isEmpty {
            self.triggeredAlerts = triggered
        }
        // Alerte INTELLIGENTE « le vent s'établit » (machine à états + balise). L'évaluateur
        // ci-dessus a déjà rafraîchi la balise → on lit la mesure fraîche.
        let reading = WindStationAggregator.shared.nearestReading(for: port)?.reading
        await WindEstablishingService.shared.evaluate(reading: reading, portId: port.id, portName: port.name)
        // Notif « fenêtre de GO ici » pour le spot SÉLECTIONNÉ (sans réseau en plus : même mesure
        // fraîche). Le gate notify(for:) interne ignore les spots non abonnés.
        await WindEstablishingService.shared.evaluateGo(reading: reading, portId: port.id, portName: port.name,
                                                        lat: port.latitude, lon: port.longitude)
    }
    
    private func updateWidgetData() {
        guard let port = selectedPort else { return }

        // Vent observé pour le widget Vent : balise la plus proche du port suivi.
        // Premium → valeurs réelles ; non-premium mais balise présente → état verrouillé
        // (upsell, sans fuiter la mesure). Pas de balise → rien.
        var windSnap: WidgetDataWriter.ObservedWindSnapshot?
        if let near = WindStationAggregator.shared.nearestReading(for: port) {
            if PremiumManager.shared.canUseRealtimeWind {
                windSnap = .init(
                    speedKmh: near.reading.speedAvgKmh,
                    gustKmh: near.reading.gustKmh,
                    directionDeg: near.reading.directionDegrees,
                    stationName: near.station.name,
                    distanceKm: near.distanceKm,
                    date: near.reading.date,
                    premiumLocked: false
                )
            } else {
                windSnap = .init(
                    speedKmh: 0, gustKmh: nil, directionDeg: 0,
                    stationName: near.station.name,
                    distanceKm: near.distanceKm,
                    date: near.reading.date,
                    premiumLocked: true
                )
            }
        }

        // Vent PRÉVU (cache, sans réseau) : repli du widget vent quand pas de balise.
        var forecastSnap: WidgetDataWriter.ForecastWindSnapshot?
        if let fc = MarineWeatherService.shared.cachedForecast(for: port)?
            .min(by: { abs($0.time.timeIntervalSinceNow) < abs($1.time.timeIntervalSinceNow) }) {
            forecastSnap = .init(speedKmh: fc.windSpeedKmh, gustKmh: fc.windGustKmh,
                                 directionDeg: fc.windDirection, confidence: fc.windConfidence)
        }

        // Surf : UNIQUEMENT pour les spots de surf du catalogue (les ports classiques n'accueillent
        // pas l'activité surf). Houle dominante + verdict « coup d'œil », lus dans le cache marine
        // (aucun réseau) → offline-safe ; nil si pas de donnée de vague (jamais une fausse valeur).
        let isSurfSpot = SurfSpotCatalog.shared.spot(id: port.id) != nil
        var surfSnap: WidgetDataWriter.SurfSnapshot?
        if isSurfSpot,
           let f = MarineWeatherService.shared.cachedForecast(for: port)?
               .min(by: { abs($0.time.timeIntervalSinceNow) < abs($1.time.timeIntervalSinceNow) }) {
            let cfg = SpotConfigStore.shared.config(for: port.id)
            if let m = SurfHourMetrics.make(from: f, spot: cfg) {
                let grade = SurfMetrics.grade(for: f, spot: cfg)
                surfSnap = .init(swellHeightM: m.dominantSwellHeight,
                                 swellPeriodS: m.dominantSwellPeriod,
                                 swellDirectionDeg: m.dominantSwellDirection,
                                 gradeRaw: grade.rawValue)
            }
        }

        WidgetDataWriter.saveForWidget(
            portName: port.name,
            portId: port.id,
            tideData: tideData,
            currentTime: Date(),
            portTimeZoneIdentifier: port.portTimeZoneIdentifier,
            latitude: port.latitude,
            longitude: port.longitude,
            observedWind: windSnap,
            forecastWind: forecastSnap,
            isSurfSpot: isSurfSpot,
            surf: surfSnap
        )
        // Persister le port sélectionné pour App Intents / Siri
        UserDefaults.standard.set(port.id, forKey: "selectedPortId")
        UserDefaults.standard.set(port.name, forKey: "selectedPortName")
    }

    /// Rafraîchit les données du widget — appelé lors du retour au premier plan
    func refreshWidgetData() {
        updateWidgetData()
        // Pousser AUSSI un état frais à la Live Activity au retour au premier plan.
        // Sans ça, une activité démarrée par une ancienne build n'était jamais
        // re-rendue → le bandeau gardait l'ancienne mise en page après mise à jour.
        updateLiveActivity()
    }
} 
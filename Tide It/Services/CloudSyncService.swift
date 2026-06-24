//
//  CloudSyncService.swift
//  Tide It
//
//  Synchronisation iCloud via NSUbiquitousKeyValueStore
//  Synchronise : favoris, port sélectionné, alertes
//

import Foundation
import Combine
import os.log

@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    private let store = NSUbiquitousKeyValueStore.default

    // Clés iCloud
    private enum Keys {
        static let favorites = "cloud_favoritePorts"
        static let selectedPort = "cloud_selectedPortId"
        static let alerts = "cloud_savedTideAlerts"
        static let settings = "cloud_settings"
        static let customPorts = "cloud_customPorts"
        static let lastSync = "cloud_lastSyncDate"
    }

    /// Clés de réglages (UserDefaults.standard) synchronisées entre appareils.
    static let syncedSettingKeys = [
        "appearanceMode", "windMode", "curveMode", "tideParticlesEnabled",
        "measureSystem", "windSpeedUnit", "preferredActivities",
        "riderMinWindKmh", "spotConfigs",
        "pwAlertsEnabled",
        "sportSetupsBySpot_v1",   // « Mes sports » PAR SPOT : conditions + suivi + toggle notif par port.
        "sportSetups",            // (hérité — sert encore de template par défaut à la migration)
        // "pecheAlertsEnabled" retiré : pêche à pied hors périmètre (cf. ThemeManager.pecheAPiedEnabled).
    ]

    // Callback quand les favoris changent depuis un autre appareil
    var onFavoritesChanged: (([String]) -> Void)?
    var onSelectedPortChanged: ((String) -> Void)?
    /// Appelé quand les ports personnalisés changent depuis un autre appareil
    /// (blob JSON `[Port]`). L'observateur décode et fusionne (union par id).
    var onCustomPortsChanged: ((Data) -> Void)?
    /// Appelé quand les réglages ont changé depuis un autre appareil (déjà appliqués
    /// dans UserDefaults ; l'observateur n'a plus qu'à se rafraîchir).
    var onSettingsChanged: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    /// Task de debounce pour batcher les appels à `synchronize()`
    /// (évite de bloquer le main thread après chaque save de favoris/alertes).
    private var pendingSyncTask: Task<Void, Never>?
    private let syncDebounceSeconds: TimeInterval = 1.5

    private init() {
        // S'abonner aux changements iCloud
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleExternalChange(notification)
            }
            .store(in: &cancellables)

        // Synchroniser au lancement
        store.synchronize()
        appLogger.info("[CloudSync] Initialisé")
    }

    // MARK: - Push (écriture vers iCloud)

    func saveFavorites(_ favoriteIDs: [String]) {
        store.set(favoriteIDs, forKey: Keys.favorites)
        store.set(Date().timeIntervalSince1970, forKey: Keys.lastSync)
        scheduleSync()
        appLogger.debug("[CloudSync] Favoris sauvegardés (\(favoriteIDs.count) ports)")
    }

    func saveSelectedPort(_ portId: String) {
        store.set(portId, forKey: Keys.selectedPort)
        scheduleSync()
    }

    func saveAlerts(_ data: Data) {
        store.set(data, forKey: Keys.alerts)
        scheduleSync()
        appLogger.debug("[CloudSync] Alertes sauvegardées")
    }

    /// Pousse les ports personnalisés (blob JSON `[Port]`) vers iCloud.
    func saveCustomPorts(_ data: Data) {
        store.set(data, forKey: Keys.customPorts)
        store.set(Date().timeIntervalSince1970, forKey: Keys.lastSync)
        scheduleSync()
        appLogger.debug("[CloudSync] Ports perso sauvegardés (\(data.count) o)")
    }

    // MARK: - Réglages (apparence, unités, options d'affichage)

    /// Pousse les réglages locaux vers iCloud (un seul dictionnaire).
    func saveSettings() {
        let defaults = UserDefaults.standard
        var dict: [String: Any] = [:]
        for key in Self.syncedSettingKeys {
            if let value = defaults.object(forKey: key) { dict[key] = value }
        }
        store.set(dict, forKey: Keys.settings)
        store.set(Date().timeIntervalSince1970, forKey: Keys.lastSync)
        scheduleSync()
        appLogger.debug("[CloudSync] Réglages sauvegardés (\(dict.count) clés)")
    }

    /// Applique les réglages iCloud dans UserDefaults. Retourne `false` si iCloud n'a rien.
    @discardableResult
    private func applyCloudSettings() -> Bool {
        guard let dict = store.dictionary(forKey: Keys.settings), !dict.isEmpty else { return false }
        let defaults = UserDefaults.standard
        for (key, value) in dict where Self.syncedSettingKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        return true
    }

    /// Au lancement : applique les réglages iCloud s'ils existent (last-writer-wins),
    /// sinon pousse les réglages locaux vers iCloud.
    func mergeInitialSettings() {
        if !applyCloudSettings() {
            saveSettings()
        }
    }

    /// Planifie un `synchronize()` avec debounce. Les appels rapprochés
    /// (toggle de plusieurs favoris, édition d'alerte, etc.) sont coalescés
    /// en un seul flush vers iCloud.
    private func scheduleSync() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.syncDebounceSeconds ?? 1.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.store.synchronize()
        }
    }

    /// Flush immédiat — à utiliser uniquement lors de scenarios critiques
    /// (fermeture de l'app, demande explicite).
    func flushSyncNow() {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        store.synchronize()
    }

    // MARK: - Pull (lecture depuis iCloud)

    func loadFavorites() -> [String]? {
        store.array(forKey: Keys.favorites) as? [String]
    }

    func loadSelectedPort() -> String? {
        store.string(forKey: Keys.selectedPort)
    }

    func loadAlerts() -> Data? {
        store.data(forKey: Keys.alerts)
    }

    func loadCustomPorts() -> Data? {
        store.data(forKey: Keys.customPorts)
    }

    // MARK: - External Change Handler

    private func handleExternalChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else { return }

        // Ne traiter que les changements serveur ou initiaux
        guard reason == NSUbiquitousKeyValueStoreServerChange ||
              reason == NSUbiquitousKeyValueStoreInitialSyncChange else { return }

        guard let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }

        appLogger.info("[CloudSync] Changement externe : \(changedKeys.joined(separator: ", "))")

        for key in changedKeys {
            switch key {
            case Keys.favorites:
                if let favorites = store.array(forKey: Keys.favorites) as? [String] {
                    onFavoritesChanged?(favorites)
                    appLogger.info("[CloudSync] Favoris reçus depuis iCloud (\(favorites.count) ports)")
                }
            case Keys.selectedPort:
                if let portId = store.string(forKey: Keys.selectedPort) {
                    onSelectedPortChanged?(portId)
                    appLogger.info("[CloudSync] Port sélectionné reçu : \(portId)")
                }
            case Keys.settings:
                applyCloudSettings()
                onSettingsChanged?()
                appLogger.info("[CloudSync] Réglages reçus depuis iCloud")
            case Keys.customPorts:
                if let data = store.data(forKey: Keys.customPorts) {
                    onCustomPortsChanged?(data)
                    appLogger.info("[CloudSync] Ports perso reçus depuis iCloud")
                }
            default:
                break
            }
        }
    }

    // MARK: - Merge au lancement

    /// Fusionne les favoris locaux et iCloud (union)
    func mergeInitialFavorites(localFavorites: [String]) -> [String] {
        guard let cloudFavorites = loadFavorites() else {
            // Pas de données iCloud, pousser les données locales
            saveFavorites(localFavorites)
            return localFavorites
        }

        // Union des deux ensembles
        let merged = Array(Set(localFavorites + cloudFavorites))
        if Set(merged) != Set(localFavorites) {
            appLogger.info("[CloudSync] Fusion : \(localFavorites.count) locaux + \(cloudFavorites.count) iCloud = \(merged.count) favoris")
        }

        // Sauvegarder la fusion
        saveFavorites(merged)
        return merged
    }
}

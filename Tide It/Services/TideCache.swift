//
//  TideCache.swift
//  Tide It
//
//  Cache intelligent pour les données de marée avec persistence
//

import Foundation
import os.log

final class TideCache: @unchecked Sendable {
    static let shared = TideCache()

    /// Clé disque VERSIONNÉE par le moteur : à chaque hausse de `tideEnginePredictionVersion`,
    /// la clé change → les prédictions cachées par une ancienne version ne sont plus lues
    /// (auto-invalidation, fini les marées périmées après une correction du moteur).
    private let cacheKey = "tideCacheData_v\(tideEnginePredictionVersion)"
    private let cacheKeyPrefix = "tideCacheData"
    private let cacheDuration: TimeInterval = 6 * 3600 // 6 heures
    
    private var memoryCache: [String: CachedTideData] = [:]
    private let queue = DispatchQueue(label: "com.tideit.cache", attributes: .concurrent)
    
    struct CachedTideData: Codable {
        let portId: String
        let tides: [TideData]
        let fetchDate: Date
        let expirationDate: Date
        
        var isExpired: Bool {
            Date() > expirationDate
        }
    }
    
    private init() {
        purgeStaleVersions()
        loadFromDisk()
    }

    /// Supprime les caches des versions de moteur ANTÉRIEURES (clé legacy non versionnée
    /// incluse) → pas d'accumulation dans UserDefaults, et aucune chance de relire du périmé.
    private func purgeStaleVersions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(cacheKeyPrefix) && key != cacheKey {
            defaults.removeObject(forKey: key)
        }
    }
    
    // MARK: - Public API
    
    func get(portId: String) -> [TideData]? {
        queue.sync {
            guard let cached = memoryCache[portId], !cached.isExpired else {
                return nil
            }
            return cached.tides
        }
    }
    
    func set(portId: String, tides: [TideData]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let cached = CachedTideData(
                portId: portId,
                tides: tides,
                fetchDate: Date(),
                expirationDate: Date().addingTimeInterval(self.cacheDuration)
            )
            self.memoryCache[portId] = cached
            self.saveToDisk()
        }
    }
    
    func invalidate(portId: String) {
        queue.async(flags: .barrier) { [weak self] in
            self?.memoryCache.removeValue(forKey: portId)
            self?.saveToDisk()
        }
    }
    
    func invalidateAll() {
        queue.async(flags: .barrier) { [weak self] in
            self?.memoryCache.removeAll()
            self?.saveToDisk()
        }
    }
    
    func clearAll() {
        queue.async(flags: .barrier) { [weak self] in
            self?.memoryCache.removeAll()
            UserDefaults.standard.removeObject(forKey: self?.cacheKey ?? "")
        }
    }
    
    // MARK: - Persistence

    /// Sauvegarde asynchrone sur disque — évite de bloquer le thread appelant
    private func saveToDisk() {
        let snapshot = Array(memoryCache.values)
        let key = cacheKey
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                DispatchQueue.main.async {
                    UserDefaults.standard.set(data, forKey: key)
                }
            } catch {
                appLogger.error("TideCache: Erreur sauvegarde - \(error)")
            }
        }
    }
    
    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        
        do {
            let cachedItems = try JSONDecoder().decode([CachedTideData].self, from: data)
            for item in cachedItems where !item.isExpired {
                memoryCache[item.portId] = item
            }
        } catch {
            appLogger.error("TideCache: Erreur chargement - \(error)")
        }
    }
}

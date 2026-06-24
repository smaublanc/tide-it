//
//  SurfSpotCatalog.swift
//  Tide It
//
//  Catalogue des spots de surf = SEED embarqué (surf_spots.json, orientations « suggérées »)
//  + spots ajoutés/affinés par l'utilisateur (persistés localement). Les spots NE polluent PAS
//  la liste des ports/favoris : ils vivent dans ce catalogue à part, affichés dynamiquement sur
//  la carte. Chaque spot se RATTACHE au port de référence le plus proche pour sa marée
//  (TideService.nearestReferencePort), à la volée (pas de ref stockée → jamais périmée).
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class SurfSpotCatalog: ObservableObject {
    static let shared = SurfSpotCatalog()
    static let userStorageKey = "surfSpotsUser_v1"

    /// Seed + spots utilisateur fusionnés (l'utilisateur écrase le seed par `id`), triés par nom.
    @Published private(set) var spots: [SurfSpot] = []

    private var seed: [SurfSpot] = []
    private var userSpots: [SurfSpot] = []

    private init() {
        seed = Self.loadSeed()
        userSpots = Self.loadUser()
        rebuild()
    }

    private func rebuild() {
        var byId: [String: SurfSpot] = [:]
        for s in seed { byId[s.id] = s }
        for s in userSpots { byId[s.id] = s }   // l'utilisateur prime (override ou ajout)
        spots = byId.values.sorted { $0.name < $1.name }
    }

    // MARK: - Requêtes carte

    /// Spots dans un rayon (km) d'une coordonnée — pour la carte (le filtrage viewport se fait
    /// en amont ; ici on borne par distance). Tri par proximité.
    func spots(near coord: CLLocationCoordinate2D, radiusKm: Double) -> [SurfSpot] {
        let center = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return spots
            .map { ($0, CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: center)) }
            .filter { $0.1 <= radiusKm * 1000 }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    func nearest(to coord: CLLocationCoordinate2D) -> SurfSpot? {
        let center = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return spots.min {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: center)
            < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: center)
        }
    }

    func spot(id: String) -> SurfSpot? { spots.first { $0.id == id } }

    // MARK: - Rattachement au port le plus proche (marée)

    /// Port officiel de référence le plus proche du spot → fournit la MARÉE du spot.
    /// Résolu à la volée (pas stocké) pour ne jamais devenir périmé si le catalogue de ports change.
    /// `TideService` n'est pas un singleton → l'appelant (qui en détient une instance) le passe.
    func referencePort(for spot: SurfSpot, using tideService: TideService) -> Port? {
        tideService.nearestReferencePort(to: spot.coordinate)
    }

    // MARK: - Ouverture d'un spot (matérialisation + config) — SOURCE UNIQUE

    /// Matérialise un spot du catalogue en port custom (marée du port de réf le plus proche) et,
    /// à la 1ʳᵉ ouverture, pose sa config terrain (SpotConfig) + des conditions GO surf intelligentes.
    /// Renvoie le port. UTILISÉ par la carte (tap pastille) ET le picker (section Surf) → pas de doublon.
    func materializeAndConfigure(_ spotID: String, tideService: TideService) -> Port? {
        guard let spot = spot(id: spotID) else { return nil }
        let isNew = !tideService.ports.contains { $0.id == spot.id }
        guard let port = tideService.materializeSurfSpot(
            id: spot.id, name: spot.name,
            latitude: spot.latitude, longitude: spot.longitude, country: spot.country
        ) else { return nil }
        if isNew {
            SpotConfigStore.shared.set(spot.spotConfig, for: port.id)
            let smart = SurfConditions.intelligent(facingBearingDeg: spot.facingBearingDeg,
                                                   skillFloor: spot.skillFloor, breakType: spot.breakType)
            SportSetupStore.shared.configureAsSurfSpot(smart, for: port.id)
        }
        return port
    }

    // MARK: - Édition utilisateur

    func add(_ spot: SurfSpot) {
        userSpots.removeAll { $0.id == spot.id }
        userSpots.append(spot)
        persistUser()
        rebuild()
    }

    /// Supprime un spot UTILISATEUR. (Un spot du seed ne peut pas être supprimé — il peut être
    /// masqué/édité via un override utilisateur de même `id`.)
    func removeUserSpot(id: String) {
        userSpots.removeAll { $0.id == id }
        persistUser()
        rebuild()
    }

    func isUserSpot(id: String) -> Bool { userSpots.contains { $0.id == id } }

    // MARK: - Persistance

    private static func loadSeed() -> [SurfSpot] {
        guard let url = Bundle.main.url(forResource: "surf_spots", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SurfSpotSeed].self, from: data) else {
            return []
        }
        return decoded.map { $0.asSpot }
    }

    private static func loadUser() -> [SurfSpot] {
        guard let data = UserDefaults.standard.data(forKey: userStorageKey),
              let decoded = try? JSONDecoder().decode([SurfSpot].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistUser() {
        if let data = try? JSONEncoder().encode(userSpots) {
            UserDefaults.standard.set(data, forKey: Self.userStorageKey)
        }
    }
}

/// Forme du JSON embarqué `surf_spots.json` (sans `source`, qui vaut toujours `.seed`).
private struct SurfSpotSeed: Codable {
    let id: String
    let name: String
    let country: String
    let region: String?
    let latitude: Double
    let longitude: Double
    let facingBearingDeg: Double
    let breakType: BreakType?
    let bottomType: BottomType?
    let skillFloor: Int?

    var asSpot: SurfSpot {
        SurfSpot(id: id, name: name, latitude: latitude, longitude: longitude,
                 facingBearingDeg: facingBearingDeg, breakType: breakType, bottomType: bottomType,
                 country: country, region: region, skillFloor: skillFloor, source: .seed)
    }
}

//
//  WebcamCatalog.swift
//  Tide It
//
//  Webcams du littoral, servies depuis un catalogue EMBARQUÉ (`webcams.json`).
//
//  POURQUOI PAS UNE API ?
//  Un seul fournisseur offre une vraie requête géographique : Windy. Son palier gratuit a été
//  lu intégralement, et il impose trois choses rédhibitoires ici — l'éditeur n'a PAS le droit
//  de réserver la fonctionnalité à ses abonnés payants (elle devrait donc être offerte à tout
//  le monde), Windy se réserve le droit de diffuser SA publicité dans l'app, et la bloquer
//  résilie le contrat. Le palier sans publicité coûte 9 990 € par an.
//  Un catalogue de webcams vérifiées à la main coûte zéro, ne dépend de personne, n'affiche
//  aucune publicité, et se met à jour par une ligne de JSON.
//
//  CE QUE L'APP FAIT, ET CE QU'ELLE NE FAIT PAS
//  Elle OUVRE la page de l'exploitant : un lien n'est pas une contrefaçon, et ça lui envoie
//  du trafic au lieu de le lui prendre. Elle ne rejoue le flux DANS l'app que pour les caméras
//  dont l'exploitant a donné un accord écrit (`embed: true`) — guideline App Store 5.2 :
//  rediffuser le flux d'un tiers sans accord fait retirer l'APPLICATION, pas la fonctionnalité.
//

import Foundation
import CoreLocation

struct Webcam: Identifiable, Hashable {
    let id: String
    let name: String
    /// Commune et secteur, tels que relevés à la vérification.
    let place: String
    let latitude: Double
    let longitude: Double
    /// Page publique de l'exploitant — ce que l'app ouvre.
    let page: URL
    /// Flux jouable DANS l'app. Reste `false` tant qu'un accord écrit n'a pas été reçu.
    let embed: Bool

    /// Haversine sur les Double stockés (même approche que `WindStation.distance`) : appelée
    /// pour chaque webcam à chaque rendu de la carte vent, donc zéro allocation.
    func distance(to coord: CLLocationCoordinate2D) -> CLLocationDistance {
        let r = 6_371_000.0
        let dLat = (coord.latitude - latitude) * .pi / 180
        let dLon = (coord.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(coord.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

@MainActor
final class WebcamCatalog {
    static let shared = WebcamCatalog()

    /// Au-delà, une webcam ne montre plus le spot qu'on regarde mais une autre plage.
    /// Une image du mauvais endroit est pire que pas d'image : elle induit en erreur.
    static let maxDistanceMeters: CLLocationDistance = 15_000
    /// L'utilisateur en veut une, on en propose trois. Au-delà c'est une liste, plus un choix.
    static let maxSuggestions = 3

    private(set) var all: [Webcam] = []

    private init() { load() }

    private func load() {
        guard let url = Bundle.main.url(forResource: "webcams", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["webcams"] as? [[String: Any]] else { return }

        all = list.compactMap { d in
            guard let id = d["id"] as? String,
                  let name = d["name"] as? String,
                  let lat = d["lat"] as? Double,
                  let lon = d["lon"] as? Double,
                  let pageStr = d["page"] as? String,
                  let page = URL(string: pageStr) else { return nil }
            return Webcam(id: id, name: name, place: (d["place"] as? String) ?? "",
                          latitude: lat, longitude: lon, page: page,
                          embed: (d["embed"] as? Bool) ?? false)
        }
    }

    /// Les webcams les plus proches d'un point, retraits appliqués.
    ///
    /// Le filtre de retrait est posé ICI, seul chemin d'accès au catalogue : un exploitant qui
    /// demande à ne plus y figurer disparaît de partout sans qu'on ait à se souvenir des écrans
    /// qui l'affichaient — même raisonnement que `WindStationAggregator.rebuildDedup`.
    func nearest(to coord: CLLocationCoordinate2D,
                 limit: Int = maxSuggestions,
                 maxDistance: CLLocationDistance = maxDistanceMeters) -> [(cam: Webcam, distance: CLLocationDistance)] {
        let blocklist = SourceBlocklistService.shared
        return all
            .filter { !blocklist.isBlocked(webcamID: $0.id) }
            .map { ($0, $0.distance(to: coord)) }
            .filter { $0.1 <= maxDistance }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { (cam: $0.0, distance: $0.1) }
    }
}

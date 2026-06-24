//
//  SurfSpot.swift
//  Tide It
//
//  Un SPOT DE SURF : une vague identifiée par sa position GPS + l'orientation de la côte
//  (facing) + son type de break. Ce N'EST PAS un port :
//   - la HOULE / le VENT se lisent aux VRAIES coordonnées du spot ;
//   - la MARÉE vient du PORT DE RÉFÉRENCE le plus proche (résolu à la volée via
//     TideService.nearestReferencePort) — c'est « le surf lu à travers la marée ».
//
//  Provenance honnête : un spot du SEED est « suggéré » (orientation à affiner par
//  l'utilisateur) ; un spot créé/édité par l'utilisateur est marqué `.user`.
//

import Foundation
import CoreLocation

struct SurfSpot: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// Cap de la mer ouverte vu du spot (deg, 0=N). Identique à `SpotConfig.shoreOrientation` :
    /// pilote l'offshore = (facing+180)%360 et l'exposition à la houle.
    var facingBearingDeg: Double
    var breakType: BreakType?
    var bottomType: BottomType?
    var country: String
    var region: String?
    var skillFloor: Int?
    var source: Source

    /// D'où vient le spot : seed embarqué (orientation « suggérée ») ou créé/affiné par l'utilisateur.
    enum Source: String, Codable { case seed, user }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// L'orientation du seed est une SUGGESTION (cap de côte approché) tant que l'utilisateur
    /// ne l'a pas validée → l'UI peut l'étiqueter « suggéré ».
    var orientationIsSuggested: Bool { source == .seed }

    /// Config terrain dérivée pour le moteur de score (réutilise `SpotConfig`, déjà branché
    /// sur surfingScore via `currentSpot`). La marée vient du port de référence, pas d'ici.
    var spotConfig: SpotConfig {
        SpotConfig(shoreOrientation: facingBearingDeg,
                   spotType: .ocean,
                   breakType: breakType,
                   bottomType: bottomType,
                   skillFloor: skillFloor)
    }

    init(id: String, name: String, latitude: Double, longitude: Double,
         facingBearingDeg: Double, breakType: BreakType? = nil, bottomType: BottomType? = nil,
         country: String, region: String? = nil, skillFloor: Int? = nil, source: Source) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.facingBearingDeg = facingBearingDeg
        self.breakType = breakType
        self.bottomType = bottomType
        self.country = country
        self.region = region
        self.skillFloor = skillFloor
        self.source = source
    }
}

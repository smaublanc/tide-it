import Foundation
import CoreLocation

/// Source de données d'un port
enum PortSource: String, Codable, CaseIterable {
    case shom   // Ports français (SHOM)
    case noaa   // Ports US (NOAA CO-OPS)
    case ticon  // Ports mondiaux (TICON-4 harmoniques)

    var label: String {
        switch self {
        case .shom:  return "Officiel"
        case .noaa:  return "NOAA"
        case .ticon: return "Harmoniques"
        }
    }

    var regionLabel: String {
        switch self {
        case .shom:  return "France"
        case .noaa:  return "États-Unis"
        case .ticon: return "Monde"
        }
    }
}

struct Port: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    var isFavorite: Bool = false
    var isCustom: Bool = false
    var referencePortId: String? = nil  // ID du port de référence pour un port personnalisé
    var timeOffset: Int = 0  // Décalage en minutes par rapport au port de référence
    var portTimeZoneIdentifier: String = "Europe/Paris"  // Fuseau horaire du port
    var source: PortSource = .shom  // Source de données du port
    /// Pays ou région du port (pour regroupement dans l'UI)
    var country: String = "France"

    /// Fuseau horaire résolu du port (fallback : Europe/Paris)
    var portTimeZone: TimeZone {
        TimeZone(identifier: portTimeZoneIdentifier) ?? TimeZone(identifier: "Europe/Paris") ?? .current
    }

    /// Déduit l'identifiant de fuseau IANA d'un port français à partir de ses coordonnées.
    ///
    /// Le catalogue SHOM (`shom_ports.txt`) ne fournit pas de fuseau : sans cette
    /// résolution, tous les ports — y compris l'outre-mer — tomberaient sur
    /// « Europe/Paris » (Tahiti afficherait l'heure de Paris). On classe ici la
    /// métropole et chaque territoire d'outre-mer vers un fuseau au décalage horaire
    /// (et aux règles d'heure d'été) corrects. Le fuseau choisi a toujours le bon
    /// offset pour la zone, ce qui garantit des heures de marée justes.
    static func frenchTimeZoneIdentifier(latitude lat: Double, longitude lon: Double) -> String {
        func inBox(_ latMin: Double, _ latMax: Double, _ lonMin: Double, _ lonMax: Double) -> Bool {
            lat >= latMin && lat <= latMax && lon >= lonMin && lon <= lonMax
        }

        // — Pacifique — (l'ordre compte : Marquises/Gambier avant la boîte large Tahiti)
        if inBox(-23, -17, 158, 170)   { return "Pacific/Noumea" }            // Nouvelle-Calédonie   UTC+11
        if inBox(-15, -12, -179, -175) { return "Pacific/Wallis" }            // Wallis-et-Futuna      UTC+12
        if inBox(-11, -7, -141, -138)  { return "Pacific/Marquesas" }         // Îles Marquises        UTC-9:30
        if inBox(-24, -22, -136, -133) { return "Pacific/Gambier" }           // Îles Gambier          UTC-9
        if inBox(-28, -7, -155, -133)  { return "Pacific/Tahiti" }            // Société, Tuamotu, Australes  UTC-10

        // — Océan Indien —
        if inBox(-25, -10, 38, 50)     { return "Indian/Mayotte" }            // Mayotte + Îles Éparses  UTC+3
        if inBox(-22, -20, 54, 57)     { return "Indian/Reunion" }            // La Réunion             UTC+4
        if inBox(-47, -45, 50, 53)     { return "Indian/Reunion" }            // Crozet                 UTC+4
        if inBox(-50, -38, 67, 78)     { return "Indian/Kerguelen" }          // Kerguelen, Saint-Paul  UTC+5

        // — Antarctique —
        if inBox(-90, -60, 138, 142)   { return "Antarctica/DumontDUrville" } // Terre Adélie           UTC+10

        // — Amériques —
        if inBox(4, 6.5, -55, -51)     { return "America/Cayenne" }           // Guyane                 UTC-3
        if inBox(14, 18.5, -64, -60)   { return "America/Martinique" }        // Antilles françaises    UTC-4
        if inBox(46, 48, -57, -55)     { return "America/Miquelon" }          // Saint-Pierre-et-Miquelon  UTC-3 (HE)
        if inBox(9.5, 11, -110, -108)  { return "Etc/GMT+8" }                 // Clipperton (inhabité)  UTC-8

        // — Métropole (et tout le reste) —
        return "Europe/Paris"
    }

    // Init memberwise explicite (requis car init(from:) masque l'auto-generated)
    init(id: String, name: String, latitude: Double, longitude: Double,
         isFavorite: Bool = false, isCustom: Bool = false,
         referencePortId: String? = nil, timeOffset: Int = 0,
         portTimeZoneIdentifier: String = "Europe/Paris",
         source: PortSource = .shom, country: String = "France") {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.isFavorite = isFavorite
        self.isCustom = isCustom
        self.referencePortId = referencePortId
        self.timeOffset = timeOffset
        self.portTimeZoneIdentifier = portTimeZoneIdentifier
        self.source = source
        self.country = country
    }

    // Constructeur pour un port personnalisé
    static func createCustomPort(
        name: String,
        latitude: Double,
        longitude: Double,
        referencePortId: String,
        timeOffset: Int,
        timeZoneIdentifier: String = "Europe/Paris"
    ) -> Port {
        // Créer un ID unique pour le port personnalisé
        let customId = "CUSTOM_\(name.replacingOccurrences(of: " ", with: "_").uppercased())_\(UUID().uuidString.prefix(8))"
        
        return Port(
            id: customId,
            name: name,
            latitude: latitude,
            longitude: longitude,
            isFavorite: true,
            isCustom: true,
            referencePortId: referencePortId,
            timeOffset: timeOffset,
            portTimeZoneIdentifier: timeZoneIdentifier
        )
    }
    
    // Coordonnées formatées
    var formattedCoordinates: String {
        return String(format: "%.6f, %.6f", latitude, longitude)
    }
    
    // Format le décalage horaire avec + ou -
    var formattedTimeOffset: String {
        if timeOffset == 0 {
            return "Aucun décalage"
        }
        
        let sign = timeOffset >= 0 ? "+" : ""
        let hours = abs(timeOffset) / 60
        let minutes = abs(timeOffset) % 60
        
        if hours > 0 && minutes > 0 {
            return "\(sign)\(hours)h \(minutes)min"
        } else if hours > 0 {
            return "\(sign)\(hours)h"
        } else {
            return "\(sign)\(minutes)min"
        }
    }
    
    // Calculer la distance entre ce port et une localisation donnée
    func distance(to location: CLLocation) -> CLLocationDistance {
        let portLocation = CLLocation(latitude: latitude, longitude: longitude)
        return portLocation.distance(from: location)
    }
    
    // Renvoie la localisation du port
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
    
    // Renvoie une distance formatée en km ou m
    func formattedDistance(to location: CLLocation) -> String {
        let distance = self.distance(to: location)
        
        if distance >= 1000 {
            return String(format: "%.1f km", locale: Locale.current, distance / 1000)
        } else {
            return String(format: "%.0f m", distance)
        }
    }
    
    // Égalité basée sur l'identifiant
    static func == (lhs: Port, rhs: Port) -> Bool {
        lhs.id == rhs.id
    }
    
    // Hash basé sur l'identifiant
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Encodage et décodage pour la persistance
    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, isFavorite, isCustom, referencePortId, timeOffset, portTimeZoneIdentifier, source, country
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        referencePortId = try c.decodeIfPresent(String.self, forKey: .referencePortId)
        timeOffset = try c.decodeIfPresent(Int.self, forKey: .timeOffset) ?? 0
        portTimeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .portTimeZoneIdentifier) ?? "Europe/Paris"
        source = try c.decodeIfPresent(PortSource.self, forKey: .source) ?? .shom
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? "France"
    }
}
//
//  TideAppIntents.swift
//  Tide It
//
//  App Intents pour Siri et Raccourcis
//

import AppIntents
import Foundation
import os.log

// MARK: - Port Entity (pour la sélection dans Shortcuts)

struct PortEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Port")
    static var defaultQuery = PortEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PortEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PortEntity] {
        let ports = loadPorts()
        return ports.filter { identifiers.contains($0.id) }
            .map { PortEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [PortEntity] {
        // Proposer les favoris d'abord, puis les ports principaux
        let ports = loadPorts()
        let favoriteIDs = UserDefaults.standard.stringArray(forKey: "favoritePorts") ?? []
        let favorites = ports.filter { favoriteIDs.contains($0.id) }
        let others = ports.filter { !favoriteIDs.contains($0.id) }.prefix(10)
        return (favorites + others).map { PortEntity(id: $0.id, name: $0.name) }
    }

    private func loadPorts() -> [Port] {
        guard let url = Bundle.main.url(forResource: "shom_ports", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line -> Port? in
                let c = line.components(separatedBy: ":")
                guard c.count == 4,
                      let lat = Double(c[2]),
                      let lon = Double(c[3]) else { return nil }
                return Port(id: c[0], name: c[1], latitude: lat, longitude: lon,
                            portTimeZoneIdentifier: Port.frenchTimeZoneIdentifier(latitude: lat, longitude: lon))
            }
    }
}

extension PortEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [PortEntity] {
        let normalized = string.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        return loadPorts()
            .filter {
                $0.name.lowercased()
                    .folding(options: .diacriticInsensitive, locale: .current)
                    .contains(normalized)
            }
            .map { PortEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Intent : Marée actuelle

struct GetCurrentTideIntent: AppIntent {
    static var title: LocalizedStringResource = "Marée actuelle"
    static var description = IntentDescription("Affiche la hauteur et la tendance de la marée en ce moment.")

    @Parameter(title: "Port")
    var port: PortEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Marée actuelle à \(\.$port)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let portId = port?.id ?? selectedPortId()
        guard let portId else {
            return .result(dialog: "Aucun port sélectionné. Ouvre Tide It et choisis un port.")
        }

        let portName = port?.name ?? selectedPortName() ?? portId
        guard let tides = TideCache.shared.get(portId: portId), !tides.isEmpty else {
            return .result(dialog: "Pas de données de marée disponibles pour \(portName). Ouvre l'app pour les actualiser.")
        }

        guard let state = TideCalculator.currentState(at: Date(), sortedTides: tides) else {
            return .result(dialog: "Impossible de calculer l'état actuel de la marée à \(portName).")
        }

        let height = String(format: "%.1f", locale: Locale.current, state.currentHeight)
        let trend = state.trend.description.lowercased()
        var response = "À \(portName), la marée est \(trend) à \(height) m."

        if let next = state.nextTide {
            let type = next.isHighTide ? "pleine mer" : "basse mer"
            let time = intentTime(next.date, tz: intentPortTimeZone(for: portId))
            let nextHeight = String(format: "%.1f", locale: Locale.current, next.height)
            response += " Prochaine \(type) à \(time) (\(nextHeight) m)"
            if let coef = next.coefficient {
                response += ", coef \(coef)"
            }
            response += "."
        }

        return .result(dialog: "\(response)")
    }
}

// MARK: - Intent : Prochaine marée

struct GetNextTideIntent: AppIntent {
    static var title: LocalizedStringResource = "Prochaine marée"
    static var description = IntentDescription("Donne l'heure et la hauteur de la prochaine marée haute ou basse.")

    @Parameter(title: "Port")
    var port: PortEntity?

    @Parameter(title: "Type de marée", default: .any)
    var tideType: TideTypeParam

    static var parameterSummary: some ParameterSummary {
        Summary("Prochaine \(\.$tideType) à \(\.$port)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let portId = port?.id ?? selectedPortId()
        guard let portId else {
            return .result(dialog: "Aucun port sélectionné.")
        }

        let portName = port?.name ?? selectedPortName() ?? portId
        guard let tides = TideCache.shared.get(portId: portId), !tides.isEmpty else {
            return .result(dialog: "Pas de données pour \(portName). Ouvre l'app.")
        }

        let now = Date()
        let futureTides = tides.filter { $0.date > now }.sorted { $0.date < $1.date }

        let filtered: [TideData]
        switch tideType {
        case .high:
            filtered = futureTides.filter { $0.isHighTide }
        case .low:
            filtered = futureTides.filter { !$0.isHighTide }
        case .any:
            filtered = futureTides
        }

        guard let next = filtered.first else {
            return .result(dialog: "Aucune marée trouvée dans les prochains jours pour \(portName).")
        }

        let type = next.isHighTide ? "Pleine mer" : "Basse mer"
        let time = intentTime(next.date, tz: intentPortTimeZone(for: portId), weekday: true)
        let height = String(format: "%.1f", locale: Locale.current, next.height)
        var msg = "\(type) à \(portName) : \(time), \(height) m."
        if let coef = next.coefficient {
            msg += " Coefficient \(coef)."
        }

        return .result(dialog: "\(msg)")
    }
}

enum TideTypeParam: String, AppEnum {
    case any
    case high
    case low

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Type de marée")
    static var caseDisplayRepresentations: [TideTypeParam: DisplayRepresentation] = [
        .any: "Toute marée",
        .high: "Pleine mer",
        .low: "Basse mer"
    ]
}

// MARK: - Intent : Marées du jour

struct GetTidesForDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Marées du jour"
    static var description = IntentDescription("Liste toutes les marées pour une date donnée.")

    @Parameter(title: "Port")
    var port: PortEntity?

    @Parameter(title: "Date")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Marées du \(\.$date) à \(\.$port)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let portId = port?.id ?? selectedPortId()
        guard let portId else {
            return .result(dialog: "Aucun port sélectionné.")
        }

        let portName = port?.name ?? selectedPortName() ?? portId
        guard let tides = TideCache.shared.get(portId: portId), !tides.isEmpty else {
            return .result(dialog: "Pas de données pour \(portName). Ouvre l'app.")
        }

        let resolvedDate = date ?? Date()
        // Bornes de journée DANS LE FUSEAU DU PORT (sinon « marées du jour » se décale
        // d'un cran pour les DOM-TOM / ports étrangers).
        let portTZ = intentPortTimeZone(for: portId)
        let calendar = Calendar.inTimeZone(portTZ)
        let startOfDay = calendar.startOfDay(for: resolvedDate)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return .result(dialog: "Erreur de date.")
        }

        let dayTides = tides
            .filter { $0.date >= startOfDay && $0.date < endOfDay }
            .sorted { $0.date < $1.date }

        guard !dayTides.isEmpty else {
            let dateStr = resolvedDate.formatted(.dateTime.day().month(.wide))
            return .result(dialog: "Aucune marée disponible pour le \(dateStr) à \(portName).")
        }

        let dateLabel = calendar.isDateInToday(resolvedDate) ? "Aujourd'hui" :
                         calendar.isDateInTomorrow(resolvedDate) ? "Demain" :
                         resolvedDate.formatted(.dateTime.weekday(.wide).day().month(.wide))

        var lines = ["\(dateLabel) à \(portName) :"]
        for tide in dayTides {
            let type = tide.isHighTide ? "PM" : "BM"
            let time = intentTime(tide.date, tz: portTZ)
            // Unité de l'utilisateur (m/ft) via le groupe d'app — Siri annonçait toujours des mètres.
            let height = SharedUnitFormatter.height(tide.height, decimals: 1)
            let coefStr = tide.coefficient.map { " (coef \($0))" } ?? ""
            lines.append("  \(type) \(time) — \(height)\(coefStr)")
        }

        return .result(dialog: "\(lines.joined(separator: "\n"))")
    }
}

// MARK: - Helpers

private func selectedPortId() -> String? {
    UserDefaults.standard.string(forKey: "selectedPortId")
}

private func selectedPortName() -> String? {
    UserDefaults.standard.string(forKey: "selectedPortName")
}

/// Fuseau horaire du port pour les dialogues Siri. Sinon les horaires sortent dans le
/// fuseau de l'APPAREIL — faux pour les DOM-TOM, les ports étrangers (couverture mondiale)
/// ou un utilisateur en voyage.
private func intentPortTimeZone(for portId: String) -> TimeZone {
    // 1) Port français connu → fuseau dérivé des coordonnées (couvre les DOM-TOM).
    if let url = Bundle.main.url(forResource: "shom_ports", withExtension: "txt"),
       let content = try? String(contentsOf: url, encoding: .utf8) {
        for line in content.components(separatedBy: .newlines) {
            let c = line.components(separatedBy: ":")
            if c.count == 4, c[0] == portId, let lat = Double(c[2]), let lon = Double(c[3]),
               let tz = TimeZone(identifier: Port.frenchTimeZoneIdentifier(latitude: lat, longitude: lon)) {
                return tz
            }
        }
    }
    // 2) Repli : fuseau du port courant transporté pour le widget (couvre les ports étrangers).
    if let raw = WidgetSharedKeys.sharedDefaults?.data(forKey: WidgetSharedKeys.dataKey),
       let data = try? JSONDecoder().decode(WidgetSharedData.self, from: raw),
       let tzid = data.timeZoneIdentifier, let tz = TimeZone(identifier: tzid) {
        return tz
    }
    return .current
}

/// Formate une heure (HH:mm) dans le fuseau du port, option jour de semaine.
private func intentTime(_ date: Date, tz: TimeZone, weekday: Bool = false) -> String {
    let base = Date.FormatStyle(timeZone: tz)
    let style = weekday ? base.weekday(.wide).hour().minute() : base.hour().minute()
    return date.formatted(style)
}

// MARK: - App Shortcuts (phrases Siri pré-configurées)

struct TideItShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetCurrentTideIntent(),
            phrases: [
                "Marée actuelle avec \(.applicationName)",
                "Quelle est la marée avec \(.applicationName)",
                "Hauteur de marée \(.applicationName)"
            ],
            shortTitle: "Marée actuelle",
            systemImageName: "water.waves"
        )

        AppShortcut(
            intent: GetNextTideIntent(),
            phrases: [
                "Prochaine marée avec \(.applicationName)",
                "Prochaine pleine mer \(.applicationName)",
                "Quand est la prochaine marée \(.applicationName)"
            ],
            shortTitle: "Prochaine marée",
            systemImageName: "arrow.up.right.circle"
        )

        AppShortcut(
            intent: GetTidesForDayIntent(),
            phrases: [
                "Marées du jour \(.applicationName)",
                "Horaires des marées \(.applicationName)"
            ],
            shortTitle: "Marées du jour",
            systemImageName: "calendar"
        )
    }
}

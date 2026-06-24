//
//  TideItConfigurableWidget.swift
//  TideItWidget
//
//  Widget configurable : l'utilisateur choisit le port à afficher
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Configuration Intent

struct SelectPortIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choisir un port"
    static var description = IntentDescription("Sélectionnez le port à afficher dans le widget.")

    @Parameter(title: "Port")
    var port: WidgetPortEntity?
}

// MARK: - Widget Port Entity (widget-side)

struct WidgetPortEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Port")
    static var defaultQuery = WidgetPortEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WidgetPortEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetPortEntity] {
        let available = availablePorts()
        return identifiers.compactMap { id in
            guard let name = available[id] else { return nil }
            return WidgetPortEntity(id: id, name: name)
        }
    }

    func suggestedEntities() async throws -> [WidgetPortEntity] {
        availablePorts()
            .map { WidgetPortEntity(id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func defaultResult() async -> WidgetPortEntity? {
        // Port par défaut : le port sélectionné dans l'app
        guard let defaults = WidgetSharedKeys.sharedDefaults,
              let data = defaults.data(forKey: WidgetSharedKeys.dataKey),
              let shared = try? JSONDecoder().decode(WidgetSharedData.self, from: data) else {
            return nil
        }
        // Trouver l'id du port par défaut
        let available = availablePorts()
        if let match = available.first(where: { $0.value == shared.portName }) {
            return WidgetPortEntity(id: match.key, name: match.value)
        }
        return nil
    }

    private func availablePorts() -> [String: String] {
        guard let defaults = WidgetSharedKeys.sharedDefaults else { return [:] }
        return defaults.dictionary(forKey: WidgetSharedKeys.availablePortsKey) as? [String: String] ?? [:]
    }
}

extension WidgetPortEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [WidgetPortEntity] {
        let normalized = string.lowercased()
        return availablePorts()
            .filter { $0.value.lowercased().contains(normalized) }
            .map { WidgetPortEntity(id: $0.key, name: $0.value) }
    }
}

// MARK: - Configurable Timeline Provider

struct ConfigurableTideProvider: AppIntentTimelineProvider {
    typealias Entry = TideEntry
    typealias Intent = SelectPortIntent

    func placeholder(in context: Context) -> TideEntry {
        TideEntry(date: Date(), data: nil)
    }

    func snapshot(for configuration: SelectPortIntent, in context: Context) async -> TideEntry {
        TideEntry(date: Date(), data: loadData(for: configuration))
    }

    func timeline(for configuration: SelectPortIntent, in context: Context) async -> Timeline<TideEntry> {
        let rawData = loadData(for: configuration)
        let now = Date()
        var entries: [TideEntry] = []

        let intervalMinutes = 10
        let totalEntries = 48
        for i in 0..<totalEntries {
            let entryDate = Calendar.current.date(byAdding: .minute, value: i * intervalMinutes, to: now)
                ?? now.addingTimeInterval(Double(i * intervalMinutes * 60))
            let resolved: WidgetSharedData?
            if let d = rawData {
                resolved = resolvedSharedData(from: d, at: entryDate)
            } else {
                resolved = nil
            }
            entries.append(TideEntry(date: entryDate, data: resolved))
        }

        let refreshDate = Calendar.current.date(byAdding: .hour, value: 3, to: now)
            ?? now.addingTimeInterval(3 * 3600)
        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    private func loadData(for configuration: SelectPortIntent) -> WidgetSharedData? {
        guard let defaults = WidgetSharedKeys.sharedDefaults else { return nil }

        // Si un port est sélectionné, lire ses données
        if let portId = configuration.port?.id,
           let encoded = defaults.data(forKey: WidgetSharedKeys.portDataKey(portId)),
           let data = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded) {
            return data
        }

        // Fallback : données du port par défaut
        guard let encoded = defaults.data(forKey: WidgetSharedKeys.dataKey),
              let data = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded) else {
            return nil
        }
        return data
    }
}

// MARK: - Widget Configuration (iOS only)

#if os(iOS)
struct TideItConfigurableWidget: Widget {
    let kind = "TideItConfigurableWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPortIntent.self, provider: ConfigurableTideProvider()) { entry in
            TideItWidgetEntryView(entry: entry)
                .unredacted()
        }
        .configurationDisplayName("Marées (configurable)")
        .description("Choisissez le port à afficher")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
#endif

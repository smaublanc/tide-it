//
//  SurfWidget.swift
//  TideItWidget
//
//  Widget SURF dédié aux spots de surf : houle dominante (hauteur · période · direction)
//  + verdict « coup d'œil », accent ORANGE et flèche `location.north.fill` (l'asset de
//  direction distillé partout dans le mode surf). N'affiche des données QUE pour un spot
//  de surf du catalogue ; un port classique montre un état neutre (le surf est un mode à part).
//
//  Réutilise `TideProvider` (le snapshot partagé porte désormais les champs surf) et les
//  helpers GLOBAUX `formatTideTime` / `SharedUnitFormatter`. Les helpers `private` de
//  TideItWidget.swift (WT, windAccent, interpolatedHeight…) ne sont pas visibles ici → on
//  redéfinit un mini-thème orange local.
//

import SwiftUI
import WidgetKit

#if os(iOS)

// MARK: - Thème local (orange surf)

private enum SW {
    static let accent  = Color.orange
    static let text1   = Color.primary
    static let text2   = Color.secondary
    static let text3   = Color(UIColor.tertiaryLabel)
    static let high    = Color.cyan        // marée montante
    static let low     = Color.purple      // marée descendante
    static let separator = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.10)
    })
}

/// Verdict surf → libellé localisé + teinte. On NE dépend PAS du type `SurfGrade` de l'app
/// (couplage inter-cibles) : on mappe le `rawValue` brut transporté dans le snapshot.
private struct SurfVerdict {
    let label: LocalizedStringKey
    let color: Color
    let icon: String

    init(rawValue: String?) {
        switch rawValue {
        case "firing":
            label = "Ça marche"; color = Color(red: 1.0, green: 0.52, blue: 0.0); icon = "flame.fill"
        case "clean":
            label = "Surfable"; color = .orange; icon = "checkmark.seal.fill"
        case "oversized":
            label = "Trop gros"; color = Color(red: 0.92, green: 0.26, blue: 0.21); icon = "exclamationmark.triangle.fill"
        case "flat":
            label = "Flat"; color = SW.text2; icon = "minus"
        default:
            label = "Données indisponibles"; color = SW.text3; icon = "questionmark"
        }
    }
}

// MARK: - Entry View (routeur)

struct SurfWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TideEntry

    var body: some View {
        Group {
            if let data = entry.data, data.isSurfSpot == true, data.surfSwellHeightM != nil {
                switch family {
                case .systemMedium: MediumSurfView(data: data)
                default:            SmallSurfView(data: data)
                }
            } else {
                SurfEmptyView(isSurfSpot: entry.data?.isSurfSpot == true,
                              portName: entry.data?.portName)
            }
        }
    }
}

// MARK: - Petit format

struct SmallSurfView: View {
    let data: WidgetSharedData

    var body: some View {
        let height = data.surfSwellHeightM ?? 0
        let period = data.surfSwellPeriodS
        let dir = data.surfSwellDirectionDeg
        let verdict = SurfVerdict(rawValue: data.surfGradeRaw)

        VStack(alignment: .leading, spacing: 0) {
            // En-tête : nom du spot
            HStack(spacing: 4) {
                Image(systemName: "water.waves").font(.system(size: 8, weight: .bold)).foregroundStyle(SW.accent)
                Text(data.portName)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(SW.text3).lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 3)

            // Houle dominante (valeur dominante)
            Text(SharedUnitFormatter.height(height))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(SW.text1).lineLimit(1).minimumScaleFactor(0.7)

            // Période + direction
            HStack(spacing: 6) {
                if let p = period {
                    Text("\(Int(p.rounded())) s")
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(SW.accent)
                }
                if let d = dir {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(SW.accent)
                        .rotationEffect(.degrees(d + 180))
                    Text(SharedUnitFormatter.windCardinal(d))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(SW.text2)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 5)
            Rectangle().fill(SW.separator).frame(height: 1)
            Spacer(minLength: 5)

            // Verdict
            HStack(spacing: 4) {
                Image(systemName: verdict.icon).font(.system(size: 9, weight: .bold)).foregroundStyle(verdict.color)
                Text(verdict.label)
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(verdict.color)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
    }
}

// MARK: - Format moyen (houle à gauche, marée à droite)

struct MediumSurfView: View {
    let data: WidgetSharedData

    var body: some View {
        let height = data.surfSwellHeightM ?? 0
        let period = data.surfSwellPeriodS
        let dir = data.surfSwellDirectionDeg
        let verdict = SurfVerdict(rawValue: data.surfGradeRaw)
        let isRising = data.nextTideIsHigh

        HStack(spacing: 0) {
            // ─── Houle (gauche) ───
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "water.waves").font(.system(size: 8, weight: .bold)).foregroundStyle(SW.accent)
                    Text(data.portName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(SW.text3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 4)
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle().fill(SW.accent.opacity(0.15)).frame(width: 46, height: 46)
                        if let d = dir {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 20, weight: .heavy))
                                .foregroundStyle(SW.accent)
                                .rotationEffect(.degrees(d + 180))
                        } else {
                            Image(systemName: "water.waves")
                                .font(.system(size: 18, weight: .heavy)).foregroundStyle(SW.accent)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SharedUnitFormatter.height(height))
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(SW.text1).lineLimit(1).minimumScaleFactor(0.7)
                        if let p = period {
                            Text("\(Int(p.rounded())) s" + (dir.map { " · " + SharedUnitFormatter.windCardinal($0) } ?? ""))
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(SW.accent)
                        }
                    }
                }
                Spacer(minLength: 4)
                // Verdict
                HStack(spacing: 4) {
                    Image(systemName: verdict.icon).font(.system(size: 9, weight: .bold)).foregroundStyle(verdict.color)
                    Text(verdict.label)
                        .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(verdict.color)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(verdict.color.opacity(0.15)))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(SW.separator).frame(width: 1).padding(.vertical, 4)

            // ─── Marée (droite) — le surf est marée-dépendant ───
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "water.waves").font(.system(size: 8, weight: .bold)).foregroundStyle(SW.high)
                    Text("Marée").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(SW.text3)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 4)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: isRising ? "arrow.up" : "arrow.down")
                        .font(.system(size: 18, weight: .heavy)).foregroundStyle(isRising ? SW.high : SW.low)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SharedUnitFormatter.height(data.nextTideHeight))
                            .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(SW.text1)
                        Text(isRising ? "Montante" : "Descendante")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(isRising ? SW.high : SW.low)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: data.nextTideIsHigh ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(isRising ? SW.high : SW.low)
                    Text(data.nextTideIsHigh ? "PM" : "BM")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(isRising ? SW.high : SW.low)
                    Text(formatTideTime(data.nextTideDate, in: data.timeZone))
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(SW.text1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetAccentable()
        .widgetURL(URL(string: "tideit://open"))
    }
}

// MARK: - État vide (port classique OU pas de donnée de houle)

struct SurfEmptyView: View {
    let isSurfSpot: Bool
    let portName: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "water.waves")
                .font(.system(size: 24)).foregroundStyle(SW.accent.opacity(0.6))
            Text(isSurfSpot ? "Données de houle indisponibles" : "Choisis un spot de surf")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(SW.text2).multilineTextAlignment(.center)
            if let portName, !portName.isEmpty {
                Text(portName).font(.system(size: 9, weight: .medium)).foregroundStyle(SW.text3).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(Color("WidgetBackground")) }
        .widgetURL(URL(string: "tideit://open"))
    }
}

// MARK: - Provider SURF (collant)

/// Le widget surf est « collant » sur ton spot : si le port ACTIF est un spot de surf, il l'affiche ;
/// sinon il retombe sur le DERNIER spot de surf visité (snapshot dédié) → il reste utile même quand
/// tu consultes les marées d'un port classique. Vide seulement si aucun spot n'a jamais été ouvert.
struct SurfProvider: TimelineProvider {
    func placeholder(in context: Context) -> TideEntry { TideEntry(date: Date(), data: nil) }

    func getSnapshot(in context: Context, completion: @escaping (TideEntry) -> Void) {
        completion(TideEntry(date: Date(), data: loadSurfSource()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TideEntry>) -> Void) {
        let raw = loadSurfSource()
        let now = Date()
        var entries: [TideEntry] = []
        for i in 0..<48 {
            let entryDate = Calendar.current.date(byAdding: .minute, value: i * 10, to: now)
                ?? now.addingTimeInterval(Double(i * 600))
            entries.append(TideEntry(date: entryDate, data: raw.map { resolvedSharedData(from: $0, at: entryDate) }))
        }
        let refreshDate = Calendar.current.date(byAdding: .hour, value: 3, to: now) ?? now.addingTimeInterval(3 * 3600)
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    private func loadSurfSource() -> WidgetSharedData? {
        guard let defaults = WidgetSharedKeys.sharedDefaults else { return nil }
        // 1. Port actif = spot de surf → on l'affiche.
        if let d = defaults.data(forKey: WidgetSharedKeys.dataKey),
           let main = try? JSONDecoder().decode(WidgetSharedData.self, from: d),
           main.isSurfSpot == true {
            return main
        }
        // 2. Sinon : dernier spot de surf visité.
        if let d = defaults.data(forKey: WidgetSharedKeys.lastSurfDataKey),
           let last = try? JSONDecoder().decode(WidgetSharedData.self, from: d) {
            return last
        }
        return nil
    }
}

// MARK: - Déclaration du widget

struct SurfWidget: Widget {
    let kind = "SurfWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SurfProvider()) { entry in
            SurfWidgetEntryView(entry: entry).unredacted()
        }
        .configurationDisplayName("Surf")
        .description("Houle dominante et verdict de ton spot de surf (reste sur ton dernier spot)")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

#endif // os(iOS)

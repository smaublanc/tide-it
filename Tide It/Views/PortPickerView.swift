//
//  PortPickerView.swift
//  Tide It
//
//  Sélecteur de port avec recherche — supporte les ports mondiaux (SHOM, NOAA, TICON)
//

import SwiftUI
import CoreLocation

struct PortPickerView: View {
    @ObservedObject var tideService: TideService
    @ObservedObject private var surfCatalog = SurfSpotCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedFilter: FilterOption = .all

    // Index de recherche pré-calculé UNE fois (nom+pays normalisés) — évite de
    // refaire `.folding` sur 3861 chaînes à chaque frappe. Trié par nom au build
    // pour que le résultat filtré soit déjà ordonné (pas de `.sorted` par frappe).
    @State private var searchIndex: [PortSearchEntry] = []
    // Liste de ports déjà triée alphabétiquement — sert au chemin « sans recherche »
    // pour éviter de re-trier 3861 ports à chaque rendu.
    @State private var sortedPorts: [Port] = []
    // Comptes par catégorie pré-calculés UNE fois — évite de filtrer 3861 ports
    // × 6 pills à chaque rendu (~23k ops/frame).
    @State private var counts = FilterCounts()

    struct PortSearchEntry {
        let port: Port
        let haystack: String   // "nom pays" en minuscules sans accents
    }

    struct FilterCounts {
        var all = 0, favorites = 0, nearby = 0, france = 0, usa = 0, world = 0
    }

    enum FilterOption: String, CaseIterable {
        case all = "Tous"
        case favorites = "Favoris"
        case nearby = "À proximité"
        case france = "France"
        case usa = "USA"
        case world = "Monde"
        case surf = "Surf"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                searchBar

                // Filter pills
                filterPills

                // Port list
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if selectedFilter == .surf {
                            // Section SURF : spots du catalogue (≠ ports), triés par distance, couleur orange.
                            surfSpotList
                        } else if searchText.isEmpty && selectedFilter == .all {
                            // Vue groupée par région quand aucun filtre
                            groupedPortList
                        } else {
                            // Vue plate en mode recherche/filtre
                            flatPortList
                        }
                    }
                    .padding(.horizontal, DS.spacingLG)
                    .padding(.top, DS.spacingSM)
                    .padding(.bottom, 100)
                }
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .navigationTitle("Sélectionner un port")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if searchIndex.isEmpty { buildIndexAndCounts() }
            }
        }
    }

    /// Construit l'index de recherche et les comptes une seule fois.
    private func buildIndexAndCounts() {
        // Tri alphabétique payé UNE seule fois ici (et non à chaque frappe / rendu).
        let ports = tideService.ports.sorted { $0.name < $1.name }
        sortedPorts = ports
        searchIndex = ports.map { port in
            let haystack = (port.name + " " + port.country)
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
            return PortSearchEntry(port: port, haystack: haystack)
        }
        counts = FilterCounts(
            all: ports.count,
            favorites: ports.filter(\.isFavorite).count,
            nearby: min(30, ports.count),
            france: ports.filter { $0.source == .shom }.count,
            usa: ports.filter { $0.source == .noaa }.count,
            world: ports.filter { $0.source == .ticon }.count
        )
    }

    // MARK: - Grouped Port List (par région)
    // Chaque région pousse un écran dédié (LazyVStack) plutôt que de tout
    // matérialiser dans un DisclosureGroup — qui n'est PAS lazy et instancierait
    // d'un coup les 2000+ PortRow → freeze main thread → crash watchdog.
    private var groupedPortList: some View {
        // Comptes pré-calculés (counts) → pas de Dictionary(grouping:) par rendu.
        VStack(spacing: 0) {
            if counts.france > 0 {
                regionNavLink(title: "France", icon: "flag.fill", iconColor: .cyan, count: counts.france, source: .shom)
            }
            if counts.usa > 0 {
                OpenRowDivider(leadingInset: 40)
                regionNavLink(title: "États-Unis", icon: "globe.americas.fill", iconColor: .blue, count: counts.usa, source: .noaa)
            }
            if counts.world > 0 {
                OpenRowDivider(leadingInset: 40)
                regionNavLink(title: "Monde", icon: "globe", iconColor: .purple, count: counts.world, source: .ticon)
            }
        }
    }

    /// Ligne de navigation vers la liste filtrée d'une région.
    private func regionNavLink(title: String, icon: String, iconColor: Color, count: Int, source: PortSource) -> some View {
        NavigationLink {
            PortRegionListView(
                title: title,
                source: source,
                tideService: tideService,
                onSelect: selectPort
            )
        } label: {
            HStack(spacing: DS.spacingMD) {
                Image(systemName: icon)
                    .font(.scaled(size: DS.fontHeadline))
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                Text(title)
                    .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(count)")
                    .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.glassHighlight.opacity(0.1)))

                Image(systemName: "chevron.right")
                    .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // Dé-cadré : ligne de navigation ouverte.
            .padding(.vertical, DS.spacingMD + 2)
            .padding(.horizontal, DS.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Flat Port List (lignes ouvertes + filets)
    @ViewBuilder
    private var flatPortList: some View {
        let ports = filteredPorts
        ForEach(Array(ports.enumerated()), id: \.element.id) { i, port in
            PortRow(
                port: port,
                userLocation: tideService.userLocation,
                isSelected: tideService.selectedPort?.id == port.id
            ) {
                selectPort(port)
            }
            if i < ports.count - 1 { OpenRowDivider(leadingInset: 38) }
        }
    }

    // MARK: - Surf Spot List (catalogue surf, trié distance, couleur map)
    @ViewBuilder
    private var surfSpotList: some View {
        let spots = sortedSurfSpots
        ForEach(Array(spots.enumerated()), id: \.element.id) { i, spot in
            SurfSpotRow(spot: spot, userLocation: tideService.userLocation) {
                // Matérialise + configure (source unique, partagée avec la carte) → sélectionne.
                if let port = SurfSpotCatalog.shared.materializeAndConfigure(spot.id, tideService: tideService) {
                    selectPort(port)
                }
            }
            if i < spots.count - 1 { OpenRowDivider(leadingInset: 38) }
        }
    }

    /// Spots du catalogue, filtrés par la recherche, triés par distance à l'utilisateur (sinon par nom).
    private var sortedSurfSpots: [SurfSpot] {
        var spots = surfCatalog.spots
        let needle = searchText.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        if !needle.isEmpty {
            spots = spots.filter {
                ($0.name + " " + $0.country + " " + ($0.region ?? "")).lowercased()
                    .folding(options: .diacriticInsensitive, locale: .current).contains(needle)
            }
        }
        guard let loc = tideService.userLocation else { return spots }   // déjà triés par nom
        return spots.sorted {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc)
                < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: loc)
        }
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: "magnifyingglass")
                .font(.scaled(size: DS.fontHeadline))
                .foregroundStyle(.gray)

            TextField("Rechercher un port...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.scaled(size: DS.fontHeadline))
                .foregroundStyle(.primary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.scaled(size: DS.fontHeadline))
                        .foregroundStyle(.gray)
                }
                .accessibilityLabel("Effacer la recherche")
            }
        }
        // Champ de recherche : capsule subtile sans cadre (l'affordance reste lisible).
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Capsule().fill(Color.glassHighlight.opacity(0.07)))
        .padding(.horizontal, DS.spacingLG)
        .padding(.top, DS.spacingSM)
    }

    // MARK: - Filter Pills
    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilterOption.allCases, id: \.self) { option in
                    FilterPill(
                        title: option.rawValue,
                        isSelected: selectedFilter == option,
                        count: countForFilter(option)
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedFilter = option
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Computed Properties
    private var filteredPorts: [Port] {
        // 1) Si recherche active : partir de l'index pré-normalisé (rapide).
        var ports: [Port]
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
            ports = searchIndex.lazy.filter { $0.haystack.contains(needle) }.map(\.port)
        } else {
            ports = sortedPorts
        }

        // 2) Filtre catégorie
        switch selectedFilter {
        case .all:
            break
        case .favorites:
            ports = ports.filter { $0.isFavorite }
        case .nearby:
            if let location = tideService.userLocation {
                ports = ports.sorted { $0.distance(to: location) < $1.distance(to: location) }
                ports = Array(ports.prefix(30))
            }
        case .france:
            ports = ports.filter { $0.source == .shom }
        case .usa:
            ports = ports.filter { $0.source == .noaa }
        case .world:
            ports = ports.filter { $0.source == .ticon }
        case .surf:
            ports = []   // la section Surf utilise surfSpotList (catalogue), pas la liste de ports
        }

        // 3) Le tri est déjà fait : searchIndex / sortedPorts sont ordonnés par nom au
        //    build, les filtres catégorie préservent l'ordre, et « à proximité » a son
        //    propre tri par distance ci-dessus. Plus de `.sorted` par frappe / rendu.
        return ports
    }

    private func countForFilter(_ option: FilterOption) -> Int {
        switch option {
        case .all:       return counts.all
        case .favorites: return counts.favorites
        case .nearby:    return counts.nearby
        case .france:    return counts.france
        case .usa:       return counts.usa
        case .world:     return counts.world
        case .surf:      return surfCatalog.spots.count
        }
    }

    private func selectPort(_ port: Port) {
        tideService.selectedPort = port
        Task {
            await tideService.fetchTideData()
        }
        dismiss()
    }
}

// MARK: - Filter Pill
struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))

                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.glassHighlight.opacity(0.2) : Color.glassHighlight.opacity(0.1))
                    )
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        isSelected ?
                        AnyShapeStyle(
                            LinearGradient(
                                colors: [.cyan.opacity(0.3), .blue.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        ) :
                        AnyShapeStyle(Color.glassHighlight.opacity(0.05))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color.cyan.opacity(0.3) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Port Region List (écran dédié par région, rendu lazy)
private struct PortRegionListView: View {
    let title: String
    let source: PortSource
    @ObservedObject var tideService: TideService
    let onSelect: (Port) -> Void

    @State private var ports: [Port] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(ports.enumerated()), id: \.element.id) { i, port in
                    PortRow(
                        port: port,
                        userLocation: tideService.userLocation,
                        isSelected: tideService.selectedPort?.id == port.id
                    ) {
                        onSelect(port)
                    }
                    if i < ports.count - 1 { OpenRowDivider(leadingInset: 38) }
                }
            }
            .padding(.horizontal, DS.spacingLG)
            .padding(.top, DS.spacingSM)
            .padding(.bottom, 100)
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Tri hors du body : évite de re-trier 2000+ ports à chaque rendu.
            if ports.isEmpty {
                let filtered = tideService.ports.filter { $0.source == source }
                ports = filtered.sorted { $0.name < $1.name }
            }
        }
    }
}

// MARK: - Port Row
struct PortRow: View {
    let port: Port
    let userLocation: CLLocation?
    let isSelected: Bool
    let onSelect: () -> Void

    /// Icône de la source du port
    private var sourceIcon: String {
        switch port.source {
        case .shom:  return "flag.fill"
        case .noaa:  return "globe.americas.fill"
        case .ticon: return "globe"
        }
    }

    private var sourceColor: Color {
        switch port.source {
        case .shom:  return .cyan
        case .noaa:  return .blue
        case .ticon: return .purple
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.spacingMD + 2) {
                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? Color.tideHigh : Color.glassHighlight.opacity(0.2),
                            lineWidth: 2
                        )
                        .frame(width: 22, height: 22)

                    if isSelected {
                        Circle()
                            .fill(Color.tideHigh)
                            .frame(width: 12, height: 12)
                    }
                }

                VStack(alignment: .leading, spacing: DS.spacingXS) {
                    HStack(spacing: DS.spacingXS) {
                        Text(port.name)
                            .font(.scaled(size: DS.fontHeadline, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if port.source != .shom {
                            Image(systemName: sourceIcon)
                                .font(.system(size: 10))
                                .foregroundStyle(sourceColor)
                        }
                    }

                    HStack(spacing: DS.spacingSM) {
                        if let location = userLocation {
                            Text(port.formattedDistance(to: location))
                                .font(.scaled(size: DS.fontSubheadline))
                                .foregroundStyle(.gray)
                        }

                        if port.source != .shom {
                            Text(port.country)
                                .font(.scaled(size: DS.fontCaption))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if port.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.scaled(size: DS.fontCallout))
                        .foregroundStyle(.yellow)
                }

                if port.isCustom {
                    Image(systemName: "pin.fill")
                        .font(.scaled(size: DS.fontCallout))
                        .foregroundStyle(Color.tideLow)
                }
            }
            // Dé-cadré : ligne ouverte, sélection = teinte + barre d'accent (pattern Favoris).
            .padding(.vertical, DS.spacingMD)
            .padding(.horizontal, DS.spacingXS)
            .background(isSelected ? Color.tideHigh.opacity(0.06) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(Color.tideHigh).frame(width: 3, height: 30)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(port.name)\(isSelected ? ", sélectionné" : "")\(port.isFavorite ? ", favori" : "")")
    }
}

// MARK: - Surf Spot Row (catalogue surf : pastille orange = code couleur de la carte)
struct SurfSpotRow: View {
    let spot: SurfSpot
    let userLocation: CLLocation?
    let onSelect: () -> Void

    /// Orange = couleur de TYPE « surf » de la carte (cf. MapPillStyle.surf).
    private static let surf = Color(red: 0.98, green: 0.58, blue: 0.18)

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.spacingMD + 2) {
                Image(systemName: "water.waves")
                    .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                    .foregroundStyle(Self.surf)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: DS.spacingXS) {
                    Text(spot.name)
                        .font(.scaled(size: DS.fontHeadline, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text([spot.region ?? "", spot.country].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.scaled(size: DS.fontSubheadline))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let loc = userLocation {
                    Text(distanceLabel(to: loc))
                        .font(.scaled(size: DS.fontSubheadline))
                        .foregroundStyle(.gray)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, DS.spacingMD)
            .padding(.horizontal, DS.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spot de surf \(spot.name), \(spot.country)")
    }

    private func distanceLabel(to loc: CLLocation) -> String {
        let km = CLLocation(latitude: spot.latitude, longitude: spot.longitude).distance(from: loc) / 1000
        return km < 1 ? "< 1 km" : String(format: "%.0f km", km)
    }
}

#Preview {
    PortPickerView(tideService: TideService())
}

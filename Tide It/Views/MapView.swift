//
//  MapView.swift
//  Tide It
//
//  Vue carte ultra-fluide avec clustering adaptatif et chargement viewport-only
//

import SwiftUI
import MapKit
import UIKit

// MARK: - MapView

struct MapView: View {
    @ObservedObject var tideService: TideService
    @ObservedObject var locationManager: LocationManager
    @ObservedObject private var windAggregator = WindStationAggregator.shared
    @ObservedObject private var surfCatalog = SurfSpotCatalog.shared
    @ObservedObject private var premium = PremiumManager.shared
    @Binding var selectedTab: ContentView.AppTab
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedMapPort: Port?
    @State private var cardAppeared = false
    @State private var portTideCache: [String: [TideData]] = [:]
    @State private var isLoadingMapData = false
    @State private var loadTask: Task<Void, Never>?
    @State private var pendingRecenter = false
    @State private var selectPortTask: Task<Void, Never>?
    @State private var portLoadTasks: [String: Task<Void, Never>] = [:]

    // Recherche (remplace le titre du header)
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// Index de recherche pré-normalisé (nom plié une fois) — évite de faire `.folding`
    /// sur ~3861 noms à chaque frappe. Construit une fois à l'apparition.
    @State private var searchIndex: [(haystack: String, port: Port)] = []
    /// Ports mondiaux dédoublonnés (<5 km) pour l'AFFICHAGE — calculé en arrière-plan.
    /// nil = pas encore prêt → seuls les essentiels (favoris/custom/sélection) s'affichent.
    /// Tous les ports restent disponibles dans la recherche.
    @State private var dedupedDisplayIDs: Set<String>?

    /// Ports passés à la carte : sous-ensemble dédoublonné (le zoom fait le reste côté MapKit).
    /// On EXCLUT les ports qui sont en réalité des SPOTS DE SURF (id présent au catalogue) : un spot
    /// de surf reste TOUJOURS une pastille orange, même une fois matérialisé en port pour la marée.
    /// → l'identité « surf » ne dépend JAMAIS de l'existence d'une ligne Port.
    private var mapPorts: [Port] {
        let selectedID = selectedMapPort?.id ?? tideService.selectedPort?.id
        let isSurfSpotID: (String) -> Bool = { surfCatalog.spot(id: $0) != nil }
        guard let ids = dedupedDisplayIDs else {
            return tideService.ports.filter { ($0.isFavorite || $0.isCustom || $0.id == selectedID) && !isSurfSpotID($0.id) }
        }
        return tideService.ports.filter { (ids.contains($0.id) || $0.id == selectedID) && !isSurfSpotID($0.id) }
    }

    /// Spots de surf passés à la carte : réservés au premium (surf = fonction payante).
    /// Vide pour les non-premium → la carte reste strictement identique à avant. Un spot reste dans
    /// CETTE couche même après matérialisation en port (cf. mapPorts qui l'exclut) → tap ≠ changement
    /// d'identité : la pastille reste orange « hauteur · période ».
    private var mapSurfSpots: [SurfSpot] {
        guard premium.isPremium else { return [] }
        return surfCatalog.spots
    }

    /// Tap sur une pastille de spot de surf → le matérialise en port custom (rattaché au port de
    /// référence le plus proche) + écrit sa config surf (orientation/break) + l'ouvre comme un port.
    private func launchSurfSpot(_ spotID: String) {
        // Matérialisation + config = SOURCE UNIQUE (partagée avec le picker, cf. SurfSpotCatalog).
        guard let port = surfCatalog.materializeAndConfigure(spotID, tideService: tideService) else { return }
        selectedMapPort = port
        pendingMapRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        )
    }
    @State private var portRisingStates: [String: Bool] = [:]
    /// Hauteur d'eau instantanée par port (m, repère chart datum) — alimentée en même temps
    /// que le sens de marée pour les ports dont on a chargé les marées (favoris + visités).
    /// Affichée sur la pastille (« Brest ↑ 4.2 m »). Absente ⇒ pastille = nom seul.
    @State private var portTideHeights: [String: Double] = [:]
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var pendingMapRegion: MKCoordinateRegion?
    @State private var newSpotPoint: MapPoint?
    @State private var showFavoritesManager = false

    /// Schéma effectif de l'app (MapKit n'hérite pas du thème → on lui impose).
    private var mapScheme: ColorScheme { themeManager.appearance.colorScheme ?? colorScheme }

    /// Fond rond verre commun aux boutons flottants de la carte.
    private var mapGlassCircle: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().stroke(
                LinearGradient(colors: [Color.glassHighlight.opacity(0.3), Color.glassHighlight.opacity(0.1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.5)
        }
    }

    /// Menu d'accès rapide aux favoris : gestionnaire (ports & spots) + saut direct sur chacun.
    private var favoritesQuickMenu: some View {
        // TOUT ce qui est sauvegardé : ports intégrés favoris + spots PERSO + spots SURF (= les 3
        // onglets du gestionnaire). `isFavorite || isCustom` → on ne rate plus les spots custom non
        // explicitement « favoris ». Classés du plus PROCHE au plus loin ; repli alphabétique.
        let favs: [Port] = {
            let list = tideService.ports.filter { $0.isFavorite || $0.isCustom }
            guard let here = tideService.userLocation else {
                return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            return list.sorted {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: here)
                    < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: here)
            }
        }()
        return Menu {
            Button {
                HapticManager.shared.impact(.light)
                showFavoritesManager = true
            } label: { Label("Gestionnaire de favoris", systemImage: "slider.horizontal.3") }

            if !favs.isEmpty {
                Divider()
                ForEach(favs) { port in
                    Button {
                        HapticManager.shared.impact(.light)
                        jumpToPort(port)
                    } label: {
                        // Icône monochrome PAR TYPE : spot de surf = vague, port perso = pin plein,
                        // port intégré = pin cerclé.
                        Label(port.name, systemImage:
                                SurfSpotCatalog.shared.spot(id: port.id) != nil ? "water.waves"
                                : (port.isCustom ? "mappin.and.ellipse" : "mappin.circle"))
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.tideHigh)
                .frame(width: 44, height: 44)
                .background(mapGlassCircle)
                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        .accessibilityLabel("Favoris")
    }

    /// Centre initial de la carte (port sélectionné → position user → centre FR).
    private var initialMapCenter: CLLocationCoordinate2D {
        if let p = tideService.selectedPort {
            return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        }
        if let loc = tideService.userLocation {
            return loc.coordinate
        }
        return CLLocationCoordinate2D(latitude: 46.5, longitude: -2.5)
    }

    /// La carte a peint sa PREMIÈRE image (tuiles rendues) — ou a échoué à charger ses tuiles
    /// (hors-ligne : on n'affiche pas une barre qui tournerait sans fin). Piloté par MapKit.
    @State private var mapDidRender = false
    /// Le premier rendu traîne au-delà du délai anti-flash → on le SIGNALE. Filet de sécurité :
    /// si un rendu lent revenait un jour (tuiles réseau, régression), l'utilisateur voit une barre
    /// de chargement au lieu d'un écran figé — au lieu de croire l'app plantée.
    @State private var mapRenderIsSlow = false
    /// Délai avant de considérer le premier rendu comme « lent » (évite un flash de barre sur
    /// une carte qui s'affiche instantanément — le cas normal).
    private static let mapRenderSlowAfter: Duration = .milliseconds(400)

    /// Vrai dès qu'un fetch de données de port est en cours (préchargement des favoris, tap sur un
    /// port, ou fetch du port sélectionné) OU si la carte tarde à peindre sa première image
    /// → pilote la barre de chargement en haut de la carte.
    private var isMapBusy: Bool {
        isLoadingMapData || tideService.isLoading || (mapRenderIsSlow && !mapDidRender)
    }

    var body: some View {
        ZStack {
            TintedMapRepresentable(
                ports: mapPorts,
                windStations: windAggregator.allStations,
                surfSpots: mapSurfSpots,
                selectedPortID: Binding(
                    get: { selectedMapPort?.id },
                    set: { id in selectedMapPort = id.flatMap { pid in tideService.ports.first { $0.id == pid } } }
                ),
                risingStates: portRisingStates,
                heights: portTideHeights,
                scheme: mapScheme,
                initialCenter: initialMapCenter,
                pendingRegion: $pendingMapRegion,
                onLongPress: { coord in newSpotPoint = MapPoint(coordinate: coord) },
                onSelectSurfSpot: { spotID in launchSurfSpot(spotID) },
                onFirstRender: { mapDidRender = true }
            )
            .ignoresSafeArea()

            // Voile sur-brand (haut + bas) + atmosphère glow cyan/violet : relie à la DA Today.
            // ⚠️ FRÈRE du représentable dans le ZStack (et NON un `.overlay` posé dessus) :
            // un `.overlay` SwiftUI sur un `UIViewRepresentable` (MKMapView) provoque le
            // reparenting « _UIReparentingView … UIHostingController » à répétition pendant
            // l'usage de la carte. Empilé ici, le rendu est identique sans ce souci.
            let scrim = mapScheme == .dark ? Color.black : Color.white
            ZStack {
                LinearGradient(
                    colors: [scrim.opacity(0.35), .clear, .clear, scrim.opacity(0.5)],
                    startPoint: .top, endPoint: .bottom
                )
                RadialGradient(colors: [Color.tideHigh.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.5, y: 0.1), startRadius: 0, endRadius: 340)
                    .blendMode(.screen)
                RadialGradient(colors: [Color.tideLow.opacity(0.08), .clear],
                               center: UnitPoint(x: 0.5, y: 1.0), startRadius: 0, endRadius: 300)
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()

            VStack {
                headerOverlay
                // Barre de chargement (récupération des données de port) — déclenchée DIRECTEMENT
                // dès le début du fetch. Sibling du représentable (jamais un .overlay) → pas de
                // reparenting MapKit (cf. note plus haut).
                if isMapBusy {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.tideHigh)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DS.pagePadding)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
                Spacer()

                if let port = selectedMapPort ?? tideService.selectedPort,
                   let currentPort = tideService.ports.first(where: { $0.id == port.id }) {
                    // SOURCE UNIQUE pour le port sélectionné dans l'app : marées LIVE (tideService.tideData),
                    // jamais une copie parallèle qui pourrait diverger. portTideCache ne sert qu'aux AUTRES
                    // ports tapés sur la carte.
                    let portData = (currentPort.id == tideService.selectedPort?.id && !tideService.tideData.isEmpty)
                        ? tideService.tideData
                        : (portTideCache[currentPort.id] ?? [])
                    EnhancedPortInfoCard(
                        port: currentPort,
                        tideData: portData,
                        isLoading: isLoadingMapData && portData.isEmpty,
                        userLocation: tideService.userLocation,
                        onSelect: { selectPort(currentPort) },
                        onDirections: { openInMaps(port: currentPort) },
                        onToggleFavorite: { tideService.toggleFavorite(port: currentPort) },
                        isSurfSpot: surfCatalog.spot(id: currentPort.id) != nil
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .bottom)),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                    .onAppear {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            cardAppeared = true
                        }
                    }
                    .onDisappear { cardAppeared = false }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(.easeInOut(duration: 0.25), value: isMapBusy)
        }
        .onChange(of: selectedMapPort) { _, newPort in
            // Le recentrage à la sélection est géré dans la carte (didSelect) ; ici on
            // ne fait que charger les marées du port.
            if let port = newPort {
                loadPortTideData(port)
            }
        }
        // Sélection EXTERNE du port (autre vue, favori, géoloc, barre du bas) pendant que la
        // carte est déjà affichée → on recadre dessus (makeUIView ne s'exécute qu'à la 1ʳᵉ
        // apparition, d'où l'absence de recentrage auparavant).
        .onChange(of: tideService.selectedPort) { _, newPort in
            guard let port = newPort, port.id != selectedMapPort?.id else { return }
            selectedMapPort = port
            pendingMapRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
            )
        }
        // Dédoublonnage d'affichage (<5 km) calculé EN ARRIÈRE-PLAN (« fais-le en back »).
        .task(id: tideService.ports.count) {
            let ports = tideService.ports
            let ids = await Task.detached(priority: .utility) {
                MapView.computeDisplayIDs(ports: ports)
            }.value
            dedupedDisplayIDs = ids
        }
        .onAppear {
            setupInitialPosition()
            buildSearchIndex()
            seedCurrentPortData()
            loadPriorityPortsData()
            // Filet de sécurité « écran figé » : si la carte n'a pas peint sa 1ʳᵉ image au bout du
            // délai anti-flash, la barre de chargement le dit. MapKit coupe le signal dès le
            // premier rendu terminé — ou dès l'échec des tuiles (hors-ligne), pour ne jamais
            // laisser tourner une barre sans fin.
            Task {
                try? await Task.sleep(for: Self.mapRenderSlowAfter)
                if !mapDidRender { mapRenderIsSlow = true }
            }
            // Charger les stations de vent (Pioupiou + METAR) pour les badges moulin
            Task {
                let centerCoord = tideService.selectedPort.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                } ?? CLLocationCoordinate2D(latitude: 46.5, longitude: 2.0)  // centre FR par défaut
                await windAggregator.refresh(around: centerCoord)
            }
        }
        .onDisappear {
            loadTask?.cancel()
            selectPortTask?.cancel()
            portLoadTasks.values.forEach { $0.cancel() }
            portLoadTasks.removeAll()
        }
        .onChange(of: tideService.userLocation) { _, newLocation in
            guard pendingRecenter, let location = newLocation else { return }
            pendingRecenter = false
            pendingMapRegion = MKCoordinateRegion(center: location.coordinate,
                                                  span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
        }
        .sheet(item: $newSpotPoint) { point in
            SpotEditorView(tideService: tideService, initialCoordinate: point.coordinate) { created in
                selectedMapPort = created
            }
            .presentationDetents([.large])
            .sheetBackground()
        }
        .sheet(isPresented: $showFavoritesManager) {
            FavoritesView(tideService: tideService, selectedTab: $selectedTab)
                .sheetBackground()
        }
    }

    // MARK: - Dédoublonnage d'affichage (grille spatiale, O(n))

    /// Sous-ensemble de ports à AFFICHER : les ports mondiaux (NOAA/TICON) situés à
    /// moins de ~5 km d'un port déjà retenu sont masqués (doublettes). Priorité de
    /// rétention : custom/favoris > SHOM > NOAA > TICON. Pure → exécutée off-main.
    nonisolated static func computeDisplayIDs(ports: [Port]) -> Set<String> {
        func priority(_ p: Port) -> Int {
            if p.isCustom || p.isFavorite { return 0 }
            switch p.source {
            case .shom:  return 1
            case .noaa:  return 2
            case .ticon: return 3
            }
        }
        let sorted = ports.sorted { priority($0) < priority($1) }

        // Grille ~5,5 km (0,05° lat / 0,07° lon) → recherche de voisins en O(1).
        var grid: [Int64: [(lat: Double, lon: Double)]] = [:]
        func cellOf(lat: Double, lon: Double) -> (Int64, Int64) {
            (Int64((lat + 90) / 0.05), Int64((lon + 180) / 0.07))
        }
        func key(_ cy: Int64, _ cx: Int64) -> Int64 { cy &* 100_000 &+ cx }

        var keptIDs = Set<String>()
        keptIDs.reserveCapacity(ports.count)
        for p in sorted {
            var isDuplicate = false
            if priority(p) >= 2 {   // seuls les mondiaux se font dédupliquer
                let (cy, cx) = cellOf(lat: p.latitude, lon: p.longitude)
                let cosLat = cos(p.latitude * .pi / 180)
                outer: for dy in Int64(-1)...1 {
                    for dx in Int64(-1)...1 {
                        for q in grid[key(cy + dy, cx + dx)] ?? [] {
                            let dLat = (q.lat - p.latitude) * 111_000
                            let dLon = (q.lon - p.longitude) * 111_000 * cosLat
                            if dLat * dLat + dLon * dLon < 5_000 * 5_000 {
                                isDuplicate = true
                                break outer
                            }
                        }
                    }
                }
            }
            guard !isDuplicate else { continue }
            keptIDs.insert(p.id)
            let (cy, cx) = cellOf(lat: p.latitude, lon: p.longitude)
            grid[key(cy, cx), default: []].append((p.latitude, p.longitude))
        }
        return keptIDs
    }

    // MARK: - Recherche

    /// Résultats de recherche (TOUS les ports — y compris les doublettes masquées).
    private var searchResults: [Port] {
        let q = searchText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard q.count >= 2 else { return [] }
        // Index pré-normalisé : on ne plie plus 3861 noms à chaque frappe, juste la requête.
        return searchIndex.lazy
            .filter { $0.haystack.contains(q) }
            .prefix(8)
            .map(\.port)
    }

    /// Construit l'index de recherche une seule fois (noms pliés sans accents/casse).
    private func buildSearchIndex() {
        guard searchIndex.isEmpty else { return }
        searchIndex = tideService.ports.map { port in
            (haystack: port.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current),
             port: port)
        }
    }

    /// Saute sur un port depuis la recherche : centre la carte + ouvre son panneau.
    private func jumpToPort(_ port: Port) {
        HapticManager.shared.impact(.light)
        searchText = ""
        searchFocused = false
        selectedMapPort = port
        pendingMapRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        )
    }

    // MARK: - Header Overlay
    private var headerOverlay: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack(alignment: .top, spacing: DS.spacingMD) {
                // Champ de recherche (remplace le titre « Carte · N ports »)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.scaled(size: DS.fontCallout))
                        .foregroundStyle(.secondary)
                    TextField("Rechercher un port…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.scaled(size: DS.fontCallout))
                        .foregroundStyle(.primary)
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.scaled(size: DS.fontCallout))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Effacer la recherche")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .liquidGlass(in: Capsule())
                VStack(spacing: DS.spacingSM) {
                Button {
                    HapticManager.shared.impact(.light)
                    if let location = tideService.userLocation {
                        pendingMapRegion = MKCoordinateRegion(center: location.coordinate,
                                                              span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
                    } else {
                        // Aucune position disponible — on en demande une fraîche et on centre dès réception
                        pendingRecenter = true
                        locationManager.requestLocationUpdate()
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.tideHigh)
                        .frame(width: 44, height: 44)
                        .background(mapGlassCircle)
                        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
                }
                .accessibilityLabel("Centrer sur ma position")

                // Accès rapide aux favoris (sous l'icône localisation).
                favoritesQuickMenu
                }
            }

            // Résultats de recherche (sous le champ, par-dessus la carte)
            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { i, port in
                        Button {
                            jumpToPort(port)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: port.isCustom ? "pin.fill" : "mappin.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(port.isCustom ? Color.tideLow : Color.tideHigh)
                                Text(port.name)
                                    .font(.scaled(size: DS.fontCallout, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let loc = tideService.userLocation {
                                    Text(port.formattedDistance(to: loc))
                                        .font(.scaled(size: DS.fontCaption))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < searchResults.count - 1 { OpenRowDivider(leadingInset: 36) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: DS.radiusMD).fill(.ultraThinMaterial))
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusMD))
            }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .background(
                LinearGradient(
                    colors: {
                        let scrim = colorScheme == .dark ? Color.black : Color.white
                        return [scrim.opacity(0.82), scrim.opacity(0.5), .clear]
                    }(),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )
        }
        .frame(height: 88)
    }

    // MARK: - Data Loading

    private func setupInitialPosition() {
        if let port = tideService.selectedPort {
            position = .camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude),
                distance: 100000
            ))
        } else if let location = tideService.userLocation {
            position = .camera(MapCamera(centerCoordinate: location.coordinate, distance: 100000))
        } else {
            position = .camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: 46.5, longitude: -1.5),
                distance: 1000000
            ))
        }
    }

    /// Seeds the cache with the currently selected port's data (already loaded)
    private func seedCurrentPortData() {
        if let port = tideService.selectedPort, !tideService.tideData.isEmpty {
            portTideCache[port.id] = tideService.tideData
            updateRisingState(portId: port.id, tideData: tideService.tideData)
        }
    }

    /// Loads tide data for favorites + nearby ports (limited set for arrows)
    private func loadPriorityPortsData() {
        // 1. Favorites first (usually 3-5 ports)
        let favorites = tideService.ports.filter { $0.isFavorite && portTideCache[$0.id] == nil }
        guard !favorites.isEmpty else { return }
        isLoadingMapData = true   // déclenche la barre IMMÉDIATEMENT (avant le 1er await réseau)
        loadTask = Task {
            for port in favorites {
                guard !Task.isCancelled else { isLoadingMapData = false; return }
                let data = await tideService.fetchTideDataForPort(port.id)
                if !data.isEmpty {
                    portTideCache[port.id] = data
                    updateRisingState(portId: port.id, tideData: data)
                }
            }
            isLoadingMapData = false

            // 2. Ne PAS pré-charger tous les ports restants
            // Les données sont chargées à la demande via loadPortTideData()
            // quand l'utilisateur tape sur un port visible sur la carte.
            // Pré-charger 3500+ ports consommerait trop de crédits API (WorldTides)
            // et causerait des centaines d'appels réseau inutiles.
        }
    }

    private func updateRisingState(portId: String, tideData: [TideData]) {
        guard let state = TideCalculator.currentState(at: Date(), sortedTides: tideData) else { return }
        portRisingStates[portId] = (state.trend == .rising || state.trend == .lowSlack)
        portTideHeights[portId] = state.currentHeight
    }

    private func selectPort(_ port: Port) {
        HapticManager.shared.success()
        tideService.selectedPort = port
        // Navigation IMMÉDIATE et fiable : on ne la conditionne pas au fetch réseau,
        // qui peut être lent ou échouer pour les ports du monde (NOAA). La TodayView
        // recharge marées + météo de son côté via onChange(selectedPort).
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            selectedTab = .today
        }
        selectPortTask?.cancel()
        selectPortTask = Task { await tideService.fetchTideData() }
    }

    private func loadPortTideData(_ port: Port) {
        guard portTideCache[port.id] == nil, portLoadTasks[port.id] == nil else { return }
        isLoadingMapData = true
        let task = Task {
            let data = await tideService.fetchTideDataForPort(port.id)
            guard !Task.isCancelled else { return }
            if !data.isEmpty {
                portTideCache[port.id] = data
                updateRisingState(portId: port.id, tideData: data)
            }
            isLoadingMapData = false
            portLoadTasks[port.id] = nil
        }
        portLoadTasks[port.id] = task
    }

    private func openInMaps(port: Port) {
        let location = CLLocation(latitude: port.latitude, longitude: port.longitude)
        let mapItem: MKMapItem
        if #available(iOS 26.0, *) {
            mapItem = MKMapItem(location: location, address: nil)
        } else {
            let placemark = MKPlacemark(coordinate: location.coordinate)
            mapItem = MKMapItem(placemark: placemark)
        }
        mapItem.name = port.name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

// MARK: - Enhanced Port Info Card

struct EnhancedPortInfoCard: View {
    let port: Port
    let tideData: [TideData]
    let isLoading: Bool
    let userLocation: CLLocation?
    let onSelect: () -> Void
    let onDirections: () -> Void
    let onToggleFavorite: () -> Void
    /// Ce port est un SPOT DE SURF → on affiche la section houle (hauteur · période · sens).
    var isSurfSpot: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeManager: ThemeManager
    /// Météo de l'heure courante au port (Open-Meteo, cache 1 h côté service).
    @State private var currentWx: HourlyForecast?
    /// Min/max du jour au port (dérivés des prévisions horaires).
    @State private var tempMin: Double?
    @State private var tempMax: Double?
    /// Série marine complète du spot (graphe surf : période + orientation + tendance de houle).
    @State private var surfSeries: [HourlyForecast] = []
    /// Cap de la mer ouverte vue du spot (orientation de la côte) — pilote l'exposition (éclat des
    /// chevrons + aiguille) de la vitrine surf.
    @State private var shoreOrientation: Double?

    /// Libellé + icône depuis le code météo WMO (Open-Meteo).
    private func wmoCondition(_ code: Int?) -> (icon: String, label: String) {
        switch code ?? -1 {
        case 0:          return ("sun.max.fill", "Temps clair")
        case 1, 2:       return ("cloud.sun.fill", "Peu nuageux")
        case 3:          return ("cloud.fill", "Couvert")
        case 45, 48:     return ("cloud.fog.fill", "Brouillard")
        case 51...57:    return ("cloud.drizzle.fill", "Bruine")
        case 61...67:    return ("cloud.rain.fill", "Pluie")
        case 71...77:    return ("cloud.snow.fill", "Neige")
        case 80...82:    return ("cloud.heavyrain.fill", "Averses")
        case 95...99:    return ("cloud.bolt.rain.fill", "Orage")
        default:         return ("cloud.fill", "Météo")
        }
    }

    /// Marées du jour au port (≤ 4 pour la rangée compacte).
    private var todayTidesRow: [TideData] {
        let cal = Calendar.inTimeZone(port.portTimeZone)
        return Array(tideData.filter { cal.isDateInToday($0.date) }.sorted { $0.date < $1.date }.prefix(4))
    }

    private var tideState: TideCalculator.TideState? {
        TideCalculator.currentState(at: Date(), sortedTides: tideData)
    }

    /// Échantillon marin le plus proche de « maintenant » (alimente la vitrine surf).
    private var nearestForecast: HourlyForecast? {
        let now = Date()
        return surfSeries.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) })
    }

    /// Prochaine marée à venir (PM ou BM) — la SEULE info marée gardée sur la card surf (tide-gated).
    private var nextTide: TideData? {
        let now = Date()
        return tideData.filter { $0.date > now }.min(by: { $0.date < $1.date })
    }



    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingXS) {
            // NOM EN HAUT de la card (→ fiche marée) · ÉTOILE favori. (Sans distance.)
            HStack(alignment: .center, spacing: DS.spacingSM) {
                Button(action: onSelect) {
                    HStack(spacing: 6) {
                        Text(port.name)
                            .font(.scaled(size: DS.fontTitle2, weight: .regular, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName: "chevron.right")
                            .font(.scaled(size: DS.fontSubheadline, weight: .bold))
                            // Affordance « aller plus loin » : orange = surf, cyan = port classique.
                            .foregroundStyle(isSurfSpot ? Color.orange : Color.tideHigh)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir la marée de \(port.name)")

                Spacer(minLength: 0)

                Button {
                    HapticManager.shared.heartbeat()
                    onToggleFavorite()
                } label: {
                    Image(systemName: port.isFavorite ? "star.fill" : "star")
                        .font(.scaled(size: DS.fontTitle2))
                        .foregroundStyle(port.isFavorite ? .yellow : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(port.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
            }
            .padding(.horizontal, DS.spacingLG)
            .padding(.top, DS.spacingXS)

            // Le GRAPHE sous le nom : spot de surf = bandeau HORAIRE de houle (barres hauteur +
            // flèches d'orientation), port classique = mini-courbe de marée. Bord à bord.
            if isLoading {
                HStack(spacing: DS.spacingSM) {
                    ProgressView().tint(Color.tideHigh)
                    Text("Chargement des marées…")
                        .font(.scaled(size: DS.fontFootnote))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if !tideData.isEmpty {
                if isSurfSpot {
                    // VITRINE surf façon Apple Weather « Hauteur de la houle » : gros chiffre +
                    // période, cadran d'horloge pour la direction, graphe 24 h (points + échelle +
                    // chevrons + heures). Selon la charte (accent orange).
                    SurfSwellStrip(surfSeries: surfSeries, nowForecast: nearestForecast,
                                   shoreOrientation: shoreOrientation, portTimeZone: port.portTimeZone)
                        .padding(.horizontal, DS.spacingLG)
                        .allowsHitTesting(false)
                } else {
                    MiniMapTideCurve(tideData: tideData, portTimeZone: port.portTimeZone)
                        .frame(height: 88)
                        .allowsHitTesting(false)
                }
            }

            // Météo du jour (condition + plage de température) — UNIQUEMENT pour les ports classiques.
            // La card surf reste une vitrine épurée (la météo n'est pas le sujet d'un spot de surf).
            if !isSurfSpot, let wx = currentWx {
                let cond = wmoCondition(wx.weatherCode)
                HStack(spacing: DS.spacingSM) {
                    Image(systemName: cond.icon)
                        .font(.scaled(size: DS.fontHeadline))
                        .foregroundStyle(.yellow)
                    Text(cond.label)
                        .font(.scaled(size: DS.fontCallout, weight: .regular))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let lo = tempMin, let hi = tempMax {
                        // Conversion °C→°F selon le réglage (était en °C brut même en impérial).
                        Text("\(Int(UnitFormatter.tempValue(lo, system: themeManager.measureSystem).rounded()))°")
                            .foregroundStyle(.secondary)
                        Capsule().fill(Color.yellow.opacity(0.8)).frame(width: 42, height: 5)
                        Text("\(Int(UnitFormatter.tempValue(hi, system: themeManager.measureSystem).rounded()))°")
                            .foregroundStyle(.primary)
                    }
                }
                .font(.scaled(size: DS.fontCallout, weight: .medium))
                .padding(.horizontal, DS.spacingLG)
                .allowsHitTesting(false)
            }

            if isSurfSpot {
                // Surf = tide-gated : UNE seule info marée (la prochaine PM/BM). Seul endroit où
                // le cyan/violet de marée apparaît dans la vitrine surf.
                if let t = nextTide {
                    let c = t.isHighTide ? Color.tideHigh : Color.tideLow
                    HStack(spacing: 6) {
                        Image(systemName: t.isHighTide ? "arrow.up" : "arrow.down")
                            .font(.scaled(size: DS.fontCaption, weight: .semibold))
                            .foregroundStyle(c)
                        Text(t.isHighTide ? "Pleine mer" : "Basse mer")
                            .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(formatTideTime(t.date, in: port.portTimeZone))
                            .font(.scaled(size: DS.fontSubheadline, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary).monospacedDigit()
                        Text(UnitFormatter.height(t.height, system: themeManager.measureSystem, decimals: 1))
                            .font(.scaled(size: DS.fontFootnote))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.spacingLG)
                    .allowsHitTesting(false)
                }
            } else if !todayTidesRow.isEmpty {
                // Port classique : les 4 marées du jour, rangée SANS cadre séparée par de fins traits.
                HStack(spacing: 0) {
                    ForEach(Array(todayTidesRow.enumerated()), id: \.element.id) { idx, tide in
                        let c = tide.isHighTide ? Color.tideHigh : Color.tideLow
                        HStack(spacing: 5) {
                            Image(systemName: tide.isHighTide ? "arrow.up" : "arrow.down")
                                .font(.scaled(size: DS.fontCaption, weight: .semibold))
                                .foregroundStyle(c.opacity(0.85))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(formatTideTime(tide.date, in: port.portTimeZone))
                                    .font(.scaled(size: DS.fontSubheadline, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary)
                                Text(UnitFormatter.height(tide.height, system: themeManager.measureSystem, decimals: 1))
                                    .font(.scaled(size: DS.fontCaption2))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if idx < todayTidesRow.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 0.5, height: 22)
                        }
                    }
                }
                .padding(.horizontal, DS.spacingLG)   // aligné sur les autres rangées de la card (était 18)
                .allowsHitTesting(false)
            }
        }
        .padding(.top, DS.spacingSM)
        .padding(.bottom, DS.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        // PANNEAU LIQUID GLASS arrondi et CONTENU (effet préféré, restauré). Le crash n'était PAS
        // le glassEffect — c'est une assertion Metal API Validation (DEBUG uniquement) sur un rendu
        // à 0×0 ; en build Release/App Store la validation est OFF → pas de crash.
        .liquidGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, DS.pagePadding)
        .padding(.bottom, 30)
        // Météo du port affiché (cache 1 h dans MarineWeatherService → quasi gratuit).
        .task(id: port.id) {
            // Cap du spot (pour l'exposition de la vitrine surf) — résolu par id (le port matérialisé
            // partage l'id du SurfSpot). nil pour un port classique.
            shoreOrientation = isSurfSpot ? SurfSpotCatalog.shared.spot(id: port.id)?.facingBearingDeg : nil
            // CACHE D'ABORD : la TodayView a déjà rempli MarineWeatherService.shared pour ce port
            // (MÊME source, MÊME id). On peint INSTANTANÉMENT depuis le cache chaud — pas de
            // reset/spinner. On ne vide l'état (état « chargement ») QUE sur un vrai cache-miss.
            var forecasts = MarineWeatherService.shared.cachedForecast(for: port) ?? []
            if forecasts.isEmpty {
                currentWx = nil; tempMin = nil; tempMax = nil; surfSeries = []
                forecasts = await MarineWeatherService.shared.fetchHourlyForecast(for: port)
            }
            let now = Date()
            if isSurfSpot { surfSeries = forecasts }   // série complète pour la vitrine surf
            currentWx = forecasts.min(by: {
                abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now))
            })
            // Plage de température du jour au port (uniquement utile aux ports classiques).
            if !isSurfSpot {
                let cal = Calendar.inTimeZone(port.portTimeZone)
                let temps = forecasts.filter { cal.isDateInToday($0.time) }.compactMap(\.temperature)
                tempMin = temps.min()
                tempMax = temps.max()
            }
        }
    }

}


// MARK: - Mini Map Tide Curve

struct MiniMapTideCurve: View {
    let tideData: [TideData]
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    /// Jour affiché (aujourd'hui par défaut). Le Calendrier passe le jour sélectionné ;
    /// le point « maintenant » et le trail n'apparaissent que si « now » tombe dedans.
    var day: Date = Date()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            // Garde-fou taille dégénérée (0×0 pendant l'animation d'apparition / layout) :
            // évite tout rendu Metal sur un drawable nul (source de crash côté GPU).
            guard size.width > 1, size.height > 1 else { return }
            let calendar = Calendar.inTimeZone(portTimeZone)
            let startOfDay = calendar.startOfDay(for: day)
            let endOfDay = startOfDay.addingTimeInterval(86400)

            // Filtrer les marées du jour affiché
            let todayTides = tideData.filter {
                calendar.isDate($0.date, inSameDayAs: day)
            }
            guard todayTides.count >= 2 else { return }

            // Étendre avec les marées adjacentes pour des bords lisses.
            // On inclut jusqu'à 2 points avant et 2 après le jour visible
            // pour garantir une interpolation cosinus lisse aux bords.
            var extendedTides = todayTides

            // Points avant le jour : prendre jusqu'à 2 marées avant la première du jour
            let tidesBeforeToday = tideData.filter { $0.date < (todayTides.first?.date ?? startOfDay) }
                .sorted { $0.date < $1.date }
            let preBorder = tidesBeforeToday.suffix(2)
            for tide in preBorder.reversed() {
                extendedTides.insert(tide, at: 0)
            }

            // Points après le jour : prendre jusqu'à 2 marées après la dernière du jour
            let tidesAfterToday = tideData.filter { $0.date > (todayTides.last?.date ?? endOfDay) }
                .sorted { $0.date < $1.date }
            let postBorder = tidesAfterToday.prefix(2)
            for tide in postBorder {
                extendedTides.append(tide)
            }

            // Fallback : si pas de données adjacentes, créer des points virtuels miroir
            let typicalHalfCycle: TimeInterval = 6 * 3600 + 12 * 60 // ~6h12m
            if preBorder.isEmpty, let firstToday = todayTides.first {
                if todayTides.count >= 2 {
                    let gap = todayTides[1].date.timeIntervalSince(firstToday.date)
                    let virtualDate = firstToday.date.addingTimeInterval(-abs(gap))
                    let virtualTide = TideData(
                        date: virtualDate,
                        height: todayTides[1].height,
                        isHighTide: !firstToday.isHighTide,
                        coefficient: nil
                    )
                    extendedTides.insert(virtualTide, at: 0)
                } else {
                    let virtualDate = firstToday.date.addingTimeInterval(-typicalHalfCycle)
                    let delta = (extendedTides.map(\.height).max() ?? firstToday.height) -
                                (extendedTides.map(\.height).min() ?? firstToday.height)
                    let mirrorH = firstToday.isHighTide
                        ? firstToday.height - max(delta, 1.0)
                        : firstToday.height + max(delta, 1.0)
                    extendedTides.insert(TideData(
                        date: virtualDate, height: mirrorH,
                        isHighTide: !firstToday.isHighTide, coefficient: nil
                    ), at: 0)
                }
            }
            if postBorder.isEmpty, let lastToday = todayTides.last {
                if todayTides.count >= 2 {
                    let gap = lastToday.date.timeIntervalSince(todayTides[todayTides.count - 2].date)
                    let virtualDate = lastToday.date.addingTimeInterval(abs(gap))
                    let virtualTide = TideData(
                        date: virtualDate,
                        height: todayTides[todayTides.count - 2].height,
                        isHighTide: !lastToday.isHighTide,
                        coefficient: nil
                    )
                    extendedTides.append(virtualTide)
                } else {
                    let virtualDate = lastToday.date.addingTimeInterval(typicalHalfCycle)
                    let delta = (extendedTides.map(\.height).max() ?? lastToday.height) -
                                (extendedTides.map(\.height).min() ?? lastToday.height)
                    let mirrorH = lastToday.isHighTide
                        ? lastToday.height - max(delta, 1.0)
                        : lastToday.height + max(delta, 1.0)
                    extendedTides.append(TideData(
                        date: virtualDate, height: mirrorH,
                        isHighTide: !lastToday.isHighTide, coefficient: nil
                    ))
                }
            }

            var minH = Double.infinity, maxH = -Double.infinity
            for t in extendedTides {
                if t.height < minH { minH = t.height }
                if t.height > maxH { maxH = t.height }
            }
            let padding = (maxH - minH) * 0.15
            let adjMin = minH - padding
            let range = max((maxH + padding) - adjMin, 0.1)

            let secondsInDay: Double = 86400
            let isDark = colorScheme == .dark

            // Amplitude SIGNATURE (esprit Today) : marges haut/bas → vague ample.
            let topMargin: CGFloat = size.height * 0.20
            let bandBottom: CGFloat = size.height * (1 - 0.14)
            let drawH = max(bandBottom - topMargin, 1)
            func yFor(_ h: Double) -> CGFloat {
                topMargin + CGFloat(1 - (h - adjMin) / range) * drawH
            }

            var curvePath = Path()
            let steps = Int(size.width)
            for i in 0...steps {
                let x = CGFloat(i)
                let time = startOfDay.addingTimeInterval(Double(i) / Double(steps) * secondsInDay)
                let y = yFor(interpolateHeight(at: time, tides: extendedTides))
                if i == 0 { curvePath.move(to: CGPoint(x: x, y: y)) }
                else { curvePath.addLine(to: CGPoint(x: x, y: y)) }
            }

            // — Fill SIGNATURE : dégradé multi-stops tideHigh→tideLow qui se dissout.
            var fillPath = curvePath
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()
            let fillStops: [Gradient.Stop] = isDark ? [
                .init(color: Color.tideHigh.opacity(0.30), location: 0.0),
                .init(color: Color.tideMid.opacity(0.22), location: 0.25),
                .init(color: Color.tideLow.opacity(0.14), location: 0.5),
                .init(color: Color.tideLow.opacity(0.04), location: 0.8),
                .init(color: .clear, location: 1.0)
            ] : [
                .init(color: Color.tideHigh.opacity(0.10), location: 0.0),
                .init(color: Color.tideLow.opacity(0.05), location: 0.45),
                .init(color: .clear, location: 0.8)
            ]
            context.fill(fillPath, with: .linearGradient(
                Gradient(stops: fillStops),
                startPoint: CGPoint(x: size.width / 2, y: topMargin),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            ))

            // — Position « maintenant » (sert au dégradé deux teintes ET au point).
            let now = Date()
            let nowT = now.timeIntervalSince(startOfDay) / secondsInDay
            let nowX = CGFloat(nowT) * size.width
            let nowY = yFor(interpolateHeight(at: now, tides: extendedTides))
            // Abscisse de césure passé / futur, bornée au cadre.
            let splitX = CGFloat(min(max(nowT, 0), 1)) * size.width

            // DEUX TEINTES, césure au point « maintenant » : cyan = déjà parcouru (passé),
            // violet = à venir (futur). Trait AFFINÉ (était dégradé 4 couleurs 2,5/3 px + trail 5 px).
            let pastColor = Color.tideHigh      // avant le point
            let futureColor = Color.tideLow     // après le point
            let pastWidth: CGFloat = isDark ? 2.6 : 2.8
            let futureWidth: CGFloat = isDark ? 1.6 : 1.9

            // — Glow SIGNATURE (dark only) sur le PASSÉ : la portion parcourue « brille » (cyan).
            if isDark && splitX > 0 {
                var g = context
                g.clip(to: Path(CGRect(x: 0, y: 0, width: splitX, height: size.height)))
                for layer in [(blur: 10.0, opacity: 0.28, width: 7.0), (blur: 4.0, opacity: 0.45, width: 4.0)] {
                    var gg = g
                    gg.addFilter(.blur(radius: layer.blur))
                    gg.opacity = layer.opacity
                    gg.stroke(curvePath, with: .color(pastColor),
                              style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }

            // — Futur (à droite du point) : trait fin, teinte « à venir ».
            if splitX < size.width {
                var fc = context
                fc.clip(to: Path(CGRect(x: splitX, y: 0, width: size.width - splitX, height: size.height)))
                fc.stroke(curvePath, with: .color(futureColor.opacity(isDark ? 0.92 : 0.85)),
                          style: StrokeStyle(lineWidth: futureWidth, lineCap: .round, lineJoin: .round))
            }
            // — Passé (à gauche du point) : trait un peu plus marqué, teinte cyan.
            if splitX > 0 {
                var pc = context
                pc.clip(to: Path(CGRect(x: 0, y: 0, width: splitX, height: size.height)))
                pc.stroke(curvePath, with: .color(pastColor),
                          style: StrokeStyle(lineWidth: pastWidth, lineCap: .round, lineJoin: .round))
            }

            // — Point « maintenant » : même style que Today (halo + anneau + cœur lumineux).
            if nowT >= 0 && nowT <= 1 {
                context.fill(Circle().path(in: CGRect(x: nowX - 12, y: nowY - 12, width: 24, height: 24)),
                             with: .color(Color.cyan.opacity(0.15)))
                context.stroke(Circle().path(in: CGRect(x: nowX - 8, y: nowY - 8, width: 16, height: 16)),
                               with: .color(Color.cyan.opacity(0.4)), lineWidth: 1.5)
                // Cœur lumineux (halo cyan flouté + cœur net).
                var glowDot = context
                glowDot.addFilter(.blur(radius: 4))
                glowDot.fill(Circle().path(in: CGRect(x: nowX - 5, y: nowY - 5, width: 10, height: 10)),
                             with: .color(.cyan))
                context.fill(Circle().path(in: CGRect(x: nowX - 4, y: nowY - 4, width: 8, height: 8)),
                             with: .color(isDark ? .white : .cyan))
            }

            // — Pleines/basses mers du jour + étiquette d'heure.
            let labelFmt = CachedDateFormatter.make("HH:mm", timeZone: portTimeZone)
            let labelColor: Color = isDark ? Color.white.opacity(0.78) : Color.black.opacity(0.6)
            for tide in todayTides {
                let tT = tide.date.timeIntervalSince(startOfDay) / secondsInDay
                guard tT >= 0 && tT <= 1 else { continue }
                let tx = CGFloat(tT) * size.width
                let ty = yFor(tide.height)
                let color: Color = tide.isHighTide ? .tideHigh : .tideLow
                context.fill(Circle().path(in: CGRect(x: tx - 2.5, y: ty - 2.5, width: 5, height: 5)), with: .color(color))
                // Heure : au-dessus des pleines mers, en dessous des basses ; x borné pour ne pas couper.
                let label = Text(labelFmt.string(from: tide.date))
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundColor(labelColor)
                let ly = tide.isHighTide ? ty - 11 : ty + 11
                let lx = min(max(tx, 20), size.width - 20)
                context.draw(label, at: CGPoint(x: lx, y: ly), anchor: .center)
            }
        }
        // Pas de `.drawingGroup()` : il alloue un drawable Metal hors-écran (taille animée à
        // l'apparition de la carte) — source de crash GPU 0×0 empilé sur MapKit. Le Canvas gère
        // ses propres flous (glow / point) sans cette couche ; rendu visuellement identique.
    }

    /// Cosine interpolation with smooth extrapolation at edges
    private func interpolateHeight(at date: Date, tides: [TideData]) -> Double {
        interpolateTideHeight(at: date, tides: tides)   // logique factorisée (partagée avec le graphe surf)
    }
}

/// Interpolation cosinus de la hauteur d'eau entre extrema de marée, avec extrapolation cosinus
/// avant le premier / après le dernier point (sans clamp). Factorisée hors de MiniMapTideCurve pour
/// factorisée hors de MiniMapTideCurve (réutilisable par d'autres tracés de marée).
fileprivate func interpolateTideHeight(at date: Date, tides: [TideData]) -> Double {
    guard let first = tides.first, let last = tides.last else { return 0 }

    // Extrapolation avant : continuer la courbe cosinus sans clamp
    if date < first.date && tides.count >= 2 {
        let second = tides[1]
        let duration = second.date.timeIntervalSince(first.date)
        guard duration > 0 else { return first.height }
        let t = date.timeIntervalSince(first.date) / duration
        let cosT = (1 - cos(t * .pi)) / 2
        return first.height + (second.height - first.height) * cosT
    }

    // Extrapolation après : continuer la courbe cosinus sans clamp
    if date > last.date && tides.count >= 2 {
        let prev = tides[tides.count - 2]
        let duration = last.date.timeIntervalSince(prev.date)
        guard duration > 0 else { return last.height }
        let t = date.timeIntervalSince(prev.date) / duration
        let cosT = (1 - cos(t * .pi)) / 2
        return prev.height + (last.height - prev.height) * cosT
    }

    // Interpolation entre deux points connus
    for i in 0..<tides.count - 1 {
        let prev = tides[i]
        let next = tides[i + 1]
        if date >= prev.date && date <= next.date {
            let totalInterval = next.date.timeIntervalSince(prev.date)
            guard totalInterval > 0 else { return prev.height }
            let t = date.timeIntervalSince(prev.date) / totalInterval
            let cosT = (1 - cos(t * .pi)) / 2
            return prev.height + (next.height - prev.height) * cosT
        }
    }
    return last.height
}

/// Nom de secteur (8 points) d'une direction de houle (deg, « d'où vient la houle »).
// MARK: - Graphe surf horaire (pied de fiche d'un SPOT DE SURF)

/// Remplace MiniMapTideCurve pour un SPOT DE SURF — PAS de courbe de marée. Graphe HORAIRE façon
/// app météo : barres de HAUTEUR au déferlement sur la journée + ligne « maintenant », puis sous
/// l'axe des heures, des flèches d'ORIENTATION de houle et deux nombres (hauteur en gras · période
/// en gris). Honnête : modèle large, la hauteur est un intervalle dont on affiche le milieu.
// MARK: - Vitrine surf (héro + ruban) — remplace l'ancien bandeau horaire dense

/// Card surf façon Apple Weather « Hauteur de la houle » (selon la charte : verre sombre, accent
/// orange). Gros chiffre de hauteur de houle (valeur modèle = honnête) + période, un CADRAN
/// d'horloge pour la direction (remplace la flèche fine), et un graphe propre sur 24 h glissantes :
/// points de hauteur + échelle + chevrons de direction + axe d'heures. Remplace l'ancien héro+ruban.
private struct SurfSwellStrip: View {
    let surfSeries: [HourlyForecast]
    let nowForecast: HourlyForecast?
    let shoreOrientation: Double?
    var portTimeZone: TimeZone
    @Environment(\.colorScheme) private var colorScheme

    // Accent = ORANGE (code couleur surf de l'app). La capture Apple Weather ne sert que de cadre
    // de RENDU (lignes, pointillés, grilles, cadran, chevrons) — surtout pas pour la couleur.
    private let surf = Color.orange

    private var nowDP: (height: Double, period: Double, direction: Double?, isPeak: Bool, count: Int)? {
        nowForecast.flatMap { SurfMetrics.dominantPartition($0) }
    }

    var body: some View {
        let sys = ThemeManager.shared.measureSystem
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: "water.waves")
                            .font(.scaled(size: DS.fontCaption, weight: .semibold))
                            .foregroundStyle(surf)
                        Text("HAUTEUR DE LA HOULE")
                            .font(.scaled(size: DS.fontCaption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.4)
                    }
                    if let dp = nowDP {
                        Text(UnitFormatter.height(dp.height, system: sys, decimals: 1))
                            .font(.scaled(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary).monospacedDigit()
                        Text("Période : \(Int(dp.period.rounded())) s")
                            .font(.scaled(size: DS.fontSubheadline))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .font(.scaled(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                directionDial
            }
            graph.frame(height: 96).allowsHitTesting(false)
        }
    }

    /// Cadran d'horloge : graduations (16 traits, 4 cardinaux plus longs) + aiguille orange en
    /// losange vers la PROVENANCE de la houle, cardinal dessous. Direction inconnue → point central.
    private var directionDial: some View {
        VStack(spacing: 3) {
            Canvas { ctx, size in
                guard size.width > 1, size.height > 1 else { return }
                let ink: Color = colorScheme == .dark ? .white : .black
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 2
                func pt(_ deg: Double, _ rad: CGFloat) -> CGPoint {
                    let a = deg * .pi / 180
                    return CGPoint(x: c.x + rad * CGFloat(sin(a)), y: c.y - rad * CGFloat(cos(a)))
                }
                // Graduations UNIFORMES (18 traits identiques) — comme la réf, pas de longues/courtes.
                for k in 0..<18 {
                    let deg = Double(k) / 18 * 360
                    var t = Path(); t.move(to: pt(deg, R)); t.addLine(to: pt(deg, R - 4))
                    ctx.stroke(t, with: .color(ink.opacity(0.28)), lineWidth: 1)
                }
                guard let dir = nowDP?.direction else {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(ink.opacity(0.4)))
                    return
                }
                // Aiguille = LA MÊME flèche location.north.fill que partout (dock, card, dashboard),
                // orientée vers la houle. Cohérence totale du glyphe de direction dans l'app.
                var g = ctx
                g.translateBy(x: c.x, y: c.y)
                g.rotate(by: .degrees(dir + 180))
                g.draw(Text(Image(systemName: "location.north.fill"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(surf),
                       at: .zero, anchor: .center)
            }
            .frame(width: 48, height: 48)
            Text(nowDP?.direction.map { WindTidePlanner.cardinal($0) } ?? "—")
                .font(.scaled(size: DS.fontCaption, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private struct GP { let frac: Double; let h: Double; let dir: Double? }

    /// Graphe 24 h (≈3 h de passé pour le contexte) façon Apple Weather : grilles légères H + V,
    /// échelle (m) à droite, hauteur de houle en ligne de TIRETS (passé estompé), chevrons de
    /// direction (~1,5 h), heures « 15 h » toutes les 6 h. Code couleur = orange surf.
    private var graph: some View {
        Canvas { ctx, size in
            guard size.width > 1, size.height > 1 else { return }
            let ink: Color = colorScheme == .dark ? .white : .black
            let sys = ThemeManager.shared.measureSystem
            let cal = Calendar.inTimeZone(portTimeZone)
            let now = Date()
            let hourStart = cal.dateInterval(of: .hour, for: now)?.start ?? now
            let windowStart = hourStart.addingTimeInterval(-3 * 3600)   // ~3 h de passé estompé
            let span = 24.0 * 3600
            let pts: [GP] = surfSeries.compactMap { f in
                let dt = f.time.timeIntervalSince(windowStart)
                guard dt >= 0, dt <= span, let dp = SurfMetrics.dominantPartition(f) else { return nil }
                return GP(frac: dt / span, h: dp.height, dir: dp.direction)
            }
            guard !pts.isEmpty else {
                ctx.draw(Text("Données de houle indisponibles").font(.system(size: 11)).foregroundColor(ink.opacity(0.45)),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let rightPad: CGFloat = 22
            let leftInset: CGFloat = 4                // marge : le 1er point/chevron n'est plus tronqué
            let plotW = size.width - rightPad - leftInset
            let gridTop: CGFloat = 8
            let dotBottom = size.height - 34          // place pour chevrons + heures
            let plotH = dotBottom - gridTop
            // Échelle 0 / 1 / 2 comme la capture de référence (min. 2 m, grandit si plus gros).
            let maxH = max(2.0, (pts.map(\.h).max() ?? 1).rounded(.up))
            func X(_ frac: Double) -> CGFloat { leftInset + CGFloat(frac) * plotW }
            func Y(_ h: Double) -> CGFloat { dotBottom - CGFloat(min(h, maxH) / maxH) * plotH }
            let nowFrac = now.timeIntervalSince(windowStart) / span

            // Grilles HORIZONTALES légères + échelle (m) à droite (pas de 1 m).
            var lvl = 0.0
            while lvl <= maxH + 0.001 {
                let gy = Y(lvl)
                var gl = Path(); gl.move(to: CGPoint(x: 0, y: gy)); gl.addLine(to: CGPoint(x: size.width - rightPad, y: gy))
                ctx.stroke(gl, with: .color(ink.opacity(0.16)), style: StrokeStyle(lineWidth: 0.6))
                let lab = UnitFormatter.height(lvl, system: sys, decimals: 0)
                    .replacingOccurrences(of: " m", with: "").replacingOccurrences(of: " ft", with: "")
                ctx.draw(Text(lab).font(.system(size: 11, weight: .medium)).foregroundColor(ink.opacity(0.4)),
                         at: CGPoint(x: size.width - 2, y: gy), anchor: .trailing)
                lvl += 1
            }

            // Grilles VERTICALES légères toutes les 6 h, alignées aux heures « 15 h » (comme la réf).
            let fmt = CachedDateFormatter.make("H' h'", timeZone: portTimeZone)
            let hourY = size.height - 7
            for hod in stride(from: 0, through: 24, by: 6) {
                let frac = Double(hod) / 24
                let gx = X(frac)
                var vg = Path(); vg.move(to: CGPoint(x: gx, y: gridTop)); vg.addLine(to: CGPoint(x: gx, y: dotBottom))
                ctx.stroke(vg, with: .color(ink.opacity(0.15)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                let target = windowStart.addingTimeInterval(Double(hod) * 3600)
                let anchor: UnitPoint = hod == 0 ? .leading : (hod == 24 ? .trailing : .center)
                ctx.draw(Text(fmt.string(from: target)).font(.system(size: 11, weight: .medium)).foregroundColor(ink.opacity(0.5)),
                         at: CGPoint(x: gx, y: hourY), anchor: anchor)
            }

            // (Pas de trait « maintenant » : ambigu. Le passé récent est juste estompé ci-dessous.)

            // Hauteur de houle = petits TIRETS courts et arrondis (presque ovales), comme la réf —
            // pas des longs traits. Passé estompé, futur vif.
            for p in pts {
                let col = surf.opacity(p.frac < nowFrac ? 0.4 : 0.95)
                let cx = X(p.frac), cy = Y(p.h)
                ctx.fill(Path(roundedRect: CGRect(x: cx - 3, y: cy - 2.4, width: 6, height: 4.8), cornerRadius: 2.4),
                         with: .color(col))
            }

            // Flèches de direction = SF Symbol « location.north.fill » — LE MÊME glyphe que le bandeau
            // dock du mode surf (cohérence demandée), pivoté vers la houle (~1,5 h), orange selon l'expo.
            let chevY = size.height - 22
            for step in stride(from: 0.0, through: 24.0, by: 1.5) {
                let frac = step / 24
                guard let s = pts.min(by: { abs($0.frac - frac) < abs($1.frac - frac) }),
                      abs(s.frac - frac) < 1.0 / 24, let dir = s.dir else { continue }
                let expo = SurfMetrics.shoreExposure(swellDirection: dir, shoreOrientation: shoreOrientation) ?? 1
                var g = ctx
                g.translateBy(x: X(frac), y: chevY)
                g.rotate(by: .degrees(dir + 180))
                g.draw(Text(Image(systemName: "location.north.fill"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(surf.opacity(0.55 + 0.4 * expo)),
                       at: .zero, anchor: .center)
            }
        }
    }
}

// MARK: - Carte teintée maison (MKMapView)
// Tuiles Apple sombres + un calque de TEINTE navy rendu SOUS les labels et SOUS les
// pins (les overlays passent sous les annotations dans MapKit) → fond bleu nuit
// cohérent avec l'app, PINS 100 % INTACTS. Gestes natifs. Offline.

/// Overlay couvrant le monde projeté (pas de polygone lon/lat → zéro souci antiméridien).
final class WorldTintOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}

/// Remplit d'une couleur (navy semi-transparent) LA TUILE demandée — et elle seule.
final class TintRenderer: MKOverlayRenderer {
    let fill: UIColor
    init(overlay: MKOverlay, fill: UIColor) {
        self.fill = fill
        super.init(overlay: overlay)
    }
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(fill.cgColor)
        // ⚠️ `mapRect` (la TUILE demandée), JAMAIS `overlay.boundingMapRect` (= .world).
        // MapKit appelle draw() une fois PAR TUILE : remplir le rect MONDE à chaque appel
        // faisait rasteriser un CGRect de ~268 M × 268 M points par tuile et par niveau de
        // zoom → la carte mettait ~10 s à s'afficher (mode sombre uniquement : la teinte
        // n'est installée que là). L'union des tuiles = le monde → rendu IDENTIQUE.
        context.fill(rect(for: mapRect))
    }
}

/// Annotation port légère.
final class PortAnnotation: NSObject, MKAnnotation {
    let portID: String
    let isFavorite: Bool
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    init(port: Port) {
        portID = port.id
        isFavorite = port.isFavorite
        coordinate = CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude)
        title = port.name
    }
}

/// Annotation balise vent : petit point discret, non sélectionnable.
final class WindDotAnnotation: NSObject, MKAnnotation {
    let stationID: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// Label balise : vent réel · rafale · orientation (ex « 18 km/h · raf 25 · NO »).
    var windLabel: String?
    init(station: WindStation, windLabel: String?) {
        stationID = station.id
        coordinate = station.coordinate
        self.windLabel = windLabel
    }
}

/// Annotation SPOT DE SURF : pastille sélectionnable colorée par le grade (lu en CACHE seulement,
/// jamais de fetch). `grade`/`subtitle` sont mutables → mis à jour quand le cache se remplit.
final class SurfSpotAnnotation: NSObject, MKAnnotation {
    let spotID: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    var grade: SurfGrade
    /// Label de données affiché sous la pastille : houle + période (ex « 1,5 m · 12 s »),
    /// sinon le nom du spot tant qu'il n'y a pas de donnée fraîche en cache.
    var detailLabel: String?
    init(spot: SurfSpot, grade: SurfGrade, detailLabel: String?) {
        spotID = spot.id
        coordinate = spot.coordinate
        title = spot.name
        self.grade = grade
        self.detailLabel = detailLabel
        subtitle = grade == .unknown ? nil : grade.localizedName
    }
}

/// Palette des marqueurs de carte UNIFIÉS — la couleur de FOND encode le TYPE (et rien d'autre) :
/// 🟢 port classique · 🔵 balise de vent réel · 🟠 spot de surf. Le rating/qualité vit ailleurs
/// (étoiles de la courbe, fiche du spot) ; la carte se lit d'un coup d'œil par type.
enum MapPillStyle {
    static let port = UIColor(red: 0.18, green: 0.72, blue: 0.47, alpha: 0.94)   // vert mer
    static let wind = UIColor(red: 0.34, green: 0.69, blue: 0.96, alpha: 0.94)   // bleu ciel
    static let surf = UIColor(red: 0.98, green: 0.58, blue: 0.18, alpha: 0.94)   // orange
}

/// Marqueur de carte UNIFIÉ : une « cellule » pilule (icône + texte) de MÊME forme et MÊME layout
/// pour les trois types ; seule la COULEUR DE FOND change selon le type (cf. MapPillStyle) :
/// - port : nom + flèche de marée (↑ montante / ↓ descendante / 〜 inconnue)
/// - vent : vent réel + rafale (+ orientation)
/// - surf : hauteur au déferlement + période de houle
/// Remplace les anciennes PortMarkerView / SurfSpotMarkerView / WindBaliseMarkerView (formes
/// hétérogènes : épingle-flèche, point cyan, pastille colorée-par-grade).
final class DataPillMarkerView: MKAnnotationView {
    private let cell = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()
    private let favoriteDot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        cell.layer.cornerCurve = .continuous
        cell.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        cell.layer.borderWidth = 1
        cell.layer.shadowColor = UIColor.black.cgColor
        cell.layer.shadowOpacity = 0.35
        cell.layer.shadowRadius = 2.5
        cell.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(cell)

        iconView.tintColor = .white
        iconView.contentMode = .center
        cell.addSubview(iconView)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 1
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.45
        label.layer.shadowRadius = 1
        label.layer.shadowOffset = .zero
        cell.addSubview(label)

        favoriteDot.backgroundColor = .systemYellow
        favoriteDot.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
        favoriteDot.layer.borderWidth = 0.5
        favoriteDot.isHidden = true
        addSubview(favoriteDot)

        collisionMode = .circle
        centerOffset = .zero
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Configure la cellule. `iconSystemName == nil` (ou symbole introuvable) → pas d'icône.
    func configure(text: String?, iconSystemName: String?, bgColor: UIColor,
                   favorite: Bool = false, selected: Bool = false) {
        label.text = text
        if let n = iconSystemName,
           let img = UIImage(systemName: n, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)) {
            iconView.image = img
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
        cell.backgroundColor = bgColor
        // Bordure adaptative : blanche sur carte sombre, NOIRE sur carte claire (le blanc fixe
        // était invisible en mode clair).
        let lightMap = cell.traitCollection.userInterfaceStyle == .light
        let borderBase = lightMap ? UIColor.black : UIColor.white
        cell.layer.borderColor = borderBase.withAlphaComponent(selected ? 0.85 : 0.6).cgColor
        cell.layer.borderWidth = selected ? 1.6 : 1
        favoriteDot.isHidden = !favorite
        layoutCell()
    }

    override func layoutSubviews() { super.layoutSubviews(); layoutCell() }

    private func layoutCell() {
        let hasText = !(label.text?.isEmpty ?? true)
        guard hasText || !iconView.isHidden else { cell.isHidden = true; return }
        cell.isHidden = false
        let hPad: CGFloat = 7, vPad: CGFloat = 3, gap: CGFloat = 4
        let iconSize: CGFloat = iconView.isHidden ? 0 : 13
        label.sizeToFit()
        let lw = hasText ? label.bounds.width : 0
        let lh = hasText ? max(label.bounds.height, 13) : 0
        let contentW = iconSize + ((!iconView.isHidden && hasText) ? gap : 0) + lw
        let cellW = contentW + hPad * 2
        let cellH = max(lh, iconSize) + vPad * 2

        bounds = CGRect(x: 0, y: 0, width: cellW, height: cellH)
        cell.frame = bounds
        cell.layer.cornerRadius = cellH / 2

        var x = hPad
        if !iconView.isHidden {
            iconView.frame = CGRect(x: x, y: (cellH - iconSize) / 2, width: iconSize, height: iconSize)
            x += iconSize + (hasText ? gap : 0)
        }
        if hasText {
            label.frame = CGRect(x: x, y: (cellH - lh) / 2, width: lw, height: lh)
        }
        favoriteDot.frame = CGRect(x: cellW - 5, y: -3, width: 8, height: 8)
        favoriteDot.layer.cornerRadius = 4
    }
}

// (Anciennes SurfSpotMarkerView / WindBaliseMarkerView / surfGradeUIColor supprimées :
//  remplacées par DataPillMarkerView ci-dessus — une seule forme, couleur de fond par type.)

// MARK: Pins/clusters (vues SwiftUI rendues en images, cachées)

private enum MapGlyphs {
    private static var cache: [String: UIImage] = [:]

    @MainActor static func cluster(count: Int, favorite: Bool) -> UIImage {
        let key = "c_\(count)_\(favorite ? "f" : "_")"
        if let img = cache[key] { return img }
        let img = render(MapClusterGlyph(count: count, favorite: favorite))
        // Borne le cache : les clés cluster ("c_<count>_…") sont quasi illimitées (un compte distinct
        // = une clé). Au-delà du plafond, on repart à zéro (re-rendu ponctuel des ~12 pins + dot).
        if cache.count > 80 { cache.removeAll() }
        cache[key] = img
        return img
    }

    @MainActor private static func render<V: View>(_ view: V) -> UIImage {
        let r = ImageRenderer(content: view)
        r.scale = 3
        return r.uiImage ?? UIImage()
    }
}

private struct MapClusterGlyph: View {
    let count: Int
    let favorite: Bool

    var body: some View {
        let d: CGFloat = count > 99 ? 38 : (count > 9 ? 32 : 27)
        let grad = LinearGradient(colors: [.tideHigh, .tideLow], startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            Circle().fill(grad).frame(width: d, height: d)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.2))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            Text("\(count)")
                .font(.system(size: count > 99 ? 13 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white).monospacedDigit()
            if favorite {
                Circle().fill(.yellow).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
                    .offset(x: d / 2 - 2, y: -d / 2 + 2)
            }
        }
        .frame(width: 52, height: 52)
    }
}

// MARK: Representable

struct TintedMapRepresentable: UIViewRepresentable {
    var ports: [Port]
    /// Balises vent réel à matérialiser en petits points discrets (filtrées par zoom/viewport).
    var windStations: [WindStation]
    /// Spots de surf à afficher (pastille colorée par grade, lue en cache). Vide = aucun
    /// (ex. utilisateur non-premium → la carte reste identique à avant).
    var surfSpots: [SurfSpot] = []
    @Binding var selectedPortID: String?
    var risingStates: [String: Bool]
    /// Hauteur d'eau instantanée par port (m). Présente ⇒ affichée sur la pastille.
    var heights: [String: Double] = [:]
    var scheme: ColorScheme
    var initialCenter: CLLocationCoordinate2D
    @Binding var pendingRegion: MKCoordinateRegion?
    /// Appui long sur la carte → coordonnée pour créer un spot custom géolocalisé.
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    /// Tap sur une pastille de SPOT DE SURF → son id (le parent le matérialise en port + l'ouvre).
    var onSelectSurfSpot: (String) -> Void = { _ in }
    /// Premier rendu de la carte terminé — OU échec de chargement des tuiles (hors-ligne).
    /// Le parent coupe alors sa barre de chargement. Appelé UNE seule fois.
    var onFirstRender: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsTraffic = false
        map.showsBuildings = false
        map.showsUserLocation = true
        let lp = UILongPressGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleLongPress(_:)))
        lp.minimumPressDuration = 0.5
        map.addGestureRecognizer(lp)
        map.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        // Ouverture ZOOMÉE au plus près du port/spot courant (initialCenter = port sélectionné).
        // ~0,2° ≈ 22 km : on voit le spot et sa côte immédiate, plus la vue pays d'avant.
        map.setRegion(MKCoordinateRegion(center: initialCenter,
                                         span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)),
                      animated: false)
        context.coordinator.installTint(on: map)
        context.coordinator.syncAnnotations(on: map, ports: ports)
        context.coordinator.syncSurfSpots(on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        if map.overrideUserInterfaceStyle != style {
            map.overrideUserInterfaceStyle = style
            map.removeOverlays(map.overlays)
            context.coordinator.installTint(on: map)
        }
        context.coordinator.syncAnnotations(on: map, ports: ports)
        context.coordinator.syncWindDots(on: map)
        context.coordinator.syncSurfSpots(on: map)
        context.coordinator.refreshMarkers(on: map)
        context.coordinator.refreshSurfMarkers(on: map)
        if let r = pendingRegion {
            // Ne PAS recadrer si la carte n'est pas encore dimensionnée : animer un
            // setRegion sur des bounds nulles fait rendre MapKit dans un drawable 0×0
            // (« Failed to acquire drawable » / setDrawableSize 0×0). On garde la région
            // en attente et on l'applique au prochain updateUIView (carte dimensionnée).
            guard map.bounds.width > 1, map.bounds.height > 1 else { return }
            map.setRegion(r, animated: true)
            DispatchQueue.main.async { pendingRegion = nil }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TintedMapRepresentable
        init(_ parent: TintedMapRepresentable) { self.parent = parent }

        // MARK: Premier rendu (pilote la barre de chargement du parent)

        private var didSignalFirstRender = false

        /// Signale UNE fois que la carte est peinte (ou qu'elle ne le sera pas). Async sur la main
        /// queue : on ne mute jamais l'état SwiftUI pendant une passe de mise à jour de la vue.
        private func signalFirstRender() {
            guard !didSignalFirstRender else { return }
            didSignalFirstRender = true
            let notify = parent.onFirstRender
            DispatchQueue.main.async { notify() }
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            signalFirstRender()
        }

        /// Tuiles indisponibles (hors-ligne, réseau coupé) : la carte ne peindra pas — on coupe
        /// quand même la barre. Elle reste utilisable (gestes + annotations depuis le cache), fidèle
        /// au parti pris offline : jamais un chargement qui tourne dans le vide.
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            signalFirstRender()
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            HapticManager.shared.impact(.medium)
            parent.onLongPress(coord)
        }

        func installTint(on map: MKMapView) {
            // Teinte uniquement en mode sombre. .aboveRoads → sous les labels (lisibles)
            // et sous les annotations (pins intacts).
            guard parent.scheme == .dark else { return }
            // Idempotent : ne pas empiler plusieurs voiles (ex. bascules de thème répétées).
            guard !map.overlays.contains(where: { $0 is WorldTintOverlay }) else { return }
            map.addOverlay(WorldTintOverlay(), level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Navy semi-transparent → assombrit + bleute les tuiles Apple sombres.
            TintRenderer(overlay: overlay, fill: UIColor(red: 0.03, green: 0.05, blue: 0.16, alpha: 0.55))
        }

        // MARK: Annotations

        /// Dézoomé (span > seuil) → seuls favoris/custom/sélection sont affichés ;
        /// les autres ports APPARAISSENT en zoomant. (Pas tout au lancement.)
        private var zoomGated = true
        private let zoomGateThreshold: CLLocationDegrees = 5.5

        // Rechargement des balises au pan (METAR/winds.mobi sont GLOBAUX) — débouncé + borné.
        private var panRefreshTask: Task<Void, Never>?
        private var lastBaliseCenter: CLLocationCoordinate2D?
        // Prefetch des prévisions surf des spots VISIBLES (remplit les labels orange) — débouncé + borné.
        private var surfPrefetchTask: Task<Void, Never>?

        /// Re-fetch les balises autour du centre visible si on s'est éloigné de > ~80 km de la
        /// dernière zone chargée — UNIQUEMENT zoomé (les points sont visibles) et avec un débounce,
        /// pour ne PAS refaire le churn de re-renders qui aggravait l'ancien rendu 0×0.
        private func refreshBalisesIfMoved(center: CLLocationCoordinate2D) {
            guard !zoomGated else { return }
            if let last = lastBaliseCenter,
               MKMapPoint(center).distance(to: MKMapPoint(last)) < 80_000 { return }
            lastBaliseCenter = center
            panRefreshTask?.cancel()
            panRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)   // 0,6 s après l'arrêt du geste
                if Task.isCancelled { return }
                await WindStationAggregator.shared.refresh(around: center)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let gated = mapView.region.span.latitudeDelta > zoomGateThreshold
            let gateChanged = (gated != zoomGated)
            zoomGated = gated
            // Zoomé (non gated) → on re-synchronise À CHAQUE déplacement : seules les épingles du
            // cadre visible restent posées (viewport-only). Le diff étant idempotent (ajoute/retire
            // uniquement les deltas), ça reste léger même en balayant le monde.
            if gateChanged || !gated {
                syncAnnotations(on: mapView, ports: parent.ports)
                syncWindDots(on: mapView)
                syncSurfSpots(on: mapView)
            }
            // Recharge les balises autour de la zone visible quand on s'éloigne assez (sinon
            // `allStations` reste filtré à 200 km autour du port FR sélectionné → aucune balise à
            // l'étranger). Débouncé + borné en distance + zoomé seulement → pas de churn de rendu.
            refreshBalisesIfMoved(center: mapView.region.center)
        }

        /// Diff idempotent : ajoute les ports manquants (ex. spot custom fraîchement créé)
        /// et retire ceux supprimés. Appelé à la création, à chaque update et au
        /// franchissement du seuil de zoom.
        func syncAnnotations(on map: MKMapView, ports allPorts: [Port]) {
            let ports: [Port]
            if zoomGated {
                // Dézoomé : uniquement favoris / custom / sélection.
                ports = allPorts.filter { $0.isFavorite || $0.isCustom || $0.id == parent.selectedPortID }
            } else {
                // VIEWPORT-ONLY : seules les épingles du cadre visible (élargi de 25 % pour anticiper
                // le pan) sont posées, + toujours favoris/custom/sélection. → le nombre TOTAL de ports
                // (~3 800 dans le monde) n'impacte plus le rendu : le 1ᵉʳ affichage redevient direct.
                let v = map.visibleMapRect
                let mx = v.size.width * 0.25, my = v.size.height * 0.25
                let rect = MKMapRect(x: v.origin.x - mx, y: v.origin.y - my,
                                     width: v.size.width + 2 * mx, height: v.size.height + 2 * my)
                // L'antiméridien (Fidji, Tuvalu, NZ, Midway…) : visibleMapRect peut déborder
                // de [0, world) ; MKMapRect.contains ne « wrappe » pas. On décale le point de
                // ±world pour rattraper la couture. N'ajoute que des épingles, jamais n'en retire.
                let world = MKMapSize.world.width
                func wrappedContains(_ r: MKMapRect, _ p: MKMapPoint) -> Bool {
                    r.contains(p)
                        || r.contains(MKMapPoint(x: p.x + world, y: p.y))
                        || r.contains(MKMapPoint(x: p.x - world, y: p.y))
                }
                ports = allPorts.filter {
                    $0.isFavorite || $0.isCustom || $0.id == parent.selectedPortID
                        || wrappedContains(rect, MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)))
                }
            }

            let existing = map.annotations.compactMap { $0 as? PortAnnotation }
            let existingIDs = Set(existing.map { $0.portID })
            let newIDs = Set(ports.map { $0.id })

            let toRemove = existing.filter { !newIDs.contains($0.portID) }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }

            let toAdd = ports.filter { !existingIDs.contains($0.id) }
            if !toAdd.isEmpty { map.addAnnotations(toAdd.map { PortAnnotation(port: $0) }) }
        }

        /// Balises vent en PETITS POINTS discrets. MÊME filtre que les ports : RIEN quand dézoomé
        /// (« pas tout d'un coup »), viewport-only en zoomé. Seules les balises FRAÎCHES (qui émettent
        /// vraiment) sont posées. Diff idempotent par stationID.
        /// Label balise : « vent · rafale · orientation » dans l'unité de vent de l'utilisateur.
        private func baliseLabel(for s: WindStation) -> String? {
            guard let r = s.reading else { return nil }
            let unit = ThemeManager.shared.windUnit
            var parts = ["\(UnitFormatter.windSpeedInt(r.speedAvgKmh, unit: unit)) \(unit.label)"]
            if let g = r.gustKmh { parts.append("raf \(UnitFormatter.windSpeedInt(g, unit: unit))") }
            parts.append(compass8(r.directionDegrees))
            return parts.joined(separator: " · ")
        }

        func syncWindDots(on map: MKMapView) {
            let existing = map.annotations.compactMap { $0 as? WindDotAnnotation }
            guard !zoomGated else {
                if !existing.isEmpty { map.removeAnnotations(existing) }
                return
            }
            let v = map.visibleMapRect
            let mx = v.size.width * 0.25, my = v.size.height * 0.25
            let rect = MKMapRect(x: v.origin.x - mx, y: v.origin.y - my,
                                 width: v.size.width + 2 * mx, height: v.size.height + 2 * my)
            // Antiméridien (Fidji, NZ…) : visibleMapRect peut déborder de [0, world) ; on teste le
            // point décalé de ±world comme syncAnnotations, sinon les balises disparaissent vers 180°.
            let world = MKMapSize.world.width
            let visible = parent.windStations.filter {
                guard $0.reading?.isFresh == true else { return false }
                let p = MKMapPoint($0.coordinate)
                return rect.contains(p)
                    || rect.contains(MKMapPoint(x: p.x + world, y: p.y))
                    || rect.contains(MKMapPoint(x: p.x - world, y: p.y))
            }
            let existingIDs = Set(existing.map { $0.stationID })
            let newIDs = Set(visible.map { $0.id })
            let toRemove = existing.filter { !newIDs.contains($0.stationID) }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            let toAdd = visible.filter { !existingIDs.contains($0.id) }
            if !toAdd.isEmpty {
                map.addAnnotations(toAdd.map { WindDotAnnotation(station: $0, windLabel: baliseLabel(for: $0)) })
            }
        }

        /// Grade d'un spot lu en CACHE seulement (jamais de fetch déclenché ici → offline-safe,
        /// pas de fan-out réseau au pan). Réservé au premium (surf = payant) ; sinon `.unknown`
        /// (teinte neutre). Choisit l'heure de prévision la plus proche de maintenant.
        /// Grade + label de données (hauteur · période) d'un spot, lu en CACHE seulement (premium).
        /// JAMAIS le nom du spot : un spot affiche sa hauteur + période, ou rien (label nil → la
        /// pastille montre « — »), pour qu'on le distingue d'un port d'un coup d'œil par la couleur.
        private func surfReadout(for spot: SurfSpot) -> (grade: SurfGrade, label: String?) {
            guard PremiumManager.shared.isPremium,
                  let fc = MarineWeatherService.shared.cachedForecast(latitude: spot.latitude, longitude: spot.longitude),
                  !fc.isEmpty else { return (.unknown, nil) }
            let now = Date()
            guard let current = fc.min(by: {
                abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now))
            }) else { return (.unknown, nil) }
            let grade = SurfMetrics.grade(for: current, spot: spot.spotConfig)
            // Hauteur au déferlement (plage, façon Surfline) + PÉRIODE de houle : « 0,3–0,6 m · 12 s ».
            guard let dp = SurfMetrics.dominantPartition(current) else { return (grade, nil) }
            let br = SurfMetrics.breakingHeightRange(height: dp.height, period: dp.period)
            let sys = ThemeManager.shared.measureSystem
            let lo = UnitFormatter.height(br.lowerBound, system: sys, decimals: 1)
                .replacingOccurrences(of: " m", with: "").replacingOccurrences(of: " ft", with: "")
            let hi = UnitFormatter.height(br.upperBound, system: sys, decimals: 1)   // garde l'unité
            return (grade, "\(lo)–\(hi) · \(Int(dp.period.rounded())) s")
        }

        /// Spots de surf en pastilles colorées. MÊME filtre que les balises : RIEN quand dézoomé,
        /// viewport-only en zoomé. Diff idempotent par spotID. Le grade est posé à la création puis
        /// recoloré par refreshSurfMarkers quand le cache se remplit.
        func syncSurfSpots(on map: MKMapView) {
            let existing = map.annotations.compactMap { $0 as? SurfSpotAnnotation }
            guard !zoomGated, !parent.surfSpots.isEmpty else {
                if !existing.isEmpty { map.removeAnnotations(existing) }
                return
            }
            let v = map.visibleMapRect
            let mx = v.size.width * 0.25, my = v.size.height * 0.25
            let rect = MKMapRect(x: v.origin.x - mx, y: v.origin.y - my,
                                 width: v.size.width + 2 * mx, height: v.size.height + 2 * my)
            let world = MKMapSize.world.width
            let visible = parent.surfSpots.filter {
                let p = MKMapPoint($0.coordinate)
                return rect.contains(p)
                    || rect.contains(MKMapPoint(x: p.x + world, y: p.y))
                    || rect.contains(MKMapPoint(x: p.x - world, y: p.y))
            }
            let existingIDs = Set(existing.map { $0.spotID })
            let newIDs = Set(visible.map { $0.id })
            let toRemove = existing.filter { !newIDs.contains($0.spotID) }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            let toAdd = visible.filter { !existingIDs.contains($0.id) }
            if !toAdd.isEmpty {
                map.addAnnotations(toAdd.map { spot -> SurfSpotAnnotation in
                    let r = surfReadout(for: spot)
                    return SurfSpotAnnotation(spot: spot, grade: r.grade, detailLabel: r.label)
                })
            }
            // Remplit les labels orange : pré-charge (borné) la prévision des spots visibles sans cache.
            prefetchVisibleSurfReadouts(visible, center: map.region.center, on: map)
        }

        /// Pré-charge (BORNÉ + débouncé) la prévision marine des spots de surf VISIBLES qui n'ont pas
        /// encore de cache → leurs pastilles orange passent de « — » à « hauteur · période ». Premium +
        /// zoomé seulement, cap dur ~10, trié par distance au centre ; repeint via refreshSurfMarkers.
        /// Offline-safe : sans réseau, no-op silencieux (les labels restent « — »). Aucun fan-out.
        private func prefetchVisibleSurfReadouts(_ spots: [SurfSpot], center: CLLocationCoordinate2D, on map: MKMapView) {
            guard PremiumManager.shared.isPremium, !zoomGated, !spots.isEmpty else { return }
            let missing = spots.filter {
                MarineWeatherService.shared.cachedForecast(latitude: $0.latitude, longitude: $0.longitude) == nil
            }
            guard !missing.isEmpty else { return }
            let c = MKMapPoint(center)
            let targets = missing
                .sorted { MKMapPoint($0.coordinate).distance(to: c) < MKMapPoint($1.coordinate).distance(to: c) }
                .prefix(10)
                .map { (lat: $0.latitude, lon: $0.longitude) }
            surfPrefetchTask?.cancel()
            surfPrefetchTask = Task { [weak self, weak map] in
                try? await Task.sleep(nanoseconds: 600_000_000)   // 0,6 s après l'arrêt du geste
                if Task.isCancelled { return }
                for t in targets {
                    if Task.isCancelled { return }
                    await MarineWeatherService.shared.prefetchForecastIfStale(latitude: t.lat, longitude: t.lon)
                }
                if Task.isCancelled { return }
                await MainActor.run { guard let self, let map else { return }; self.refreshSurfMarkers(on: map) }
            }
        }

        /// Symbole de marée pour la pastille de port : ↑ montante, ↓ descendante, 〜 inconnue.
        private func tideArrowSymbol(_ rising: Bool?) -> String {
            guard let r = rising else { return "water.waves" }
            return r ? "arrow.up" : "arrow.down"
        }

        /// Texte de la pastille de port : nom + hauteur d'eau si chargée (« Brest · 4.2 m »).
        /// Sans donnée de marée (ports non visités) → nom seul, comme avant.
        private func portPillText(_ port: PortAnnotation) -> String? {
            guard let title = port.title else { return nil }
            guard let h = parent.heights[port.portID] else { return title }
            return "\(title) · \(SharedUnitFormatter.height(h, decimals: 1))"
        }

        /// (Ré)applique la config d'un port sur sa pastille unifiée (nom + hauteur + flèche marée, fond vert).
        private func applyPort(_ view: DataPillMarkerView, _ port: PortAnnotation, selected: Bool) {
            view.configure(text: portPillText(port),
                           iconSystemName: tideArrowSymbol(parent.risingStates[port.portID]),
                           bgColor: MapPillStyle.port,
                           favorite: port.isFavorite,
                           selected: selected)
        }

        /// Met à jour le label/flèche des pastilles surf quand le grade/cache change (le FOND reste
        /// orange : la couleur encode le type, plus le rating).
        func refreshSurfMarkers(on map: MKMapView) {
            let spotsByID = Dictionary(parent.surfSpots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for ann in map.annotations {
                guard let s = ann as? SurfSpotAnnotation, let spot = spotsByID[s.spotID] else { continue }
                let r = surfReadout(for: spot)
                if r.grade != s.grade {
                    s.grade = r.grade
                    s.subtitle = r.grade == .unknown ? nil : r.grade.localizedName
                }
                s.detailLabel = r.label
                guard let view = map.view(for: ann) as? DataPillMarkerView else { continue }
                view.configure(text: s.detailLabel ?? "—", iconSystemName: nil,   // pas de flèche/icône sur le surf
                               bgColor: MapPillStyle.surf, selected: view.isSelected)
            }
        }

        func refreshMarkers(on map: MKMapView) {
            for ann in map.annotations {
                guard let port = ann as? PortAnnotation,
                      let view = map.view(for: ann) as? DataPillMarkerView else { continue }
                applyPort(view, port, selected: parent.selectedPortID == port.portID)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let port = annotation as? PortAnnotation {
                let id = "port"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DataPillMarkerView)
                    ?? DataPillMarkerView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.clusteringIdentifier = "port"
                view.displayPriority = port.isFavorite ? .required : .defaultLow
                view.isEnabled = true
                view.canShowCallout = false
                applyPort(view, port, selected: parent.selectedPortID == port.portID)
                return view
            }
            if let dot = annotation as? WindDotAnnotation {
                let id = "windDot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DataPillMarkerView)
                    ?? DataPillMarkerView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.clusteringIdentifier = nil        // les balises ne se regroupent pas
                view.isEnabled = false                 // discret : non sélectionnable, taps au travers
                view.displayPriority = .defaultLow      // les ports priment en cas de collision
                view.collisionMode = .circle
                view.configure(text: dot.windLabel, iconSystemName: nil, bgColor: MapPillStyle.wind)  // vent : pas de flèche
                return view
            }
            if let surf = annotation as? SurfSpotAnnotation {
                let id = "surfSpot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DataPillMarkerView)
                    ?? DataPillMarkerView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.clusteringIdentifier = nil
                view.isEnabled = true
                view.canShowCallout = false            // tap → on OUVRE le spot (card), pas un callout
                view.displayPriority = .defaultLow      // les ports priment en cas de collision
                view.collisionMode = .circle
                view.configure(text: surf.detailLabel ?? "—", iconSystemName: nil, bgColor: MapPillStyle.surf)  // surf : hauteur · période, jamais de nom/flèche
                return view
            }
            if let cluster = annotation as? MKClusterAnnotation {
                let id = "cluster"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.collisionMode = .circle
                let hasFav = cluster.memberAnnotations.contains { ($0 as? PortAnnotation)?.isFavorite == true }
                view.image = MapGlyphs.cluster(count: cluster.memberAnnotations.count, favorite: hasFav)
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let surf = view.annotation as? SurfSpotAnnotation {
                // Tap sur un spot de surf → le parent le matérialise en port + l'ouvre. On déselectionne
                // (sa pastille va disparaître au profit d'une épingle de port) ; le recentrage est géré
                // par le parent via pendingRegion.
                HapticManager.shared.impact(.medium)
                mapView.deselectAnnotation(view.annotation, animated: false)
                parent.onSelectSurfSpot(surf.spotID)
                return
            }
            if let port = view.annotation as? PortAnnotation {
                HapticManager.shared.impact(.medium)
                parent.selectedPortID = port.portID
                (view as? DataPillMarkerView).map { applyPort($0, port, selected: true) }
                // recentre doux (décalé vers le haut, la fiche couvre le bas)
                var span = mapView.region.span
                if span.latitudeDelta > 6 { span = MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6) }
                let c = CLLocationCoordinate2D(latitude: port.coordinate.latitude - span.latitudeDelta * 0.18,
                                               longitude: port.coordinate.longitude)
                mapView.setRegion(MKCoordinateRegion(center: c, span: span), animated: true)
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                var rect = MKMapRect.null
                for ann in cluster.memberAnnotations {
                    let p = MKMapPoint(ann.coordinate)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 90, left: 60, bottom: 340, right: 60), animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if let port = view.annotation as? PortAnnotation {
                (view as? DataPillMarkerView).map { applyPort($0, port, selected: false) }
            }
        }
    }
}

#Preview {
    MapView(tideService: TideService(), locationManager: LocationManager(), selectedTab: .constant(.map))
        .preferredColorScheme(.dark)
}

// MARK: - Création d'un spot depuis la carte (géolocalisé d'office)

/// Wrapper Identifiable pour présenter `SpotEditorView` via `.sheet(item:)` sur un point carte.
struct MapPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

//
//  FavoritesView.swift
//  Tide It
//
//  Vue des ports favoris et personnalisés
//

import SwiftUI
import CoreLocation

struct FavoritesView: View {
    @ObservedObject var tideService: TideService
    @Binding var selectedTab: ContentView.AppTab
    @State private var showAddCustomPort = false
    @State private var selectedSegment = 0
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                // Header
                headerSection
                
                // Segment control
                segmentControl
                
                // Content — ordre : Favoris · Surf · Personnalisés
                if selectedSegment == 0 {
                    favoritesSection
                } else if selectedSegment == 1 {
                    surfSpotsSection
                } else {
                    customPortsSection
                }
                
                Spacer(minLength: 100)
            }
            .padding(.top, 16)
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .sheet(isPresented: $showAddCustomPort) {
            SpotEditorView(tideService: tideService)
        }
    }
    
    // MARK: - Header (style CalendarView)
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Favoris")
                    .pageHeaderStyle()
                
                Text("\(favoritePorts.count) ports enregistrés")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.gray)
            }
            
            Spacer()
            
            Button {
                showAddCustomPort = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.horizontal, DS.pagePadding)
        .padding(.bottom, 2)
    }
    
    // MARK: - Segment Control (souligné, composant partagé)
    private var segmentControl: some View {
        UnderlineSegments(
            titles: [String(localized: "Favoris"), String(localized: "Surf"), String(localized: "Personnalisés")],
            selectedIndex: selectedSegment,
            onSelect: { index in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedSegment = index
                }
            },
            accent: selectedSegment == 1 ? .orange : .cyan   // code couleur surf sur l'onglet Surf
        )
        .padding(.horizontal, DS.pagePadding)
    }
    
    // MARK: - Favorites Section (liste ouverte, sans cadre)
    private var favoritesSection: some View {
        VStack(spacing: 0) {
            if favoritePorts.isEmpty {
                emptyFavoritesView
            } else {
                ForEach(Array(favoritePorts.enumerated()), id: \.element.id) { i, port in
                    FavoritePortRow(
                        port: port,
                        tideService: tideService,
                        selectedTab: $selectedTab,
                        isSelected: tideService.selectedPort?.id == port.id
                    )
                    if i < favoritePorts.count - 1 { rowDivider }
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }

    // Ports custom de l'utilisateur, séparés : les SPOTS DE SURF (matérialisés depuis le catalogue)
    // vont dans l'onglet « Surf » ; les autres ports perso restent dans « Personnalisés ».
    private var surfCustomPorts: [Port] {
        tideService.customPorts.filter { SurfSpotCatalog.shared.spot(id: $0.id) != nil }
    }
    private var nonSurfCustomPorts: [Port] {
        tideService.customPorts.filter { SurfSpotCatalog.shared.spot(id: $0.id) == nil }
    }

    // MARK: - Custom Ports Section (ports perso NON-surf)
    private var customPortsSection: some View {
        VStack(spacing: 0) {
            if nonSurfCustomPorts.isEmpty {
                emptyCustomPortsView
            } else {
                ForEach(Array(nonSurfCustomPorts.enumerated()), id: \.element.id) { i, port in
                    CustomPortRow(
                        port: port,
                        tideService: tideService,
                        selectedTab: $selectedTab,
                        isSelected: tideService.selectedPort?.id == port.id
                    )
                    if i < nonSurfCustomPorts.count - 1 { rowDivider }
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - Surf Section (les SPOTS DE SURF sauvegardés de l'utilisateur)
    private var surfSpotsSection: some View {
        VStack(spacing: 0) {
            if surfCustomPorts.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "figure.surfing")
                        .font(.system(size: 44)).foregroundStyle(.gray.opacity(0.5))
                    Text("Aucun spot de surf")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.primary)
                    Text("Ajoute un spot depuis la carte ou la recherche")
                        .font(.system(size: 14)).foregroundStyle(.gray).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ForEach(Array(surfCustomPorts.enumerated()), id: \.element.id) { i, port in
                    CustomPortRow(
                        port: port,
                        tideService: tideService,
                        selectedTab: $selectedTab,
                        isSelected: tideService.selectedPort?.id == port.id,
                        isSurf: true
                    )
                    if i < surfCustomPorts.count - 1 { rowDivider }
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }

    /// Fin séparateur entre lignes (composant partagé), aligné après l'icône.
    private var rowDivider: some View {
        OpenRowDivider(leadingInset: 64)
    }
    
    // MARK: - Empty Views (ouverts, sans cadre)
    private var emptyFavoritesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.slash")
                .font(.system(size: 48))
                .foregroundStyle(.gray.opacity(0.5))
            
            Text("Aucun favori")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            
            Text("Ajoutez des ports en favoris depuis la carte ou la recherche")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 50)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var emptyCustomPortsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 48))
                .foregroundStyle(.gray.opacity(0.5))
            
            Text("Aucun port personnalisé")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            
            Text("Créez des ports personnalisés avec un décalage horaire basé sur un port de référence")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            
            Button {
                showAddCustomPort = true
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("Ajouter un port")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
            }
        }
        .padding(.vertical, 50)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Computed
    private var favoritePorts: [Port] {
        let favorites = tideService.ports.filter { $0.isFavorite && !$0.isCustom }
        // Classés par distance à l'iPhone si la position est connue, sinon par nom.
        if let here = tideService.userLocation {
            return favorites.sorted { $0.distance(to: here) < $1.distance(to: here) }
        }
        return favorites.sorted { $0.name < $1.name }
    }
}

// MARK: - Favorite Port Row
struct FavoritePortRow: View {
    let port: Port
    @ObservedObject var tideService: TideService
    @Binding var selectedTab: ContentView.AppTab
    let isSelected: Bool
    @ObservedObject private var sportStore = SportSetupStore.shared

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isSelected ?
                                [.cyan.opacity(0.3), .blue.opacity(0.2)] :
                                [.gray.opacity(0.2), .gray.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? .cyan : .secondary)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(port.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.cyan : .primary)
                    if sportStore.notify(for: port.id) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.cyan)
                            .accessibilityLabel("Notifications de fenêtre GO activées")
                    }
                }

                if let location = tideService.userLocation {
                    Text(port.formattedDistance(to: location))
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 14) {
                Button {
                    tideService.toggleFavorite(port: port)
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.cyan.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Color.cyan).frame(width: 3, height: 30)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectPort()
        }
    }
    
    private func selectPort() {
        HapticManager.shared.impact(.light)
        tideService.selectedPort = port
        Task {
            await tideService.fetchTideData()
        }
        // Naviguer vers l'onglet Aujourd'hui
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            selectedTab = .today
        }
    }
}

// MARK: - Custom Port Row
struct CustomPortRow: View {
    let port: Port
    @ObservedObject var tideService: TideService
    @Binding var selectedTab: ContentView.AppTab
    let isSelected: Bool
    /// true = rangée d'un SPOT DE SURF (onglet Surf) → icône vague + code couleur orange, et
    /// AUCUNE mention (ref/décalage) pour un alignement net. false = port perso classique (pin violet).
    var isSurf: Bool = false
    @ObservedObject private var sportStore = SportSetupStore.shared
    @State private var showDeleteConfirm = false
    @State private var showEditor = false

    /// Accent de la rangée : orange pour un spot surf, violet pour un port perso.
    private var accent: Color { isSurf ? .orange : .purple }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isSurf
                                ? [.orange.opacity(0.30), Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.20)]
                                : [.purple.opacity(0.3), .indigo.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)

                Image(systemName: isSurf ? "water.waves" : "pin.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(port.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .primary)
                    if sportStore.notify(for: port.id) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.cyan)
                            .accessibilityLabel("Notifications de fenêtre GO activées")
                    }
                }

                // Mention (port de référence + décalage horaire) — UNIQUEMENT pour les ports perso.
                // Un spot de surf reste sur une seule ligne (nom seul) → rangées alignées, sans décalage.
                if !isSurf {
                    HStack(spacing: 8) {
                        if let refId = port.referencePortId,
                           let refPort = tideService.ports.first(where: { $0.id == refId }) {
                            Text("Ref: \(refPort.name)")
                                .font(.system(size: 12))
                                .foregroundStyle(.gray)
                        }

                        Text(port.formattedTimeOffset)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.2))
                            )
                    }
                }
            }
            
            Spacer()

            // Edit button
            Button {
                HapticManager.shared.impact(.light)
                showEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)

            // Delete button
            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.purple.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Color.purple).frame(width: 3, height: 30)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.shared.impact(.light)
            tideService.selectedPort = port
            Task {
                await tideService.fetchTideData()
            }
            // Naviguer vers l'onglet Aujourd'hui
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = .today
            }
        }
        .alert("Supprimer le port", isPresented: $showDeleteConfirm) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                tideService.removeCustomPort(portId: port.id)
            }
        } message: {
            Text("Voulez-vous vraiment supprimer \(port.name) ?")
        }
        .sheet(isPresented: $showEditor) {
            SpotEditorView(tideService: tideService, editingPort: port)
        }
    }
}

// MARK: - Éditeur de spot
/// Éditeur de spot unifié : point d'entrée UNIQUE pour créer un port/spot personnalisé.
/// Point d'entrée unique pour créer un port/spot personnalisé — depuis le « + » des
/// favoris (sans coordonnée → « ma position » ou coords du port de référence) ou depuis
/// l'appui long sur la carte (coordonnée pré-remplie, donc spot géolocalisé d'office).
struct SpotEditorView: View {
    @ObservedObject var tideService: TideService
    /// Coordonnée pré-remplie (appui long carte). nil = création depuis les favoris.
    var initialCoordinate: CLLocationCoordinate2D? = nil
    /// Spot existant à modifier (depuis les favoris). nil = création.
    var editingPort: Port? = nil
    /// Callback avec le port créé (la carte s'en sert pour le sélectionner).
    var onCreated: (Port) -> Void = { _ in }

    private var isEditing: Bool { editingPort != nil }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var name = ""
    @State private var selectedReferencePort: Port?
    @State private var timeOffsetHours = 0
    @State private var timeOffsetMinutes = 0
    @State private var isPositiveOffset = true
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var didPrefill = false
    @State private var saveErrorMessage: String?
    @State private var showReferencePicker = false
    // Type de spot / eau praticable / orientation : retirés (gérés par sport dans « Mes sports »).

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    nameField
                    positionField
                    referenceField
                    offsetField
                    // Type de spot / eau praticable / orientation côté mer RETIRÉS : ces gates
                    // sont désormais réglés PAR SPORT dans « Mes sports » (vent, direction,
                    // hauteur d'eau, fenêtre marée), pas par spot. App orientée vent.

                    Spacer(minLength: 40)

                    saveButton
                }
                .padding(20)
            }
            .appBackground()
            .navigationTitle(isEditing ? "Modifier le spot" : "Nouveau spot")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { prefillIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .foregroundStyle(.cyan)
                }
            }
            .alert(
                "Impossible d'ajouter le port",
                isPresented: Binding(
                    get: { saveErrorMessage != nil },
                    set: { if !$0 { saveErrorMessage = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) { saveErrorMessage = nil }
                },
                message: {
                    if let msg = saveErrorMessage { Text(msg) }
                }
            )
            .sheet(isPresented: $showReferencePicker) {
                ReferencePortPicker(tideService: tideService, selected: $selectedReferencePort)
            }
        }
    }

    private var canSave: Bool {
        !name.isEmpty && selectedReferencePort != nil
    }
    
    // MARK: - Champs (extraits pour soulager le type-checker)

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nom du port")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.gray)
            TextField("Entrez le nom du port", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
        }
    }

    @ViewBuilder
    private var positionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.gray)

            if let c = coordinate {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.green)
                    Text(String(format: "%.4f, %.4f", c.latitude, c.longitude))
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    Spacer()
                    if tideService.userLocation != nil {
                        Button("Ma position") { useMyLocation() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
            } else {
                Button { useMyLocation() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill").foregroundStyle(.cyan)
                        Text(tideService.userLocation != nil
                             ? "Utiliser ma position actuelle"
                             : "Position = celle du port de référence")
                            .font(.system(size: 15))
                            .foregroundStyle(tideService.userLocation != nil ? Color.primary : Color.gray)
                        Spacer()
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .disabled(tideService.userLocation == nil)
            }
        }
    }

    private var referenceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Port de référence")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.gray)
            // Bouton → sheet de recherche (un Menu avec 3800+ Button figerait l'UI).
            Button {
                showReferencePicker = true
            } label: {
                HStack {
                    Text(selectedReferencePort?.name ?? "Sélectionner un port")
                        .foregroundStyle(selectedReferencePort == nil ? .gray : .primary)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(.cyan)
                }
                .font(.system(size: 16))
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
    }

    private var offsetField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Décalage horaire")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.gray)
            HStack(spacing: 16) {
                Button {
                    isPositiveOffset.toggle()
                } label: {
                    Text(isPositiveOffset ? "+" : "-")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.cyan)
                        .frame(width: 50, height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.15)))
                }
                VStack(spacing: 4) {
                    Stepper("", value: $timeOffsetHours, in: 0...12).labelsHidden()
                    Text("\(timeOffsetHours)h")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
                VStack(spacing: 4) {
                    Stepper("", value: $timeOffsetMinutes, in: 0...59, step: 5).labelsHidden()
                    Text("\(timeOffsetMinutes)min")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
            }
        }
    }

    private var saveButton: some View {
        Button {
            saveCustomPort()
        } label: {
            Text(isEditing ? "Enregistrer" : "Créer le spot")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: canSave ? [.cyan, .blue] : [.gray, .gray.opacity(0.5)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canSave)
    }

    /// Au premier affichage : reprend la coordonnée fournie (carte) et pré-sélectionne
    /// le port de référence le plus proche.
    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true

        // Mode édition : on reprend tous les champs du spot existant.
        if let port = editingPort {
            name = port.name
            coordinate = CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude)
            selectedReferencePort = port.referencePortId.flatMap { id in tideService.ports.first { $0.id == id } }
            isPositiveOffset = port.timeOffset >= 0
            timeOffsetHours = abs(port.timeOffset) / 60
            timeOffsetMinutes = abs(port.timeOffset) % 60
        } else {
            if coordinate == nil { coordinate = initialCoordinate }
            if selectedReferencePort == nil, let c = coordinate {
                selectedReferencePort = tideService.nearestReferencePort(to: c)
            }
        }
    }

    private func useMyLocation() {
        guard let loc = tideService.userLocation else { return }
        coordinate = loc.coordinate
        HapticManager.shared.impact(.light)
        if selectedReferencePort == nil {
            selectedReferencePort = tideService.nearestReferencePort(to: loc.coordinate)
        }
    }

    private func saveCustomPort() {
        guard let refPort = selectedReferencePort else { return }

        let totalMinutes = (timeOffsetHours * 60 + timeOffsetMinutes) * (isPositiveOffset ? 1 : -1)
        // Position : coordonnée explicite (carte / ma position) sinon celle du port de référence.
        let lat = coordinate?.latitude ?? refPort.latitude
        let lon = coordinate?.longitude ?? refPort.longitude
        // Gates type/eau/orientation retirés du spot (gérés par sport dans « Mes sports »).
        let cfg = SpotConfig()

        // — Mode édition : on met à jour le spot existant (id conservé) —
        if let editing = editingPort {
            let updated = Port(
                id: editing.id, name: name, latitude: lat, longitude: lon,
                isFavorite: editing.isFavorite, isCustom: true,
                referencePortId: refPort.id, timeOffset: totalMinutes,
                portTimeZoneIdentifier: refPort.portTimeZoneIdentifier,
                source: editing.source, country: editing.country
            )
            tideService.updateCustomPort(updated)
            SpotConfigStore.shared.set(cfg, for: editing.id)
            TideCache.shared.invalidate(portId: editing.id)   // ref/décalage ont pu changer
            if tideService.selectedPort?.id == editing.id {
                Task { await tideService.fetchTideData(forceRefresh: true) }
            }
            HapticManager.shared.success()
            dismiss()
            return
        }

        // — Mode création —
        guard let created = tideService.addCustomPort(
            name: name,
            latitude: lat,
            longitude: lon,
            referencePortId: refPort.id,
            timeOffset: totalMinutes
        ) else {
            saveErrorMessage = "Impossible d'ajouter ce port. Vérifiez le nom et le décalage horaire (max ±12h)."
            HapticManager.shared.notification(.error)
            return
        }

        SpotConfigStore.shared.set(cfg, for: created.id)
        HapticManager.shared.success()
        onCreated(created)
        dismiss()
    }
}

// MARK: - Reference Port Picker (sheet recherche, liste lazy)
private struct ReferencePortPicker: View {
    @ObservedObject var tideService: TideService
    @Binding var selected: Port?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var index: [(port: Port, haystack: String)] = []

    private var results: [Port] {
        let base = index
        if searchText.isEmpty {
            return base.prefix(200).map(\.port)
        }
        let needle = searchText.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
        return base.lazy.filter { $0.haystack.contains(needle) }.prefix(200).map(\.port)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: DS.spacingMD) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.gray)
                    TextField("Rechercher un port...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.glassHighlight.opacity(0.05)))
                .padding(.horizontal, DS.pagePadding)
                .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { port in
                            Button {
                                selected = port
                                dismiss()
                            } label: {
                                HStack {
                                    Text(port.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if selected?.id == port.id {
                                        Image(systemName: "checkmark").foregroundStyle(.cyan)
                                    }
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, DS.pagePadding)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.glassHighlight.opacity(0.06))
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .appBackground()
            .navigationTitle("Port de référence")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if index.isEmpty {
                    index = tideService.ports
                        .filter { !$0.isCustom }
                        .sorted { $0.name < $1.name }
                        .map { port in
                            (port, port.name.lowercased()
                                .folding(options: .diacriticInsensitive, locale: .current))
                        }
                }
            }
        }
    }
}

#Preview {
    FavoritesView(tideService: TideService(), selectedTab: .constant(.today))
        .preferredColorScheme(.dark)
}

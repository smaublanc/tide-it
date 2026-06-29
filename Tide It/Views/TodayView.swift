//
//  TodayView.swift
//  Tide It
//
//  Vue principale : dashboard riche avec graphique, prochaine marée,
//  courant, météo, activités et export
//

import SwiftUI
import WeatherKit
import ActivityKit
import CoreLocation

struct TodayView: View {
    @ObservedObject var tideService: TideService
    // Utilise l'instance partagée pour éviter les doublons et dédupliquer
    // les appels WeatherKit (coûteux en quota).
    @ObservedObject private var weatherService = WeatherService.shared
    @ObservedObject var marineService: MarineWeatherService = .shared
    @ObservedObject private var liveActivityManager = LiveActivityManager.shared
    @ObservedObject private var pioupiouService = PioupiouService.shared
    @ObservedObject private var aviationWeatherService = AviationWeatherService.shared
    @ObservedObject private var weameterService = WeameterService.shared
    @ObservedObject private var premiumManager = PremiumManager.shared
    @State private var currentTime = Date()
    @State private var displayedDate = Date()
    @State private var showPortPicker = false
    @State private var showComparison = false
    @State private var scrollToTodayTrigger = false
    @State private var portChangeTask: Task<Void, Never>?
    @State private var loadDataTask: Task<Void, Never>?
    @State private var activityScores: [ActivityScore] = []
    @State private var dashboardAppeared = false
    @State private var sunTimes: [(sunrise: Date, sunset: Date)] = []
    @State private var showPremiumPaywall = false
    @State private var openMeteoForecasts: [HourlyForecast] = []
    /// TOUTES les fenêtres GO (tous sports) calculées via le MÊME `ActivityGoPlanner.plan` que le
    /// calendrier → la courbe (vent + surf) affiche exactement les fenêtres du calendrier.
    @State private var goWindows: [GoCurveWindow] = []
    @State private var dismissedErrorMessage: String?
    /// Barre de chargement marées : n'apparaît QUE si le chargement dépasse 2 s (cold start),
    /// pour ne pas clignoter sur un cache instantané.
    @State private var showLoadingBar = false
    @State private var loadingBarTask: Task<Void, Never>?
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var sportStore = SportSetupStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Sports suivis et exploitables DU SPOT COURANT → mêmes fenêtres GO que le calendrier.
    private var activeSportSetups: [SportSetup] {
        guard let portID = tideService.selectedPort?.id else { return [] }
        // Surf (conditions vides → SurfConditions) et AUTO (l'app calcule) ne doivent pas être filtrés.
        return sportStore.enabledSetups(for: portID).filter { $0.sport.isSurf || $0.auto || !$0.conditions.isEmpty }
    }

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    /// Calendrier réglé sur le fuseau du port : tout calcul « jour » (même jour, début
    /// de journée, nombre de jours) reste cohérent même quand le port est dans un autre fuseau.
    private var calendar: Calendar { Calendar.inTimeZone(portTimeZone) }

    // Formateurs de date statiques (évite recréation à chaque render)
    // Le timeZone est mis à jour dynamiquement selon le port sélectionné
    private static let frenchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Fuseau horaire du port sélectionné
    private var portTimeZone: TimeZone {
        tideService.selectedPort?.portTimeZone ?? TimeZone(identifier: "Europe/Paris") ?? .current
    }

    /// Date formatée dans le fuseau du port
    private func formattedDate(_ date: Date) -> String {
        Self.frenchDateFormatter.timeZone = portTimeZone
        return Self.frenchDateFormatter.string(from: date).capitalized
    }

    /// Heure formatée dans le fuseau du port
    private func formattedTime(_ date: Date) -> String {
        Self.timeFormatter.timeZone = portTimeZone
        return Self.timeFormatter.string(from: date)
    }

    private var isToday: Bool {
        calendar.isDate(displayedDate, inSameDayAs: currentTime)
    }


    /// Utilise l'état mis en cache par TideService (rafraîchi chaque minute via timer)
    private var currentTideState: TideCalculator.TideState? {
        tideService.cachedTideState
    }

    /// Sens du flux pour les particules : direction (+ monte / − descend) et teinte.
    private var tideFlow: (direction: Double, tint: Color) {
        let base: (direction: Double, tint: Color)
        switch tideService.cachedTideState?.trend {
        case .rising:    base = (1.0, .tideHigh)
        case .falling:   base = (-1.0, .tideLow)
        case .highSlack: base = (0.22, .tideHigh)
        case .lowSlack:  base = (-0.22, .tideLow)
        case .none:      base = (0.0, .tideHigh)
        }
        // Mode vent : couleur immédiate des particules = force du vent à l'instant courant
        // (fallback/au repos). Au défilement, ParticleFlowBus.windTint (centre de la courbe)
        // prend le relais, lu en direct par le Canvas. Le sens de dérive suit la marée.
        if themeManager.windMode, let fc = closestForecastNow() {
            return (base.direction, PremiumCurveCanvas.windColorSmooth(fc.windSpeedKmh))
        }
        return base
    }

    /// Prévision la plus proche de l'instant courant (pour la couleur vent des particules).
    private func closestForecastNow() -> HourlyForecast? {
        guard !openMeteoForecasts.isEmpty else { return nil }
        return openMeteoForecasts.min {
            abs($0.time.timeIntervalSince(currentTime)) < abs($1.time.timeIntervalSince(currentTime))
        }
    }

    /// Prévision la plus proche d'une date donnée (centre du scroll = `displayedDate`). Pilote la
    /// vision houle animée du mode surf.
    private func closestForecast(to date: Date) -> HourlyForecast? {
        guard !openMeteoForecasts.isEmpty else { return nil }
        return openMeteoForecasts.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }
    }

    /// Série de prévisions vue par la COURBE et le MOTEUR GO (jauge de confiance, stage 2). Premium +
    /// toggle « corriger avec le réel » + biais corrigeable → on retire le biais local appris (modèle
    /// vs balise) de tout l'horizon. Sinon série BRUTE. Source UNIQUE → courbe et fenêtres GO restent
    /// cohérentes. ⚠️ Jamais réinjectée dans l'apprentissage (`record` lit `closestForecastNow` = brut).
    private var forecastsForDisplay: [HourlyForecast] {
        guard themeManager.debiasGoEnabled, premiumManager.isPremium,
              let pid = tideService.selectedPort?.id else { return openMeteoForecasts }
        return ForecastBiasService.shared.debiasedSeries(openMeteoForecasts, portId: pid)
    }

    /// Tracé du vent réel récent (≈4 h) de la balise sélectionnée — archive Pioupiou DENSE et continue.
    /// Vide si la balise n'est pas Pioupiou (pas d'archive) ou pas encore chargée → pas de tracé (honnête).
    private var realWindHistory: [WindReading] {
        guard let st = observedWind?.station, st.source == .pioupiou else { return [] }
        return pioupiouService.archive(for: st.id)
    }

    /// Message d'erreur à afficher en haut de l'écran, ou nil si tout va bien.
    private var currentErrorMessage: String? {
        if let tideError = tideService.error {
            if let localized = tideError as? LocalizedError, let desc = localized.errorDescription {
                return desc
            }
            return "Impossible de charger les données de marée."
        }
        return nil
    }

    private var todayCoefficient: Int? {
        // Coefficient du cycle EN COURS : la pleine mer (porteuse du coef) la plus
        // proche de maintenant → se met à jour quand on passe d'un cycle à l'autre.
        TideCalculator.currentCoefficient(at: currentTime, tides: tideService.tideData)
    }

    var body: some View {
        GeometryReader { outerGeo in
            let availableHeight = outerGeo.size.height

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // MARK: - Graphique = exactement la zone visible
                    ZStack {
                        // Particules ambiantes (profondeur + gyroscope) derrière la courbe
                        if themeManager.tideParticles {
                            // .equatable() : le champ ne se réévalue pas pendant le scroll.
                            // La couleur vent passe par ParticleFlowBus (lu en direct dans le
                            // Canvas), donc elle suit le défilement sans aucun re-render.
                            TideParticleField(direction: tideFlow.direction, tint: tideFlow.tint)
                                .equatable()
                                .frame(height: availableHeight)
                                .allowsHitTesting(false)
                        }

                        // Courbe de marées scrollable
                        PremiumTideGraphView(
                            tideData: tideService.tideData,
                            currentTime: currentTime,
                            screenWidth: outerGeo.size.width,
                            scrollToTodayTrigger: $scrollToTodayTrigger,
                            sunTimes: sunTimes,
                            hourlyForecast: weatherService.hourlyForecast,
                            weatherService: weatherService,
                            onDateChanged: { date in
                                // Vibration au CHANGEMENT DE JOUR pendant le défilement de la courbe.
                                if !calendar.isDate(date, inSameDayAs: displayedDate) {
                                    HapticManager.shared.impact(.light)
                                }
                                displayedDate = date
                            },
                            portTimeZone: portTimeZone,
                            curveMode: themeManager.curveMode,
                            openMeteoForecasts: forecastsForDisplay,
                            observedWindKmh: observedWind?.reading.speedAvgKmh,
                            observedGustKmh: observedWind?.reading.gustKmh,
                            observedMinKmh: observedWind?.reading.minKmh,
                            observedWindDirection: observedWind?.reading.directionDegrees,
                            observedWindAgeMinutes: observedWind?.reading.ageMinutes,
                            observedWindHistory: realWindHistory,
                            hasBalise: observedWind != nil,
                            riderMinKmh: themeManager.riderMinWindKmh,
                            riderMaxKmh: themeManager.riderMaxWindKmh,
                            minWaterHeight: tideService.selectedPort.flatMap { SpotConfigStore.shared.config(for: $0.id)?.minWaterHeight },
                            windShoreOrientation: tideService.selectedPort.flatMap { SpotConfigStore.shared.config(for: $0.id)?.shoreOrientation },
                            spotConfig: tideService.selectedPort.flatMap { SpotConfigStore.shared.config(for: $0.id) },
                            sportSetups: activeSportSetups,
                            goWindows: goWindows
                        )

                        // Header superposé en haut
                        VStack {
                            headerSection
                                .padding(.top, 8)
                            Spacer()
                        }

                    }
                    .frame(height: availableHeight)

                // MARK: - Dashboard content
                VStack(spacing: DS.spacingXL) {
                    // Unified ocean dashboard card — fuses tide, weather, activities
                    if !tideService.tideData.isEmpty {
                        if themeManager.curveMode == .surf {
                            // MODE SURF : sous la courbe (conservée), le tableau de bord HOULE « Le Banc »
                            // remplace marée/courant — verdict + note par heure + flèches + rose/table.
                            SurfDashboardCard(
                                forecasts: openMeteoForecasts,
                                spot: tideService.selectedPort.flatMap { SpotConfigStore.shared.config(for: $0.id) },
                                sunTimes: sunTimes,
                                currentTime: currentTime,
                                portTimeZone: portTimeZone
                            )
                            .equatable()
                            .padding(.horizontal, DS.pagePadding)
                            .staggeredAppearance(index: 0, appeared: dashboardAppeared)
                        } else {
                            OceanDashboardCard(
                                tideData: tideService.tideData,
                                currentTime: currentTime,
                                displayedDate: displayedDate,
                                activityScores: activityScores,
                                portTimeZone: portTimeZone
                            )
                            .equatable()
                            .padding(.horizontal, DS.pagePadding)
                            .staggeredAppearance(index: 0, appeared: dashboardAppeared)
                        }
                    }

                    // (Le verdict d'activités vit désormais dans la Vue Activité — calendrier 7 j.
                    //  Sur la TodayView, le seul suivi d'activité est visuel : les rectangles GO du
                    //  mode vent sur la courbe principale. `activityScores` reste calculé pour la
                    //  carte de partage/export.)

                    // Vent observé temps réel (si station proche dispo). Premium.
                    if let obs = observedWind {
                        if premiumManager.canUseRealtimeWind {
                            ObservedWindCard(
                                station: obs.station,
                                reading: obs.reading,
                                distanceKm: obs.distanceKm,
                                predictedKmh: predictedWindKmh,
                                unit: themeManager.windUnit,
                                currentTime: currentTime
                            )
                            .equatable()
                            .padding(.horizontal, DS.pagePadding)
                            .staggeredAppearance(index: 1, appeared: dashboardAppeared)
                        } else {
                            realtimeWindUpsell(station: obs.station, distanceKm: obs.distanceKm)
                                .padding(.horizontal, DS.pagePadding)
                                .staggeredAppearance(index: 1, appeared: dashboardAppeared)
                        }
                        // Jauge de confiance (biais modèle vs réel) — GRATUITE : teaser d'honnêteté
                        // qui incite au premium (voir le vent réel + corriger les fenêtres GO).
                        // Badge informatif du biais local (gratuit) — la PREUVE visible du différenciateur.
                        // L'INTERRUPTEUR de correction vit dans Réglages ▸ Précision (activé par défaut).
                        ForecastTrustBadge(portId: tideService.selectedPort?.id ?? "", unit: themeManager.windUnit)
                            .padding(.horizontal, DS.pagePadding)
                            .staggeredAppearance(index: 2, appeared: dashboardAppeared)
                    }

                    // Météo 7 jours — un seul bandeau scrollable, dense et color-codé
                    if !openMeteoForecasts.isEmpty {
                        WeatherBand7Days(
                            portID: tideService.selectedPort?.id ?? "",
                            forecasts: openMeteoForecasts,
                            tideData: tideService.tideData,
                            currentTime: currentTime,
                            portTimeZone: portTimeZone
                        )
                        .equatable()
                        .padding(.horizontal, DS.pagePadding)
                        .staggeredAppearance(index: 3, appeared: dashboardAppeared)
                    }

                    // Attribution Apple Weather — tout en bas (guideline 5.2.5)
                    Link(destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "apple.logo").font(.system(size: 11))
                            Text("Weather").font(.system(size: 11, weight: .medium))
                            Text("· Données et sources météo")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.top, DS.spacingMD)

                }
                .padding(.top, DS.spacingLG)
                .padding(.bottom, 100)
            }
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if showLoadingBar {
                    TopLoadingBar()
                        .padding(.horizontal, DS.pagePadding)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
                if let errorMessage = currentErrorMessage, errorMessage != dismissedErrorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        onRetry: { Task { await tideService.fetchTideData(forceRefresh: true) } },
                        onDismiss: { dismissedErrorMessage = errorMessage }
                    )
                    .padding(.horizontal, DS.pagePadding)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentErrorMessage)
                }
            }
        }
        .onChange(of: tideService.isLoading) { _, loading in
            loadingBarTask?.cancel()
            if loading {
                // N'afficher la barre QUE si ça dépasse 2 s (cache instantané → rien).
                loadingBarTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { showLoadingBar = true }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.25)) { showLoadingBar = false }
            }
        }
        .task {
            // Cold start : si le chargement est DÉJÀ en cours à l'apparition (onChange ne
            // se déclenche pas), armer quand même la barre des 2 s.
            if tideService.isLoading {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if tideService.isLoading {
                    withAnimation(.easeInOut(duration: 0.25)) { showLoadingBar = true }
                }
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            tideService.refreshTideState()
            // Alerte « le vent s'établit » active → on entretient le rafraîchissement balise
            // (TTL-gated : un vrai fetch ~toutes les 3 min) pour échantillonner la confirmation.
            if let port = tideService.selectedPort,
               WindEstablishingService.hasActiveAlert(forPort: port.id) {
                Task {
                    await WindStationAggregator.shared.refresh(
                        around: CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude))
                }
            }
            // Note : les scores d'activité ne sont PAS recalculés ici (chaque minute) — ils
            // n'alimentent que la carte d'export (à la demande) et changent lentement. Ils sont
            // rafraîchis au changement de port et de marées. Évite un calcul/minute inutile.
            // Garder le curseur "maintenant" centré tant qu'on regarde aujourd'hui.
            // Si l'utilisateur a fait défiler vers un autre jour, on ne le ramène pas.
            if isToday {
                scrollToTodayTrigger.toggle()
            }
        }
        .onChange(of: tideService.selectedPort?.id) { _, _ in
            // Annuler la tâche précédente et recentrer
            portChangeTask?.cancel()
            portChangeTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                scrollToTodayTrigger.toggle()
            }
            // Charger météo & activités pour le nouveau port
            loadPortData()
            // Filet de sécurité : un spot custom dépend des marées d'un port de référence
            // (résolution réseau). Si la vue qui a sélectionné le port a vu son fetch
            // annulé/raté, on garantit ici un (re)chargement fiable. fetchTideData lit le
            // cache d'abord → quasi gratuit si déjà chargé.
            if tideService.selectedPort?.isCustom == true {
                Task { await tideService.fetchTideData() }
            }
        }
        .onChange(of: tideService.tideData) { _, _ in
            updateActivityScores()
            // Les marées arrivent souvent après le changement de port (fetch async) :
            // on (re)calcule alors le tracé solaire pour le bon port.
            if let port = tideService.selectedPort {
                Task { await reloadSunTimes(for: port) }
            }
        }
        .onChange(of: themeManager.curveMode) { _, mode in
            // Hors mode vent → on efface la teinte vent imposée (le scroll ne refire pas
            // forcément). En mode vent, la couleur immédiate vient de tideFlow.tint.
            if mode != .wind { ParticleFlowBus.shared.windTint = nil }
            // Hors surf → on coupe le front de houle (throttle et onChange = scopes différents,
            // les DEUX doivent nettoyer le bus, comme pour windTint).
            if mode != .surf { ParticleFlowBus.shared.swell = nil }
        }
        // Nouvelle mesure de la balise → recalcul du VERDICT + évaluation « le vent s'établit ».
        .onChange(of: observedWind?.reading.date) { _, _ in
            updateActivityScores()
            Task {
                await WindEstablishingService.shared.evaluate(
                    reading: observedWind?.reading,
                    portId: tideService.selectedPort?.id,
                    portName: tideService.selectedPort?.name)
            }
            // Jauge de confiance : échantillon modèle-vs-réel pour ce spot (biais local appris).
            // Le modèle = la prévision « maintenant » d'Open-Meteo (`closestForecastNow`), CAR c'est
            // CE modèle que la courbe + les fenêtres GO consomment et que la correction premium ajuste.
            // ⚠️ TOUJOURS le flux BRUT (jamais `forecastsForDisplay`) sinon boucle de feedback → biais → 0.
            if let obs = observedWind, let model = closestForecastNow()?.windSpeedKmh,
               let pid = tideService.selectedPort?.id {
                ForecastBiasService.shared.record(portId: pid, modelKmh: model,
                    observedKmh: obs.reading.speedAvgKmh, distanceKm: obs.distanceKm, at: obs.reading.date)
                if themeManager.debiasGoEnabled { recomputeGoWindows() }   // garde courbe ↔ fenêtres GO en phase
            }
            // Tracé du vent réel récent : précharge l'archive dense (≈4 h) de la balise Pioupiou sélectionnée.
            if let st = observedWind?.station, st.source == .pioupiou {
                pioupiouService.prefetchArchive(stationId: st.id)
            }
        }
        // Activer/désactiver un sport — ou éditer ses conditions / sa sensibilité — doit recalculer
        // les fenêtres GO de la courbe. Sans ça `goWindows` restait figé (seul `updateActivityScores`
        // le rafraîchissait, câblé uniquement marée/balise/port) → la courbe divergeait du calendrier
        // qui, lui, recalcule son propre plan. (`SportSetup: Equatable` → l'égalité détecte les édits.)
        .onChange(of: activeSportSetups) { _, _ in recomputeGoWindows() }
        // Filet à froid : si les prévisions arrivent APRÈS les marées (ou que le score a court-circuité
        // sur `tideData` vide), on recalcule dès qu'elles sont là. `recomputeGoWindows` a ses propres
        // gardes et lit `allTideData`, indépendamment du early-return de `updateActivityScores`.
        .onChange(of: openMeteoForecasts.count) { _, _ in recomputeGoWindows() }
        // Bascule de la correction premium « avec le réel » → recalcule les fenêtres GO (la courbe, elle,
        // se redessine seule car `forecastsForDisplay` est relue dans le body).
        .onChange(of: themeManager.debiasGoEnabled) { _, _ in recomputeGoWindows() }
        .onAppear {
            loadPortData()
            // Staggered animation
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.3)) {
                dashboardAppeared = true
            }
        }
        .modifier(TodaySheetsModifier(
            tideService: tideService,
            showPortPicker: $showPortPicker,
            showComparison: $showComparison,
            showPremiumPaywall: $showPremiumPaywall
        ))
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Mettre à jour l'heure et recentrer le graphique sur T0
                currentTime = Date()
                scrollToTodayTrigger.toggle()
            }
        }
        } // GeometryReader
    }

    // MARK: - Port Button
    // MARK: - Header Section
    private var headerSection: some View {
        // Colonne gauche (date / heure / coef) à espacement UNIFORME, alignée en haut
        // avec la lune → même respiration entre les 3, le tout remonté.
        HStack(alignment: .top, spacing: DS.spacingMD) {
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                // Date — taille fixe (ne saute pas)
                Text(formattedDate(displayedDate))
                    .font(.system(size: DS.fontTitle3, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                // Heure (hero) + retour à aujourd'hui
                HStack(spacing: 8) {
                    Text(formattedTime(displayedDate))
                        .font(.scaled(size: DS.fontLargeTitle, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    Image(systemName: "arrow.counterclockwise")
                        .font(.scaled(size: DS.fontBody, weight: .semibold))
                        .foregroundStyle(Color.tideHigh.opacity(isToday ? 0 : 0.85))
                        .frame(width: 16)
                        .animation(.easeInOut(duration: 0.2), value: isToday)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isToday {
                        HapticManager.shared.impact(.light)
                        scrollToTodayTrigger.toggle()
                    }
                }

                // Coefficient (accent)
                if let coef = headerCoefficient {
                    let coefColor = Color.coefficientColor(coef)
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.scaled(size: DS.fontFootnote, weight: .semibold))
                            .foregroundStyle(coefColor)
                        Text("Coef")
                            .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(coef)")
                            .font(.scaled(size: DS.fontTitle3, weight: .heavy, design: .rounded))
                            .foregroundStyle(coefColor)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Coefficient du jour : \(coef)")
                }
            }

            Spacer(minLength: DS.spacingSM)

            // Lune (alignée en haut avec la date)
            MoonHeaderView(date: displayedDate)
        }
        .padding(.horizontal, DS.pagePadding)
        .accessibilityElement(children: .contain)
    }

    /// Coefficient du cycle affiché (suit la date/heure scrubée).
    private var headerCoefficient: Int? {
        TideCalculator.currentCoefficient(at: displayedDate, tides: tideService.tideData)
    }

    // MARK: - Helpers
    private func loadPortData() {
        guard let port = tideService.selectedPort else { return }

        // Annuler le chargement précédent : sur des changements de port rapides, la requête
        // d'un port lointain pouvait aboutir APRÈS celle du port courant et écraser météo/
        // soleil/forecasts avec les données du mauvais port (affichées sous le nouveau nom).
        loadDataTask?.cancel()
        loadDataTask = Task { @MainActor in
            // Charger la météo
            await weatherService.fetchWeather(for: port.location)

            // Lever/coucher du soleil (dépend de la plage de marées → recalculé aussi
            // dès que tideData arrive, cf. reloadSunTimes()).
            await reloadSunTimes(for: port)
            // Garde : le port sélectionné est-il toujours `port` ? (sinon on écraserait
            // météo/soleil/forecasts avec les données d'un port abandonné).
            guard !Task.isCancelled, tideService.selectedPort?.id == port.id else { return }

            // Charger les conditions marines
            await marineService.fetchForPort(port)
            guard !Task.isCancelled, tideService.selectedPort?.id == port.id else { return }

            // Charger les prévisions Open-Meteo. Repli sur WeatherKit si vide
            // (réseau / point inland) → le bandeau météo reste toujours affiché.
            let om = await MarineWeatherService.shared.fetchHourlyForecast(for: port)
            guard !Task.isCancelled, tideService.selectedPort?.id == port.id else { return }
            openMeteoForecasts = om.isEmpty
                ? Self.forecastsFromWeatherKit(weatherService.hourlyForecast)
                : om

            // Rafraîchir les stations d'anémomètres temps réel (toutes sources)
            let portCoord = CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude)
            await WindStationAggregator.shared.refresh(around: portCoord)
            guard !Task.isCancelled, tideService.selectedPort?.id == port.id else { return }

            // Données marine + balises désormais en cache → réécrire le snapshot widget (le widget
            // surf lit la houle en cache, le widget vent lit la balise) pour qu'ils s'actualisent dès
            // le 1ᵉʳ affichage d'un spot, sans attendre le prochain cycle de marée.
            tideService.refreshWidgetData()

            // Calculer les scores d'activité
            updateActivityScores()
        }
    }

    /// Recalcule les heures de lever/coucher du soleil pour la plage de marées chargée.
    /// Appelé au changement de port ET à l'arrivée de `tideData` (les marées arrivent
    /// souvent APRÈS le changement de port, surtout pour les ports du monde).
    private func reloadSunTimes(for port: Port) async {
        guard let firstDate = tideService.tideData.first?.date,
              let lastDate = tideService.tideData.last?.date else { return }
        let startOfFirst = calendar.startOfDay(for: firstDate)
        let dayCount = max(calendar.dateComponents([.day], from: startOfFirst, to: lastDate).day ?? 1, 1) + 1
        // SOLEIL = SolarCalculator (local, déterministe, hors quota WeatherKit) — MÊME moteur que le
        // calendrier (cf. ActivityCalendarView) → la porte « jour » du planner GO est identique des deux
        // côtés : la courbe et le calendrier ne peuvent plus diverger aux bords aube/crépuscule.
        var times: [(sunrise: Date, sunset: Date)] = []
        for d in 0..<dayCount {
            if let day = calendar.date(byAdding: .day, value: d, to: startOfFirst),
               let s = SolarCalculator.sunriseSunset(latitude: port.latitude, longitude: port.longitude, date: day) {
                times.append(s)
            }
        }
        sunTimes = times
    }

    // MARK: - Observed wind (Pioupiou)

    /// Station d'anémomètre la plus proche du port (toutes sources), si fraîche < 30 min.
    /// Dépend explicitement de `pioupiouService` et `aviationWeatherService` pour que
    /// SwiftUI redéclenche la vue quand les stations arrivent.
    private var observedWind: (station: WindStation, reading: WindReading, distanceKm: Double)? {
        guard let port = tideService.selectedPort else { return nil }
        _ = pioupiouService.stations       // dépendance pour réactivité
        _ = aviationWeatherService.stations
        _ = weameterService.stations       // une balise weameter plus proche prend le relais
        return WindStationAggregator.shared.nearestReading(for: port)
    }

    /// Teaser premium : une balise est proche mais le vent temps réel est verrouillé.
    private func realtimeWindUpsell(station: WindStation, distanceKm: Double) -> some View {
        Button {
            HapticManager.shared.impact(.light)
            showPremiumPaywall = true
        } label: {
            HStack(spacing: DS.spacingMD) {
                Image(systemName: "wind")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: DS.radiusSM).fill(Color.teal.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Vent en temps réel")
                            .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    Text("Balise « \(station.name) » à \(String(format: "%.1f", locale: Locale.current, distanceKm)) km · Premium")
                        .font(.scaled(size: DS.fontCaption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.spacingLG)
            .sectionCard(cornerRadius: DS.radiusXL)
        }
        .buttonStyle(.plain)
    }

    private var predictedWindKmh: Double? {
        weatherService.currentWeather?.wind.speed.converted(to: .kilometersPerHour).value
    }

    private func updateActivityScores() {
        guard !tideService.tideData.isEmpty else { return }

        // VERDICT TEMPS RÉEL : on injecte la balise (vent réel) + la confiance d'ensemble
        // de l'heure courante → le score reflète la réalité, pas que la prévision.
        let obs = observedWind?.reading
        let observedTuple = obs.map {
            (speedKmh: $0.speedAvgKmh, gustKmh: $0.gustKmh,
             directionDeg: $0.directionDegrees, ageMinutes: $0.ageMinutes)
        }
        activityScores = ActivityScoreService.shared.calculateScores(
            tideData: tideService.tideData,
            weather: weatherService.currentWeather,
            marineConditions: marineService.currentConditions,
            currentTime: currentTime,
            observed: observedTuple,
            windConfidence: closestForecastNow()?.windConfidence,
            // Config du spot sélectionné → le verdict live honore enfin orientation/offshore/
            // exposition/gate de marée (indispensable au surf ; améliore aussi le kite).
            spot: tideService.selectedPort.flatMap { SpotConfigStore.shared.config(for: $0.id) }
        )
        recomputeGoWindows()   // fenêtres GO de la courbe = MÊME source que le calendrier
    }

    /// Calcule TOUTES les fenêtres GO (tous sports) avec le MÊME `ActivityGoPlanner.plan` + scorer
    /// que `ActivityCalendarView` → la courbe (vent + surf) montre exactement les fenêtres du calendrier.
    private func recomputeGoWindows() {
        // Fenêtres GO = fonctionnalité PREMIUM. Hors premium : aucune fenêtre (→ badge 0, pas de
        // rectangles sur la courbe — le mode vent/surf est de toute façon déjà premium).
        guard premiumManager.isPremium else { goWindows = []; return }
        guard !openMeteoForecasts.isEmpty, !activeSportSetups.isEmpty else { goWindows = []; return }
        let tide = tideService.allTideData
        let spot = tideService.selectedPort.flatMap { SpotConfigStore.shared.config(for: $0.id) }
        // Série corrigée par le biais réel SI premium + toggle (sinon brute) → source UNIQUE pour le
        // plan, l'affinage et les étoiles, afin que les fenêtres GO collent à la courbe affichée.
        let baseSeries = forecastsForDisplay
        let plan = ActivityGoPlanner.plan(
            setups: activeSportSetups,
            forecasts: baseSeries, sunTimes: sunTimes,
            tideData: tide,
            from: Date(), days: 7, calendar: calendar,
            scorer: { sport, f, lvl in
                ActivityScoreService.shared.scoreHour(sport: sport, at: f, tideData: tide, spot: spot, riderLevel: lvl)
            }
        )
        // Affinage jour-J : relevés réels (balise vent + bouée houle NDBC) injectés sur l'horizon
        // imminent (≈ maintenant → +2 h). Sans relevé, refinedSeries == openMeteoForecasts.
        let now = Date()
        let obsWind = observedWind?.reading
        let buoy: (wave: WaveReading, distanceKm: Double)? = tideService.selectedPort
            .flatMap { WindStationAggregator.shared.nearestWaveReading(for: $0) }
            .map { (wave: $0.wave, distanceKm: $0.distanceKm) }
        let refinedSeries = ActivityScoreService.shared.refinedForecasts(
            baseSeries, observedWind: obsWind, buoyWave: buoy, now: now)
        let imminentHorizon = now.addingTimeInterval(2 * 3600)

        goWindows = plan.flatMap { day in
            day.lanes.flatMap { lane -> [GoCurveWindow] in
                // Étoiles de qualité pour TOUT sport en mode AUTO (« la surprise du chef ») — moteur
                // par sport via sessionStars (surf = houle, vent/kite/wing/voile = vent).
                let setup = activeSportSetups.first { $0.sport == lane.sport }
                let isAuto = setup?.auto ?? false
                return lane.windows.map { w in
                    let stars = isAuto
                        ? ActivityScoreService.shared.sessionStars(
                            sport: lane.sport, window: (w.start, w.end),
                            forecasts: baseSeries, tideData: tide, spot: spot)
                        : nil
                    // Réinterprétation le jour J : fenêtre imminente (≤ 2 h) + un relevé réel dispo.
                    // (Surf affine houle+vent ; sports de vent affinent le vent — la houle est ignorée
                    //  par leur score, donc no-op.)
                    var refined: Int? = nil
                    var prov: MarineProvenance? = nil
                    if isAuto, w.start <= imminentHorizon, w.end >= now, (obsWind != nil || buoy != nil) {
                        refined = ActivityScoreService.shared.sessionStars(
                            sport: lane.sport, window: (w.start, w.end),
                            forecasts: refinedSeries, tideData: tide, spot: spot)
                        if lane.sport.isSurf, buoy != nil { prov = .buoyAnchored }   // teal = calé bouée (surf)
                    }
                    return GoCurveWindow(start: w.start, end: w.end, sport: lane.sport,
                                         stars: stars, refinedStars: refined, provenance: prov)
                }
            }
        }

        // COURONNER « le meilleur créneau » À VENIR : la fenêtre la mieux notée (plus d'étoiles),
        // la plus proche en cas d'égalité. On ne couronne QUE si elle est vraiment bonne (≥ 3★) →
        // jamais de fausse promesse sur une semaine molle.
        if let peakIdx = goWindows.indices
            .filter({ goWindows[$0].end >= now })
            .max(by: { a, b in
                let sa = goWindows[a].stars ?? 0, sb = goWindows[b].stars ?? 0
                if sa != sb { return sa < sb }
                return goWindows[a].start > goWindows[b].start   // égalité → la plus proche gagne
            }),
           (goWindows[peakIdx].stars ?? 0) >= 3 {
            goWindows[peakIdx].isPeak = true
        }
    }

    // MARK: - WeatherKit → HourlyForecast fallback

    /// Convertit les prévisions horaires WeatherKit en `HourlyForecast` afin que
    /// le bandeau météo reste affiché même quand Open-Meteo renvoie un tableau vide
    /// (réseau, point inland, quota). Les champs houle restent nil (non fournis ici).
    static func forecastsFromWeatherKit(_ hours: [HourWeather]) -> [HourlyForecast] {
        hours.map { h in
            HourlyForecast(
                time: h.date,
                windSpeedKmh: h.wind.speed.converted(to: .kilometersPerHour).value,
                windGustKmh: h.wind.gust?.converted(to: .kilometersPerHour).value,
                windDirection: h.wind.direction.converted(to: .degrees).value,
                temperature: h.temperature.converted(to: .celsius).value,
                weatherCode: wmoCode(from: h.condition),
                waveHeight: nil,
                wavePeriod: nil,
                swellHeight: nil,
                swellPeriod: nil,
                humidity: h.humidity * 100,
                pressure: h.pressure.converted(to: .hectopascals).value,
                uvIndex: Double(h.uvIndex.value),
                precipitationProbability: h.precipitationChance * 100
            )
        }
    }

    /// Mappe une `WeatherCondition` WeatherKit vers un code WMO compris par
    /// `weatherSymbol(_:)`, pour homogénéiser l'affichage des pictos.
    static func wmoCode(from condition: WeatherCondition) -> Int {
        switch condition {
        case .clear, .mostlyClear:                              return 0
        case .partlyCloudy, .mostlyCloudy:                      return 2
        case .cloudy:                                           return 3
        case .foggy, .haze, .smoky:                             return 45
        case .drizzle:                                          return 51
        case .freezingDrizzle:                                  return 56
        case .freezingRain:                                     return 66
        case .rain, .sunShowers:                                return 61
        case .heavyRain:                                        return 65
        case .flurries, .snow, .wintryMix, .sleet:              return 71
        case .heavySnow, .blowingSnow, .blizzard:               return 75
        case .isolatedThunderstorms, .scatteredThunderstorms,
             .thunderstorms, .hurricane, .tropicalStorm:        return 95
        default:                                                return 3
        }
    }
}

// MARK: - Premium Tide Graph View
struct PremiumTideGraphView: View {
    let tideData: [TideData]
    let currentTime: Date
    let screenWidth: CGFloat
    @Binding var scrollToTodayTrigger: Bool
    var sunTimes: [(sunrise: Date, sunset: Date)] = []
    var hourlyForecast: [HourWeather] = []
    var weatherService: WeatherService?
    let onDateChanged: (Date) -> Void
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    /// Mode de rendu de la courbe (classique / vent / surf) — threadé vers PremiumCurveCanvas.
    var curveMode: CurveMode = .classic
    /// Shim rétro-compat interne : le code « mode vent » de cette vue reste valide tel quel.
    private var windMode: Bool { curveMode == .wind }
    var openMeteoForecasts: [HourlyForecast] = []
    var observedWindKmh: Double? = nil
    var observedGustKmh: Double? = nil
    var observedMinKmh: Double? = nil
    var observedWindDirection: Double? = nil
    var observedWindAgeMinutes: Int? = nil
    var observedWindHistory: [WindReading] = []
    var hasBalise: Bool = false
    var riderMinKmh: Double = 12
    var riderMaxKmh: Double = 65
    var minWaterHeight: Double? = nil
    var windShoreOrientation: Double? = nil
    /// Config du spot (orientation/fenêtre de houle) — pilote le « front de houle » des particules (surf).
    var spotConfig: SpotConfig? = nil
    var sportSetups: [SportSetup] = []
    var goWindows: [GoCurveWindow] = []

    @EnvironmentObject private var themeManager: ThemeManager
    private var calendar: Calendar { Calendar.inTimeZone(portTimeZone) }
    private let hoursPerScreen: CGFloat = 12

    // MARK: - Échelle vent fixe (mode vent)

    /// Échelle vent FIXE (ne défile pas) : graduations + libellés à droite, dans l'unité réglée.
    private func windScaleOverlay() -> some View {
        Canvas { ctx, size in
            // Même région + même échelle max que les courbes (cf. PremiumCurveCanvas) → alignés.
            let r = PremiumCurveCanvas.windRegion(size.height)
            let maxW = PremiumCurveCanvas.windScaleMaxKmh(openMeteoForecasts)
            for tk in [maxW, maxW * 2 / 3, maxW / 3] {
                let y = r.top + r.height * (1 - CGFloat(tk / maxW))
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                ctx.draw(Text("\(UnitFormatter.windSpeedInt(tk, unit: themeManager.windUnit))")
                    .font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.45)),
                    at: CGPoint(x: size.width - 7, y: y - 8), anchor: .trailing)
            }
            // Unité juste SOUS la graduation max (la valeur max est dessinée au-dessus du trait).
            ctx.draw(Text(themeManager.windUnit.label).font(.system(size: 8))
                .foregroundColor(.white.opacity(0.32)),
                at: CGPoint(x: size.width - 7, y: r.top + 7), anchor: .trailing)
        }
        .allowsHitTesting(false)
    }

    // Pré-calcul des données — tideData déjà trié par TideService, pas de re-sort
    private var graphData: GraphData {
        let sorted = tideData // déjà trié par date croissante
        let edgePadding: TimeInterval = 7200 // 2h padding: continues the cosine curve beyond data boundaries
        let firstDate = sorted.first?.date ?? currentTime
        let lastDate = sorted.last?.date ?? currentTime
        // Extension virtuelle : demi-période (~6h) pour couvrir le point virtuel de TideMetrics
        let virtualExtension: TimeInterval = sorted.count >= 2
            ? sorted[1].date.timeIntervalSince(sorted[0].date) : 21600
        // Garantir que "now" est toujours dans le graphe, même juste après minuit
        let start = min(firstDate.addingTimeInterval(-virtualExtension), currentTime).addingTimeInterval(-edgePadding)
        // La courbe doit pouvoir AFFICHER toutes les fenêtres GO du plan (7 jours), sinon `windX`
        // cull à droite celles qui tombent au-delà de la dernière marée (le calendrier, lui, les
        // liste toujours → divergence). On étend donc la fin pour couvrir l'horizon GO. La marée
        // s'extrapole en cosinus sur les quelques heures ajoutées (les prédictions vont déjà à ~+7 j).
        let goHorizon = currentTime.addingTimeInterval(7 * 86400)
        let end = max(lastDate.addingTimeInterval(virtualExtension), currentTime, goHorizon).addingTimeInterval(edgePadding)
        let duration = max(end.timeIntervalSince(start), 86400)
        let hours = duration / 3600
        let width = max(CGFloat(hours / hoursPerScreen) * screenWidth, 1)
        return GraphData(
            sortedTides: sorted,
            startDate: start,
            endDate: end,
            totalDuration: duration,
            totalWidth: width
        )
    }

    struct GraphData {
        let sortedTides: [TideData]
        let startDate: Date
        let endDate: Date
        let totalDuration: TimeInterval
        let totalWidth: CGFloat
    }

    var body: some View {
        let data = graphData
        let nowX = currentTimeXPosition(data: data)

        GeometryReader { geometry in
            let viewH = max(geometry.size.height, 1)
            if geometry.size.width <= 0 || geometry.size.height <= 0 {
                Color.clear
            } else {
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        // Canvas de la courbe
                        PremiumCurveCanvas(
                            tideData: tideData,
                            startDate: data.startDate,
                            totalDuration: data.totalDuration,
                            totalWidth: data.totalWidth,
                            currentTime: currentTime,
                            viewHeight: viewH,
                            screenWidth: screenWidth,
                            sunTimes: sunTimes,
                            hourlyForecast: hourlyForecast,
                            weatherService: weatherService,
                            portTimeZone: portTimeZone,
                            curveMode: curveMode,
                            openMeteoForecasts: openMeteoForecasts,
                            observedWindKmh: observedWindKmh,
                            observedGustKmh: observedGustKmh,
                            observedMinKmh: observedMinKmh,
                            observedWindDirection: observedWindDirection,
                            observedWindAgeMinutes: observedWindAgeMinutes,
                            observedWindHistory: observedWindHistory,
                            hasBalise: hasBalise,
                            riderMinKmh: riderMinKmh,
                            riderMaxKmh: riderMaxKmh,
                            minWaterHeight: minWaterHeight,
                            windShoreOrientation: windShoreOrientation,
                            sportSetups: sportSetups,
                            goWindows: goWindows
                        )
                        .frame(width: data.totalWidth, height: viewH)

                        // Marqueur précis pour "maintenant" (pour le scroll)
                        HStack(spacing: 0) {
                            Spacer()
                                .frame(width: nowX)
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("now")
                            Spacer()
                                .frame(width: data.totalWidth - nowX)
                        }
                        .frame(width: data.totalWidth)

                        // Tracking scroll
                        GeometryReader { scrollGeo in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetKey.self,
                                    value: -scrollGeo.frame(in: .named("scroll")).origin.x
                                )
                        }
                        .frame(width: data.totalWidth)
                    }
                }
                .coordinateSpace(name: "scroll")
                // Fade les labels/icônes sur les 30% des bords gauche et droite
                .mask(
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.white.opacity(0.35), .white], startPoint: .leading, endPoint: .trailing)
                            .frame(width: screenWidth * 0.18)
                        Color.white
                        LinearGradient(colors: [.white, .white.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: screenWidth * 0.18)
                    }
                )
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    let bus = ParticleFlowBus.shared
                    // Parallaxe « fluide » des particules (lecture sans @State) — seule
                    // opération réellement par-frame, et c'est une simple affectation.
                    bus.scrollX = offset
                    guard data.totalWidth > 0 else { return }
                    let centerOffset = offset + screenWidth / 2
                    let progress = min(max(centerOffset / data.totalWidth, 0), 1)
                    let date = data.startDate.addingTimeInterval(progress * data.totalDuration)

                    // Throttle MINUTE : tout le travail coûteux (scan O(n) des prévisions
                    // pour la couleur du vent + notification de l'en-tête) n'est fait que
                    // lorsque la minute survolée change — pas 60×/s. Les prévisions sont
                    // horaires, donc la teinte ne change pas à l'intérieur d'une minute :
                    // aucun impact visuel, scroll nettement plus fluide en mode vent.
                    if bus.lastReportedDate == nil ||
                        !Calendar.current.isDate(date, equalTo: bus.lastReportedDate!, toGranularity: .minute) {
                        bus.lastReportedDate = date
                        let centerFc = openMeteoForecasts.min(by: {
                            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
                        })
                        if windMode, let fc = centerFc {
                            bus.windTint = PremiumCurveCanvas.windColorSmooth(fc.windSpeedKmh)
                            bus.swell = nil
                        } else if curveMode == .surf, let fc = centerFc,
                                  let m = SurfHourMetrics.make(
                                      from: fc, spot: spotConfig,
                                      trend: SurfMetrics.swellTrend(in: openMeteoForecasts, around: date)) {
                            // Crest Cadence : front de houle. punch = énergie × exposition (clampée).
                            bus.windTint = nil
                            bus.swell = SwellDrive(
                                period: max(m.dominantSwellPeriod, 4),
                                punch: m.energyIndex / 100 * (0.35 + 0.65 * (m.shoreExposure ?? 1)),
                                bearingDeg: m.dominantSwellDirection,
                                exposure: m.shoreExposure ?? 1,
                                trend: m.swellTrend)
                        } else {
                            bus.windTint = nil
                            bus.swell = nil
                        }
                        onDateChanged(date)
                    }
                }
                .onAppear {
                    // Positionner sur maintenant au lancement (données déjà en cache)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        scrollProxy.scrollTo("now", anchor: .center)
                    }
                }
                .onChange(of: data.totalWidth) { _, newWidth in
                    // Les marées arrivent souvent APRÈS l'onAppear (chargement async) :
                    // dès que la largeur réelle est connue, on recentre sur maintenant.
                    guard newWidth > 1 else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo("now", anchor: .center)
                        }
                    }
                }
                .onChange(of: scrollToTodayTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        scrollProxy.scrollTo("now", anchor: .center)
                    }
                }
                .overlay {
                    // Échelle vent FIXE par-dessus la courbe (mode vent uniquement).
                    if windMode && !openMeteoForecasts.isEmpty {
                        windScaleOverlay()
                    }
                }
            }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Graphique des marées")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Résumé texte du graphique pour VoiceOver : hauteur courante + prochaines marées
    private var accessibilitySummary: String {
        guard let state = TideCalculator.currentState(at: currentTime, sortedTides: tideData) else {
            return "Données de marée non disponibles"
        }
        let trend = state.trend.description.lowercased()
        // Unité de l'utilisateur (m/ft) — VoiceOver annonçait toujours des « mètres ».
        let sys = themeManager.measureSystem
        let unitWord = sys == .imperial ? "pieds" : "mètres"
        var summary = "Hauteur actuelle : \(String(format: "%.1f", locale: Locale.current, UnitFormatter.heightValue(state.currentHeight, system: sys))) \(unitWord), \(trend)."
        let nextTides = tideData.filter { $0.date > currentTime }.prefix(3)
        for tide in nextTides {
            let fmt = SharedFormatters.time.copy(timeZone: portTimeZone)
            let type = tide.isHighTide ? "pleine mer" : "basse mer"
            let time = fmt.string(from: tide.date)
            var line = " Prochaine \(type) à \(time), \(String(format: "%.1f", locale: Locale.current, UnitFormatter.heightValue(tide.height, system: sys))) \(unitWord)"
            if let coef = tide.coefficient {
                line += ", coefficient \(coef)"
            }
            line += "."
            summary += line
        }
        return summary
    }

    // Position X exacte pour l'heure actuelle
    private func currentTimeXPosition(data: GraphData) -> CGFloat {
        let progress = currentTime.timeIntervalSince(data.startDate) / data.totalDuration
        return CGFloat(progress) * data.totalWidth
    }

}

// MARK: - Weather Band 7 Days (pendant bas — météo en blocs-jour, pas de 3 h)
/// Bandeau météo unique scrollable sur 7 jours, groupé par jour : chaque jour =
/// en-tête (nom + coef) + mini-courbe de marée (amplitude) + colonnes toutes les
/// 3 h (heure, condition, température, pluie, vent) color-codées. Séparateurs de
/// jour nets. Rendu lazy + Equatable pour la fluidité (scroll haut non impacté).
/// Offset horizontal du bandeau météo (pour la vibration au changement de jour).
private struct WBScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct WeatherBand7Days: View, Equatable {
    let portID: String
    let forecasts: [HourlyForecast]
    let tideData: [TideData]
    let currentTime: Date
    let portTimeZone: TimeZone
    @EnvironmentObject private var themeManager: ThemeManager

    static func == (lhs: WeatherBand7Days, rhs: WeatherBand7Days) -> Bool {
        // Comparaison par CONTENU (pas count/first/last) : deux ports fetchés sur la même fenêtre
        // (forecast_days/timezone identiques) ont les MÊMES count + heures → un proxy count/heures
        // renvoyait `true` au changement de port et SwiftUI sautait le re-rendu (bandeau figé sur
        // l'ancien port). On compare les valeurs réelles → météo/marée différentes ⇒ recalcul.
        lhs.portID == rhs.portID &&
        lhs.portTimeZone == rhs.portTimeZone &&
        Calendar.current.isDate(lhs.currentTime, equalTo: rhs.currentTime, toGranularity: .hour) &&
        lhs.forecasts == rhs.forecasts &&
        lhs.tideData == rhs.tideData
    }

    // Géométrie du tableau météo empilé : légende d'icônes FIGÉE à gauche + colonnes 3 h.
    private let colW: CGFloat = 50
    private let dayHeaderH: CGFloat = 22
    private let hourH: CGFloat = 16
    private let rowH: CGFloat = 22
    private let legendW: CGFloat = 30

    /// Jour de tête courant (index) — pour vibrer au changement de jour pendant le scroll.
    @State private var lastWeatherDay: Int = -1

    /// Ligne du tableau : une métrique (icône figée à gauche + valeur par créneau 3 h).
    private struct WRow: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let isWeather: Bool
        let text: (HourlyForecast) -> String
        let color: (HourlyForecast) -> Color
    }

    private struct DayData: Identifiable {
        let id: Date
        let label: String
        let coef: Int?
        let slots: [HourlyForecast]
    }

    var body: some View {
        // tideData trié UNE fois ici, partagé par buildDays + chaque mini-courbe
        // (évite ~8 tris O(n log n) par rendu du bandeau).
        let sortedTides = tideData.sorted { $0.date < $1.date }
        let days = buildDays(sortedTides: sortedTides)

        return VStack(alignment: .leading, spacing: DS.spacingMD) {
            HStack(spacing: 8) {
                Text("Météo")
                    .font(.scaled(size: DS.fontTitle3, weight: .bold))
                    .foregroundStyle(.primary)
                Text("7 jours")
                    .font(.scaled(size: DS.fontFootnote, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "hand.draw")
                    .font(.scaled(size: DS.fontCaption2))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            let rows = weatherRows()
            HStack(alignment: .top, spacing: 0) {
                legendColumn(rows)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(days.enumerated()), id: \.element.id) { idx, day in
                            dayColumnGroup(day, rows: rows, isFirst: idx == 0)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: WBScrollOffsetKey.self,
                                               value: g.frame(in: .named("wbScroll")).minX)
                    })
                }
                .coordinateSpace(name: "wbScroll")
                .onPreferenceChange(WBScrollOffsetKey.self) { minX in
                    hapticOnDayChange(offset: -minX, days: days)
                }
            }
        }
        .padding(.top, DS.spacingMD)
    }

    /// Vibration quand le jour de tête change pendant le défilement horizontal du bandeau.
    private func hapticOnDayChange(offset: CGFloat, days: [DayData]) {
        var acc: CGFloat = 0, idx = 0
        for (i, day) in days.enumerated() {
            let groupW = (i == 0 ? 0 : 9) + colW * CGFloat(day.slots.count)   // 9 = séparateur+marge
            if offset < acc + groupW { idx = i; break }
            acc += groupW; idx = i
        }
        if idx != lastWeatherDay {
            if lastWeatherDay >= 0 { HapticManager.shared.impact(.light) }
            lastWeatherDay = idx
        }
    }

    // MARK: Légende d'icônes FIGÉE (à gauche, ne défile pas avec les créneaux)

    private func legendColumn(_ rows: [WRow]) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: dayHeaderH + hourH)   // aligne sous l'en-tête jour + heure
            ForEach(rows) { r in
                Image(systemName: r.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(r.tint)
                    .frame(width: legendW, height: rowH)
            }
        }
        .frame(width: legendW)
        .padding(.trailing, 2)
    }

    // MARK: Groupe de colonnes d'un jour (en-tête jour + créneaux 3 h empilés)

    private func dayColumnGroup(_ day: DayData, rows: [WRow], isFirst: Bool) -> some View {
        HStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Color.glassHighlight.opacity(0.12)).frame(width: 1)
                    .padding(.vertical, 6).padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(day.label)
                        .font(.scaled(size: DS.fontSubheadline, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    if let c = day.coef {
                        Text("\(c)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.coefficientColor(c))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.coefficientColor(c).opacity(0.15)))
                    }
                }
                .frame(height: dayHeaderH, alignment: .leading)
                .padding(.leading, 4)

                HStack(spacing: 0) {
                    ForEach(day.slots, id: \.time) { fc in valueColumn(fc, rows: rows) }
                }
            }
        }
    }

    // MARK: Colonne d'un créneau 3 h (heure + valeurs empilées, alignées sur la légende)

    private func valueColumn(_ fc: HourlyForecast, rows: [WRow]) -> some View {
        let cal = Calendar.inTimeZone(portTimeZone)
        let hour = cal.component(.hour, from: fc.time)
        let isNow = currentTime >= fc.time && currentTime < fc.time.addingTimeInterval(3 * 3600)
        return VStack(spacing: 0) {
            Text("\(hour)h")
                .font(.system(size: 10, weight: isNow ? .heavy : .medium, design: .rounded))
                .foregroundStyle(isNow ? Color.cyan : .secondary)
                .frame(height: hourH)
            ForEach(rows) { r in
                Group {
                    if r.isWeather {
                        Image(systemName: Self.weatherSymbol(fc.weatherCode))
                            .font(.system(size: 15))
                            .symbolRenderingMode(.multicolor)
                    } else {
                        Text(r.text(fc))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(r.color(fc))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(width: colW, height: rowH)
            }
        }
        .frame(width: colW)
        .background(RoundedRectangle(cornerRadius: 8).fill(isNow ? Color.cyan.opacity(0.10) : Color.clear))
    }

    // MARK: Lignes actives du tableau (s'adaptent aux données réellement dispo)

    private func weatherRows() -> [WRow] {
        let u = themeManager.windUnit
        func w(_ kmh: Double) -> String { "\(UnitFormatter.windSpeedInt(kmh, unit: u))" }
        var rows: [WRow] = [
            WRow(id: "sky", icon: "cloud.sun.fill", tint: .secondary, isWeather: true,
                 text: { _ in "" }, color: { _ in .primary }),
            WRow(id: "temp", icon: "thermometer.medium", tint: .orange, isWeather: false,
                 text: { $0.temperature.map { self.tempInt($0) } ?? "—" },
                 color: { $0.temperature.map { self.tempColor($0) } ?? .secondary }),
            WRow(id: "wind", icon: "wind", tint: .cyan, isWeather: false,
                 text: { fc in fc.windGustKmh.map { "\(w(fc.windSpeedKmh))·\(w($0))" } ?? w(fc.windSpeedKmh) },
                 color: { PremiumCurveCanvas.windColorSmooth($0.windSpeedKmh) }),
            WRow(id: "rain", icon: "umbrella.fill", tint: .blue, isWeather: false,
                 text: { let p = Int($0.precipitationProbability ?? 0); return p >= 5 ? "\(p)%" : "·" },
                 color: { self.precipColor(Int($0.precipitationProbability ?? 0)) }),
        ]
        if forecasts.contains(where: { $0.humidity != nil }) {
            rows.append(WRow(id: "hum", icon: "humidity.fill", tint: .cyan, isWeather: false,
                 text: { $0.humidity.map { "\(Int($0.rounded()))%" } ?? "·" }, color: { _ in .cyan }))
        }
        if forecasts.contains(where: { $0.pressure != nil }) {
            rows.append(WRow(id: "press", icon: "barometer", tint: .indigo, isWeather: false,
                 text: { $0.pressure.map { "\(Int($0.rounded()))" } ?? "·" }, color: { _ in .indigo }))
        }
        if forecasts.contains(where: { ($0.uvIndex ?? 0) > 0 }) {
            rows.append(WRow(id: "uv", icon: "sun.max.fill", tint: .yellow, isWeather: false,
                 text: { $0.uvIndex.map { "\(Int($0.rounded()))" } ?? "·" }, color: { _ in .yellow }))
        }
        if forecasts.contains(where: { $0.waveHeight != nil }) {
            rows.append(WRow(id: "wave", icon: "water.waves", tint: .teal, isWeather: false,
                 text: { $0.waveHeight.map { String(format: "%.1f", locale: Locale.current, UnitFormatter.heightValue($0, system: self.themeManager.measureSystem)) } ?? "·" }, color: { _ in .teal }))
        }
        return rows
    }

    // MARK: Data

    private func buildDays(sortedTides: [TideData]) -> [DayData] {
        let cal = Calendar.inTimeZone(portTimeZone)
        let nowHour = (cal.date(bySetting: .minute, value: 0, of: currentTime) ?? currentTime).addingTimeInterval(-1800)
        let end = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: currentTime)) ?? currentTime

        // Pas de 3 h
        let slots = forecasts.filter {
            $0.time >= nowHour && $0.time < end && cal.component(.hour, from: $0.time) % 3 == 0
        }
        let grouped = Dictionary(grouping: slots) { cal.startOfDay(for: $0.time) }

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale.current; dayFmt.timeZone = portTimeZone; dayFmt.dateFormat = "EEE d"

        return grouped.keys.sorted().compactMap { dayStart -> DayData? in
            let s = (grouped[dayStart] ?? []).sorted { $0.time < $1.time }
            guard !s.isEmpty else { return nil }

            let label: String
            if cal.isDateInToday(dayStart) { label = String(localized: "Aujourd'hui") }
            else if cal.isDateInTomorrow(dayStart) { label = String(localized: "Demain") }
            else { label = dayFmt.string(from: dayStart).capitalized }

            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let coef = sortedTides.filter { $0.date >= dayStart && $0.date < dayEnd }.compactMap(\.coefficient).first

            return DayData(id: dayStart, label: label, coef: coef, slots: s)
        }
    }

    // MARK: Helpers (color coding)

    private func tempInt(_ celsius: Double) -> String {
        let v = UnitFormatter.tempValue(celsius, system: themeManager.measureSystem)
        return "\(Int(v.rounded()))°"
    }

    private func tempColor(_ c: Double) -> Color {
        switch c {
        case ..<2:   return Color(red: 0.45, green: 0.65, blue: 1.0)
        case ..<9:   return .cyan
        case ..<15:  return .teal
        case ..<21:  return .green
        case ..<26:  return .yellow
        case ..<31:  return .orange
        default:     return .red
        }
    }

    private func precipColor(_ p: Int) -> Color {
        switch p {
        case ..<30: return .secondary
        case ..<60: return .cyan
        default:    return .blue
        }
    }

    /// Mappe un code WMO (Open-Meteo) vers un symbole SF.
    static func weatherSymbol(_ code: Int?) -> String {
        guard let code else { return "cloud.fill" }
        switch code {
        case 0, 1:           return "sun.max.fill"
        case 2:              return "cloud.sun.fill"
        case 3:              return "cloud.fill"
        case 45, 48:         return "cloud.fog.fill"
        case 51, 53, 55:     return "cloud.drizzle.fill"
        case 56, 57:         return "cloud.sleet.fill"
        case 61, 63, 65:     return "cloud.rain.fill"
        case 66, 67:         return "cloud.sleet.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82:     return "cloud.heavyrain.fill"
        case 85, 86:         return "cloud.snow.fill"
        case 95:             return "cloud.bolt.fill"
        case 96, 99:         return "cloud.bolt.rain.fill"
        default:             return "cloud.fill"
        }
    }
}

// MARK: - Scroll Offset Key
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


// MARK: - Tracking Dot (adaptatif light/dark)
/// Barre de chargement fine indéterminée (balayage néon) affichée en haut de TodayView
/// quand les marées mettent plus de 2 s à arriver (cold start). Style charte (cyan→violet).
private struct TopLoadingBar: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pill = max(w * 0.34, 44)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.glassHighlight.opacity(0.12))
                Capsule()
                    // Bords fondus (transparent → couleur → transparent) : pas d'extrémité dure.
                    .fill(LinearGradient(
                        colors: [.tideHigh.opacity(0), .tideHigh, .tideLow, .tideLow.opacity(0)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: pill)
                    // VA-ET-VIENT doux : la pastille glisse d'un bord à l'autre PUIS revient,
                    // sans saut. easeInOut → décélération à chaque extrémité = virages tout en douceur.
                    .offset(x: sweep ? (w - pill) : 0)
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                    sweep = true
                }
            }
        }
        .frame(height: 3)
        .accessibilityLabel(Text("Chargement des marées"))
    }
}

// Internal (pas `private`) : utilisé par PremiumCurveCanvas, désormais dans son propre fichier.
struct TrackingDotView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.15))
                .frame(width: 24, height: 24)
            Circle()
                .stroke(Color.cyan.opacity(0.4), lineWidth: 1.5)
                .frame(width: 16, height: 16)
            Circle()
                .fill(colorScheme == .dark ? Color.white : Color.cyan)
                .frame(width: 8, height: 8)
                .shadow(color: .cyan, radius: 10)
                .shadow(color: .cyan.opacity(0.3), radius: 2)
        }
    }
}

/// Point de suivi des courbes vent/rafale (mode vent). `filled` = vent (pastille pleine
/// colorée Beaufort) ; sinon rafale (anneau clair, en écho au pointillé).
struct WindTrackDot: View {   // internal : utilisé par PremiumCurveCanvas (fichier séparé)
    let color: Color
    let filled: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 22, height: 22)
            if filled {
                Circle().fill(color).frame(width: 11, height: 11)
                    .shadow(color: color, radius: 5)
                Circle().fill(.white).frame(width: 4, height: 4)
            } else {
                Circle().stroke(color, lineWidth: 2).frame(width: 11, height: 11)
                Circle().fill(color).frame(width: 4, height: 4)
            }
        }
    }
}


// MARK: - Tide Point with Label
struct TidePointWithLabel: View {
    let tide: TideData
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    /// Mode vent : la marée est une fine vague ambiante → point + label réduits et discrets.
    var compact: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeManager: ThemeManager

    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }

    var body: some View {
        ZStack {
            // Point centré exactement sur les coordonnées
            pointView

            // Label positionné au-dessus ou en-dessous
            labelView
                .offset(y: tide.isHighTide ? (compact ? -30 : -45) : (compact ? 24 : 35))
        }
        .opacity(compact ? 0.78 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tide.isHighTide ? "Pleine mer" : "Basse mer") à \(formatTime(tide.date))")
        .accessibilityValue({
            let sys = MeasureSystem(rawValue: UserDefaults.standard.string(forKey: "measureSystem") ?? "") ?? .metric
            return "\(String(format: "%.2f", locale: Locale.current, UnitFormatter.heightValue(tide.height, system: sys))) \(sys == .imperial ? "pieds" : "mètres")"
        }())
    }

    private var pointView: some View {
        let glowR: CGFloat = compact ? 11 : 18
        let halo: CGFloat = compact ? 22 : 36
        let dot: CGFloat = compact ? 8 : 12
        let core: CGFloat = compact ? 3.5 : 5
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            tide.isHighTide ? Color.cyan.opacity(0.7) : Color.purple.opacity(0.7),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: glowR
                    )
                )
                .frame(width: halo, height: halo)

            Circle()
                .fill(tide.isHighTide ? Color.cyan : Color.purple)
                .frame(width: dot, height: dot)
                .shadow(color: tide.isHighTide ? .cyan : .purple, radius: compact ? 5 : 8)

            Circle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.9) : Color.white)
                .frame(width: core, height: core)
        }
    }

    private var labelView: some View {
        VStack(spacing: 2) {
            Text(formatTime(tide.date))
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(.primary)

            Text(UnitFormatter.height(tide.height, system: themeManager.measureSystem))
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .foregroundStyle(tide.isHighTide ? .cyan : .purple)
        }
        .shadow(color: colorScheme == .dark ? .black.opacity(0.5) : .white.opacity(0.8), radius: colorScheme == .dark ? 4 : 6)
    }
}

// MARK: - Curve Scrub State
struct CurveScrubState {
    let offsetX: CGFloat
    let date: Date
    let height: Double
}

// MARK: - Curve Scrub Gesture (UIKit-backed, doesn't block ScrollView)
/// Uses UILongPressGestureRecognizer with cancelsTouchesInView=false
/// so the horizontal ScrollView continues to work for normal scrolling.
/// On long press (0.3s hold), scrub mode activates and scroll is disabled.
struct CurveScrubGesture: UIViewRepresentable {
    let onBegan: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        longPress.minimumPressDuration = 0.3
        longPress.allowableMovement = 8
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: (CGFloat) -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: () -> Void
        weak var parentScrollView: UIScrollView?

        init(onBegan: @escaping (CGFloat) -> Void, onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            if parentScrollView == nil {
                parentScrollView = Self.findScrollView(from: gesture.view)
            }
            let x = gesture.location(in: gesture.view).x
            switch gesture.state {
            case .began:
                parentScrollView?.isScrollEnabled = false
                onBegan(x)
            case .changed:
                onChanged(x)
            case .ended, .cancelled, .failed:
                parentScrollView?.isScrollEnabled = true
                onEnded()
            default: break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        private static func findScrollView(from view: UIView?) -> UIScrollView? {
            var current = view?.superview
            while let v = current {
                if let sv = v as? UIScrollView { return sv }
                current = v.superview
            }
            return nil
        }
    }
}

// MARK: - Unified Time Bar (display-only, gesture handled by CurveScrubGesture)
/// Vertical time indicator on the curve:
/// - At rest: positioned at current time (instant T) with a pulsating dot
/// - When scrubState is non-nil: shows scrub position with tooltip
struct UnifiedTimeBar: View {
    let tideData: [TideData]
    let startDate: Date
    let totalDuration: TimeInterval
    let totalWidth: CGFloat
    let viewHeight: CGFloat
    let currentTime: Date
    let scrubState: CurveScrubState?
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    /// Mode vent : la marée est aplatie → le point « maintenant » suit la même bande basse.
    var windMode: Bool = false
    @EnvironmentObject private var themeManager: ThemeManager

    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }

    @State private var pulse = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Amplitude verticale adaptée à la hauteur d'écran : petit écran → courbe plus
    /// plate (les creux remontent → plus de collision avec le bandeau météo du bas) ;
    /// grand écran → courbe plus ample. La compression est centrée (haut + bas).
    private var amplitudeFactor: CGFloat {
        let t = (viewHeight - 600) / 220        // ~600 (petits écrans) → 0 ; ~820+ → 1
        return min(1.0, max(0.70, 0.70 + 0.30 * t))
    }
    private var marginInset: CGFloat { 0.46 * (1 - amplitudeFactor) / 2 }
    private var topMarginRatio: CGFloat { 0.26 + marginInset }
    private var bottomMarginRatio: CGFloat { 0.28 + marginInset }

    private var nowX: CGFloat {
        let progress = currentTime.timeIntervalSince(startDate) / totalDuration
        return CGFloat(progress) * totalWidth
    }

    private var isScrubbing: Bool { scrubState != nil }
    private var activeX: CGFloat { scrubState?.offsetX ?? nowX }

    var body: some View {
        let tideMetrics = PremiumCurveCanvas.TideMetrics(tideData: tideData)
        let topMargin = viewHeight * topMarginRatio
        let drawHeight = viewHeight - topMargin - viewHeight * bottomMarginRatio

        let displayHeight: Double = {
            if let h = scrubState?.height { return h }
            if let m = tideMetrics { return PremiumCurveCanvas.interpolateOnCurve(at: currentTime, metrics: m) }
            return TideCalculator.interpolatedHeight(at: currentTime, sortedTides: tideData) ?? 0
        }()
        let adjMin = tideMetrics?.adjustedMin ?? 0
        let span = tideMetrics?.span ?? 1
        let normalizedH = span > 0 ? (displayHeight - adjMin) / span : 0.5
        let dotY0 = topMargin + drawHeight * (1 - CGFloat(normalizedH))
        // En mode vent la marée est aplatie : le point « maintenant » (et le curseur de scrub)
        // restent sur la vague aplatie.
        let dotY = windMode
            ? PremiumCurveCanvas.flattenedTideY(dotY0, topMargin: topMargin, drawHeight: drawHeight)
            : dotY0
        let x = activeX

        ZStack {
            // Vertical line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: isScrubbing
                            ? [.clear, Color.glassHighlight.opacity(0.5), Color.glassHighlight.opacity(0.3), .clear]
                            : [.clear, Color.glassHighlight.opacity(0.4), Color.glassHighlight.opacity(0.2), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: isScrubbing ? 1.5 : 1, height: viewHeight * 0.65)
                .position(x: x, y: viewHeight * 0.5)
                .allowsHitTesting(false)

            // Dot on curve
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(isScrubbing ? 0.15 : (pulse ? 0.08 : 0.15)))
                    .frame(width: isScrubbing ? 24 : (pulse ? 28 : 22), height: isScrubbing ? 24 : (pulse ? 28 : 22))

                Circle()
                    .stroke(Color.cyan.opacity(isScrubbing ? 0.4 : 0.25), lineWidth: 1.5)
                    .frame(width: isScrubbing ? 16 : 14, height: isScrubbing ? 16 : 14)

                Circle()
                    .fill(colorScheme == .dark ? Color.white : Color.cyan)
                    .frame(width: isScrubbing ? 8 : 6, height: isScrubbing ? 8 : 6)
                    .shadow(color: .cyan, radius: isScrubbing ? 10 : 6)
                    .shadow(color: .cyan.opacity(0.3), radius: 2)
            }
            .position(x: x, y: dotY)
            .allowsHitTesting(false)

            // Tooltip — only when scrubbing. L'heure dans les 2 modes ; la hauteur de marée
            // seulement en mode classique (en mode vent, les valeurs vent/rafale sont posées
            // sur leurs courbes par windTrackingOverlay).
            if let state = scrubState {
                VStack(spacing: 2) {
                    Text(formatTime(state.date))
                        .font(.scaled(size: DS.fontFootnote, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !windMode {
                        Text(UnitFormatter.height(state.height, system: themeManager.measureSystem, decimals: 2))
                            .font(.scaled(size: DS.fontCaption, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tideHigh)
                    }
                }
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, DS.spacingXS + 2)
                .glassBackground(cornerRadius: DS.radiusSM)
                .position(x: min(max(x, 50), totalWidth - 50), y: max(topMargin - 30, 20))
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }   // accessibilité : pas de pulsation infinie
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Soleil animé (course du soleil sur l'arc)
/// Petit soleil avec rayons qui tournent doucement + léger battement et halo.
/// Posé sur l'arc solaire à l'heure courante → lecture immédiate « course du soleil ».
struct SunArcGlyph: View {
    @State private var rotate = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Halo
            Circle().fill(Color.orange).frame(width: 24, height: 24)
                .blur(radius: 7).opacity(0.45)

            // Rayons (rotation lente + battement)
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [Color.yellow, Color.orange],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2, height: 6)
                    .offset(y: -11)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .scaleEffect(pulse ? 1.12 : 0.94)

            // Cœur
            Circle()
                .fill(RadialGradient(colors: [.white, Color.yellow, Color.orange],
                                     center: .center, startRadius: 0, endRadius: 7))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.orange.opacity(0.5), lineWidth: 0.5))
        }
        .frame(width: 34, height: 34)
        .shadow(color: Color.orange.opacity(0.5), radius: 4)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) { rotate = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Tide Status Widget (tendance + phase lunaire)
// MARK: - Moon Header (en-tête, en haut à droite — sans cadre)
struct MoonHeaderView: View {
    let date: Date

    var body: some View {
        VStack(spacing: 5) {
            MoonPhaseView(date: date)
                .frame(width: 56, height: 56)

            Text(moonPhaseName)
                .font(.scaled(size: DS.fontCaption, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(verbatim: "\(illuminationPercent) %")
                .font(.scaled(size: DS.fontCaption2, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var illuminationPercent: Int {
        Int((MoonPhaseHelper.illumination(for: date) * 100).rounded())
    }

    private var accessibilityLabel: String {
        String(localized: "Phase lunaire : \(moonPhaseName)") + ", \(illuminationPercent) %"
    }

    private var moonPhaseName: String {
        let phase = MoonPhaseHelper.phase(for: date)
        switch phase {
        case 0..<0.03, 0.97...1: return String(localized: "Nouvelle lune")
        case 0.03..<0.22:        return String(localized: "1er croissant")
        case 0.22..<0.28:        return String(localized: "1er quartier")
        case 0.28..<0.47:        return String(localized: "Gibbeuse +")
        case 0.47..<0.53:        return String(localized: "Pleine lune")
        case 0.53..<0.72:        return String(localized: "Gibbeuse -")
        case 0.72..<0.78:        return String(localized: "Dern. quartier")
        default:                 return String(localized: "Dern. croissant")
        }
    }
}

// MARK: - Moon Phase View
struct MoonPhaseView: View {
    let date: Date

    var body: some View {
        let phase = MoonPhaseHelper.phase(for: date)
        let illum = MoonPhaseHelper.illumination(for: date)
        let waxing = phase < 0.5

        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                // Halo lumineux — intensité proportionnelle à l'illumination
                Circle()
                    .fill(Color.white)
                    .blur(radius: d * 0.16)
                    .opacity(0.08 + 0.30 * illum)
                    .scaleEffect(1.16)

                // Disque sombre de base (clair de Terre) + texture très atténuée côté nuit
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.16), Color(white: 0.06)],
                            center: .center, startRadius: 0, endRadius: d * 0.5
                        )
                    )
                moonTexture(d)
                    .opacity(0.10)

                // Partie éclairée — texture réelle masquée par le terminateur
                moonTexture(d)
                    .mask(MoonShape(phase: phase))
                    .overlay(
                        // Lumière rasante : renforce le relief vers le limbe brillant
                        RadialGradient(
                            colors: [Color.white.opacity(0.30), .clear],
                            center: UnitPoint(x: waxing ? 0.66 : 0.34, y: 0.40),
                            startRadius: 0, endRadius: d * 0.62
                        )
                        .blendMode(.softLight)
                        .mask(MoonShape(phase: phase))
                    )

                // Fin liseré sur tout le disque
                Circle()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: max(0.5, d * 0.015))
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    /// Texture lunaire (asset léger 256 px) recadrée plein cercle.
    private func moonTexture(_ d: CGFloat) -> some View {
        Image("MoonTexture")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: d, height: d)
            .scaleEffect(1.10)               // pousse l'éventuel liseré clair hors du cercle
            .clipShape(Circle())
    }
}

// MARK: - Moon Phase Helper (shared)
enum MoonPhaseHelper {
    /// Lunar synodic period in days
    static let synodicMonth: Double = 29.53058867

    /// Returns moon phase as a value between 0 and 1 for the given date.
    /// 0 = new moon, ~0.5 = full moon.
    static func phase(for date: Date) -> Double {
        // Nouvelle lune de référence : 6 janv. 2000 à 18:14 UTC (instant RÉEL de la syzygie,
        // JD 2451550,26). L'ancien ancrage à minuit introduisait ~18 h de biais systématique
        // (0,76 j ≈ 2,6 % du cycle) → détection vives-eaux/mortes-eaux décalée.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let refComponents = DateComponents(year: 2000, month: 1, day: 6, hour: 18, minute: 14)
        let ref = utcCal.date(from: refComponents) ?? Date.distantPast
        let days = date.timeIntervalSince(ref) / 86400
        let phase = (days.truncatingRemainder(dividingBy: synodicMonth)) / synodicMonth
        return phase < 0 ? phase + 1 : phase
    }

    /// Fraction éclairée du disque (0 = nouvelle lune, 1 = pleine lune).
    static func illumination(for date: Date) -> Double {
        (1 - cos(2 * .pi * phase(for: date))) / 2
    }

    /// Vrai si la Lune est croissante (entre nouvelle et pleine lune).
    static func isWaxing(for date: Date) -> Bool { phase(for: date) < 0.5 }

    /// Âge de la Lune en jours depuis la dernière nouvelle lune.
    static func ageDays(for date: Date) -> Double { phase(for: date) * synodicMonth }

    /// Régime de marée induit par la Lune : vives-eaux près des syzygies
    /// (nouvelle/pleine lune), mortes-eaux près des quadratures (quartiers).
    enum TideRegime { case spring, neap, transition }
    static func tideRegime(for date: Date) -> TideRegime {
        let p = phase(for: date)
        let toSyzygy = min(p, abs(p - 0.5), abs(p - 1))
        let toQuarter = min(abs(p - 0.25), abs(p - 0.75))
        if toSyzygy < 0.09 { return .spring }
        if toQuarter < 0.09 { return .neap }
        return .transition
    }
}

/// Région éclairée de la Lune — terminateur **elliptique** physiquement correct.
/// Le bord du disque (limbe brillant) et le terminateur sont deux demi-ellipses
/// tracées en courbes de Bézier cubiques (kappa) → forme exacte, pas d'approximation
/// parabolique. Le terminateur a une demi-largeur horizontale `cos(2π·phase)·r` :
/// = ±r aux syzygies (disque plein/vide), 0 aux quartiers (ligne droite).
struct MoonShape: Shape {
    /// 0 = nouvelle lune, 0.5 = pleine lune, 1 = nouvelle lune.
    let phase: Double

    func path(in rect: CGRect) -> Path {
        let p = phase - floor(phase)
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let waxing = p < 0.5
        let pe = waxing ? p : 1 - p                  // 0…0.5 (illumination équivalente)
        let rx = CGFloat(cos(2 * .pi * pe)) * r      // demi-largeur signée du terminateur
        let kappa: CGFloat = 0.5522847498307936
        let kp = kappa * r                           // poignée verticale
        let kl = kappa * r                           // poignée horizontale du limbe (rx = r)
        let kt = kappa * rx                          // poignée horizontale du terminateur

        var path = Path()
        // Limbe brillant (demi-ellipse rx = r), haut → droite → bas
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addCurve(to: CGPoint(x: c.x + r, y: c.y),
                      control1: CGPoint(x: c.x + kl, y: c.y - r),
                      control2: CGPoint(x: c.x + r, y: c.y - kp))
        path.addCurve(to: CGPoint(x: c.x, y: c.y + r),
                      control1: CGPoint(x: c.x + r, y: c.y + kp),
                      control2: CGPoint(x: c.x + kl, y: c.y + r))
        // Terminateur (demi-ellipse rx signée), bas → milieu → haut
        path.addCurve(to: CGPoint(x: c.x + rx, y: c.y),
                      control1: CGPoint(x: c.x + kt, y: c.y + r),
                      control2: CGPoint(x: c.x + rx, y: c.y + kp))
        path.addCurve(to: CGPoint(x: c.x, y: c.y - r),
                      control1: CGPoint(x: c.x + rx, y: c.y - kp),
                      control2: CGPoint(x: c.x + kt, y: c.y - r))
        path.closeSubpath()

        // Lune décroissante = miroir horizontal (limbe brillant à gauche)
        if !waxing {
            path = path.applying(CGAffineTransform(translationX: 2 * c.x, y: 0).scaledBy(x: -1, y: 1))
        }
        return path
    }
}

// MARK: - Today Sheets Modifier
/// Regroupe les présentations modales de TodayView en un seul modifier — réduit
/// la longueur de la chaîne du `body` (sinon le type-checker Swift abandonne).
private struct TodaySheetsModifier: ViewModifier {
    @ObservedObject var tideService: TideService
    @Binding var showPortPicker: Bool
    @Binding var showComparison: Bool
    @Binding var showPremiumPaywall: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showPortPicker) {
                PortPickerView(tideService: tideService)
                    .presentationDetents([.medium, .large])
                    .sheetBackground()
            }
            .fullScreenCover(isPresented: $showComparison) {
                TideComparisonView(tideService: tideService)
            }
            .sheet(isPresented: $showPremiumPaywall) {
                PremiumPaywallView()
                    .presentationDetents([.large])
                    .sheetBackground()
            }
    }
}

// MARK: - Unified Ocean Dashboard Card
/// Épuré glass card: tide status, current flow, activities.
/// Nom de secteur (8 points) d'une direction (deg, « d'où vient la houle/le vent »).
func compass8(_ deg: Double) -> String {
    let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
    let i = Int((deg.truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
    return dirs[max(0, min(i, 7))]
}

// MARK: - Surf Dashboard (mode surf : remplace marée/courant sous la courbe)

/// Tableau de bord HOULE affiché sous la courbe en mode surf. Met en avant les données qui
/// décident : hauteur · période · sens (boussole), taille au déferlement, vent offshore, eau +
/// combinaison, énergie, pureté. Lit le snapshot marin courant + la config du spot via SurfMetrics.
struct SurfDashboardCard: View, Equatable {
    let forecasts: [HourlyForecast]
    let spot: SpotConfig?
    var sunTimes: [(sunrise: Date, sunset: Date)] = []
    let currentTime: Date
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    @State private var selectedIndex: Int? = nil
    /// Position du doigt sur la bande des heures (effet dock) — nil hors glissement.
    @State private var dragX: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeManager: ThemeManager

    /// Égalité à granularité HEURE (comme OceanDashboardCard) : pendant le scrub / le tick minute,
    /// la carte surf ne recalcule pas son scoring si rien de pertinent n'a changé. Les @State (scrub)
    /// re-rendent la vue indépendamment de cette égalité.
    static func == (lhs: SurfDashboardCard, rhs: SurfDashboardCard) -> Bool {
        let cal = Calendar.inTimeZone(lhs.portTimeZone)
        return lhs.forecasts == rhs.forecasts
            && lhs.spot == rhs.spot
            && lhs.sunTimes.count == rhs.sunTimes.count
            && lhs.sunTimes.first?.sunrise == rhs.sunTimes.first?.sunrise
            && cal.isDate(lhs.currentTime, equalTo: rhs.currentTime, toGranularity: .hour)
            && lhs.portTimeZone == rhs.portTimeZone
    }

    // Heures du JOUR affiché (~5h→21h) triées — l'axe partagé note/flèches.
    private var dayForecasts: [HourlyForecast] {
        let cal = Calendar.inTimeZone(portTimeZone)
        return forecasts
            .filter { cal.isDate($0.time, inSameDayAs: currentTime) }
            .filter { let h = cal.component(.hour, from: $0.time); return h >= 5 && h <= 21 }
            .sorted { $0.time < $1.time }
    }
    private var nowIdx: Int {
        dayForecasts.enumerated().min {
            abs($0.element.time.timeIntervalSince(currentTime)) < abs($1.element.time.timeIntervalSince(currentTime))
        }?.offset ?? 0
    }
    private var effIdx: Int {
        let i = selectedIndex ?? nowIdx
        return dayForecasts.indices.contains(i) ? i : nowIdx
    }
    private var selF: HourlyForecast? { dayForecasts.indices.contains(effIdx) ? dayForecasts[effIdx] : nil }
    private var selMetrics: SurfHourMetrics? {
        selF.flatMap { SurfHourMetrics.make(from: $0, spot: spot, trend: SurfMetrics.swellTrend(in: forecasts, around: $0.time)) }
    }
    private var selGrade: SurfGrade { selF.map { SurfMetrics.grade(for: $0, spot: spot) } ?? .unknown }

    // Couleur de grade = source UNIQUE partagée (SurfGrade.swiftUIColor, dans ColorExtensions) →
    // carte et Today ne peuvent plus diverger.
    private func gradeColor(_ g: SurfGrade) -> Color { g.swiftUIColor }
    private func isDaylight(_ date: Date) -> Bool {
        sunTimes.isEmpty || sunTimes.contains { date >= $0.sunrise && date <= $0.sunset }
    }
    /// Partitions de houle de l'heure sélectionnée (≤3), triées par énergie.
    private var partitions: [(h: Double, t: Double, dir: Double?, energy: Double)] {
        guard let f = selF else { return [] }
        return SurfMetrics.partitions(f).map { (h: $0.height, t: $0.period, dir: $0.direction, energy: $0.energy) }   // source unique
    }
    private var dayMaxBreaking: Double {
        dayForecasts.compactMap { f -> Double? in
            guard let m = SurfHourMetrics.make(from: f, spot: spot) else { return nil }
            return (m.breakingHeight.lowerBound + m.breakingHeight.upperBound) / 2
        }.max() ?? 1
    }
    private func fmtH(_ m: Double) -> String { UnitFormatter.height(m, system: themeManager.measureSystem, decimals: 1) }

    var body: some View {
        VStack(spacing: 16) {
            verdictBar
            ratingStrip
            swellArrowRow
            advancedSwell
            statsGrid
            footer
        }
    }

    // MARK: Verdict (mot honnête, jamais d'étoile)
    private var verdictBar: some View {
        let color = gradeColor(selGrade)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(selGrade.localizedName)
                    .font(.scaled(size: DS.fontTitle2, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                Spacer()
                if let t = selMetrics?.swellTrend, t != .unknown {
                    HStack(spacing: 4) { Image(systemName: t.symbol); Text(t.localizedName) }
                        .font(.scaled(size: DS.fontCaption, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            if let m = selMetrics {
                let r = m.breakingHeight
                let lo = SurfHeightBucket.bucket(forMeters: r.lowerBound).localizedName.lowercased()
                let hi = SurfHeightBucket.bucket(forMeters: r.upperBound).localizedName.lowercased()
                Text("\(lo) → \(hi) · \(fmtH(r.lowerBound))–\(fmtH(r.upperBound)) (estim. modèle)")
                    .font(.scaled(size: DS.fontFootnote)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let pu = SurfMetrics.purity(swellHeight: selF?.swellHeight, windWaveHeight: selF?.windWaveHeight) {
                    pill("houle propre · \(Int((pu * 100).rounded())) %", color: Color.tideLow)
                }
                pill("\(goodHours) h surfables", color: Color.tideHigh, icon: "bolt.fill")
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusLG, style: .continuous).fill(color.opacity(0.14)))
        .padding(.horizontal, DS.spacingLG)
    }
    private var goodHours: Int {
        var n = 0
        for f in dayForecasts where isDaylight(f.time) {
            let g: SurfGrade = SurfMetrics.grade(for: f, spot: spot)
            if g == .clean || g == .firing { n += 1 }
        }
        return n
    }
    private func pill(_ text: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.scaled(size: DS.fontCaption2, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.vertical, 3).padding(.horizontal, 9)
        .background(Capsule().fill(color.opacity(0.18)))
    }

    // MARK: Note par heure (la bande — touche pour scruber)
    private var ratingStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTE PAR HEURE · glisse le doigt")
                .font(.scaled(size: DS.fontCaption2, weight: .medium)).foregroundStyle(.secondary)
            // Bande avec effet DOCK : les heures sous le doigt grandissent (anchor bas, sans
            // décaler les voisines), et le glissement scrube en continu. reduceMotion → pas de
            // grossissement, mais le glissement reste actif.
            GeometryReader { geo in
                let n = max(1, dayForecasts.count)
                let cellW = geo.size.width / CGFloat(n)
                HStack(spacing: 1.5) {
                    ForEach(Array(dayForecasts.enumerated()), id: \.offset) { i, f in
                        let g = SurfMetrics.grade(for: f, spot: spot)
                        let day = isDaylight(f.time)
                        let center = (CGFloat(i) + 0.5) * cellW
                        let dist = dragX.map { abs($0 - center) } ?? .infinity
                        let bump = max(0, 1 - dist / (cellW * 3))          // rayon dock ≈ 3 cellules
                        let scale = reduceMotion ? 1 : 1 + bump * 0.9       // jusqu'à ×1,9 sous le doigt
                        Rectangle()
                            .fill(gradeColor(g).opacity(day ? (i == effIdx ? 1 : 0.6) : 0.22))
                            .frame(height: 16)
                            .overlay(alignment: .top) {
                                if i == nowIdx { Circle().fill(.primary).frame(width: 3, height: 3).offset(y: -5) }
                            }
                            .overlay(i == effIdx ? RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.6), lineWidth: 1) : nil)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .scaleEffect(x: 1, y: scale, anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragX = min(max(0, v.location.x), geo.size.width)
                            let idx = min(n - 1, max(0, Int(v.location.x / cellW)))
                            if idx != selectedIndex { HapticManager.shared.selection(); selectedIndex = idx }
                        }
                        .onEnded { _ in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragX = nil } }
                )
            }
            .frame(height: 32)   // place pour le grossissement (16 × 1,9 ≈ 30) sans rognage
            HStack {
                Text("matin").font(.scaled(size: DS.fontCaption2)).foregroundStyle(.tertiary)
                Spacer()
                Text(selHourLabel).font(.scaled(size: DS.fontCaption2, weight: .medium)).foregroundStyle(.primary)
                Spacer()
                Text("soir").font(.scaled(size: DS.fontCaption2)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DS.spacingLG)
    }
    private var selHourLabel: String {
        guard let f = selF else { return "" }
        return CachedDateFormatter.make("HH'h'", timeZone: portTimeZone).string(from: f.time)
    }

    // MARK: Flèches de houle (jour) — longueur = taille, couleur = période, sens = direction
    private var swellArrowRow: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(dayForecasts.enumerated()), id: \.offset) { _, f in
                arrowGlyph(for: f)
            }
        }
        .frame(height: 30, alignment: .bottom)
        .padding(.horizontal, DS.spacingLG)
    }
    @ViewBuilder private func arrowGlyph(for f: HourlyForecast) -> some View {
        if let m = SurfHourMetrics.make(from: f, spot: spot) {
            let mid = (m.breakingHeight.lowerBound + m.breakingHeight.upperBound) / 2
            let frac = dayMaxBreaking > 0 ? min(1, mid / dayMaxBreaking) : 0
            // Couleur = EXPOSITION du spot (orange vif si la houle est pointée vers le spot,
            // sourde si elle est dans l'ombre) — PAS la période (le rose/bleu par période était
            // illisible ici). La période reste codée dans la rose + le tableau, où le chiffre la nomme.
            // Orientation = direction de la houle ; taille = hauteur au déferlement.
            let expo = m.shoreExposure ?? 1
            // Même glyphe que le bandeau dock + la card carte : flèche de navigation iOS.
            Image(systemName: "location.north.fill")
                .font(.system(size: 8 + 8 * frac))
                .foregroundStyle(Color.orange.opacity(0.35 + 0.55 * expo))
                .rotationEffect(.degrees((m.dominantSwellDirection ?? 0) + 180))
                .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    // MARK: Houles avancées (rose + table des partitions, heure sélectionnée)
    private var advancedSwell: some View {
        HStack(alignment: .center, spacing: 12) {
            swellRose
            partitionTable
        }
        .padding(.horizontal, DS.spacingLG)
    }
    private var swellRose: some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1).frame(width: 84, height: 84)
            Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1).frame(width: 46, height: 46)
            ForEach(Array(partitions.prefix(3).enumerated()), id: \.offset) { i, p in
                let len = 12 + CGFloat(min(1, p.energy / 100)) * 28
                Rectangle()
                    .fill(PremiumCurveCanvas.surfColor(period: p.t))
                    .frame(width: i == 0 ? 3 : 2, height: len)
                    .offset(y: -len / 2)
                    .rotationEffect(.degrees((p.dir ?? 0) + 180))
            }
            Circle().fill(.primary.opacity(0.6)).frame(width: 4, height: 4)
        }
        .frame(width: 84, height: 84)
    }
    private var partitionTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HOULES").font(.scaled(size: DS.fontCaption2, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("indice").font(.scaled(size: DS.fontCaption2)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 3)
            if partitions.isEmpty {
                Text("—").foregroundStyle(.secondary).font(.scaled(size: DS.fontFootnote))
            }
            ForEach(Array(partitions.prefix(3).enumerated()), id: \.offset) { i, p in
                HStack(spacing: 6) {
                    Circle().fill(PremiumCurveCanvas.surfColor(period: p.t)).frame(width: 7, height: 7)
                    Text("\(fmtH(p.h)) · \(Int(p.t.rounded())) s")
                        .font(.scaled(size: DS.fontFootnote, weight: i == 0 ? .medium : .regular))
                        .foregroundStyle(i == 0 ? .primary : .secondary)
                    Spacer()
                    if let d = p.dir {
                        Text("\(compass8(d)) \(Int(d))°").font(.scaled(size: DS.fontCaption2)).foregroundStyle(.secondary)
                    }
                    Text("\(Int(p.energy.rounded()))")
                        .font(.scaled(size: DS.fontFootnote, weight: .medium))
                        .foregroundStyle(i == 0 ? .primary : .secondary).frame(width: 26, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Stats
    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            windCell
            waterCell
            energyCell
            purityCell
        }
        .padding(.horizontal, DS.spacingLG)
    }

    private func statCell(icon: String, label: String, value: String, sub: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(label).font(.scaled(size: DS.fontCaption2, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.scaled(size: DS.fontHeadline, weight: .regular, design: .rounded)).foregroundStyle(.primary)
            if let sub { Text(sub).font(.scaled(size: DS.fontCaption2)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: DS.radiusLG, style: .continuous).fill(Color.glassHighlight.opacity(0.06)))
    }

    private var windCell: some View {
        let unit = themeManager.windUnit
        let w = selF?.windSpeedKmh
        let dir = selF?.windDirection
        var value = "—"; var sub: String? = nil; var good = false
        if let w {
            value = "\(UnitFormatter.windSpeedInt(w, unit: unit)) \(unit.label)"
            if w <= 12 { sub = "glassy"; good = true }
            else if let orient = spot?.shoreOrientation, let dir {
                let off = (orient + 180).truncatingRemainder(dividingBy: 360)
                let d = abs(((dir - off + 540).truncatingRemainder(dividingBy: 360)) - 180)
                if d <= 60 { sub = "offshore · propre"; good = true } else { sub = "onshore · haché" }
            } else { sub = dir.map { compass8($0) } }
        }
        return statCell(icon: "wind", label: "Vent", value: value, sub: sub,
                        tint: good ? Color.tideHigh : .secondary)
    }

    private var waterCell: some View {
        let t = selF?.waterTemperature
        let value = t.map { UnitFormatter.temp($0, system: themeManager.measureSystem) } ?? "—"
        return statCell(icon: "thermometer.medium", label: "Eau", value: value,
                        sub: SurfMetrics.wetsuitAdvice(sst: t), tint: Color.tideHigh)
    }

    private var energyCell: some View {
        var value = "—"; var sub: String? = nil
        if let e = selMetrics?.energyIndex {
            value = "\(Int(e.rounded()))/100"
            sub = e > 60 ? "puissant" : (e > 30 ? "correct" : "faible")
        }
        return statCell(icon: "bolt.fill", label: "Énergie", value: value, sub: sub, tint: Color.tideLow)
    }

    private var purityCell: some View {
        var value = "—"; var sub: String? = nil
        if let pu = SurfMetrics.purity(swellHeight: selF?.swellHeight, windWaveHeight: selF?.windWaveHeight) {
            value = "\(Int((pu * 100).rounded())) %"
            sub = pu > 0.6 ? "houle propre" : "mer du vent"
        }
        return statCell(icon: "water.waves", label: "Pureté", value: value, sub: sub, tint: Color.tideMid)
    }

    // MARK: Footer honnêteté
    private var footer: some View {
        Text((selMetrics?.provenance.label ?? "Houle modèle large (~25 km, offshore)")
             + " · énergie = indice 0–100, pas une puissance")
            .font(.scaled(size: DS.fontCaption2)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.spacingLG)
    }
}

struct OceanDashboardCard: View, Equatable {
    let tideData: [TideData]
    let currentTime: Date
    let displayedDate: Date
    let activityScores: [ActivityScore]
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    @State private var tidePulse = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeManager: ThemeManager

    /// Égalité à la granularité JOUR : pendant un scrub de la courbe dans la même
    /// journée, le dashboard ne se redessine pas (scroll fluide). Il se met à jour
    /// au changement de jour, de minute (timer) ou de données. Les bindings (boutons)
    /// n'affectent pas le rendu → ignorés.
    static func == (lhs: OceanDashboardCard, rhs: OceanDashboardCard) -> Bool {
        let cal = Calendar.inTimeZone(lhs.portTimeZone)
        return lhs.tideData.count == rhs.tideData.count
            && lhs.tideData.first?.date == rhs.tideData.first?.date
            && lhs.tideData.last?.date == rhs.tideData.last?.date
            && cal.isDate(lhs.currentTime, equalTo: rhs.currentTime, toGranularity: .minute)
            && cal.isDate(lhs.displayedDate, inSameDayAs: rhs.displayedDate)
            && lhs.activityScores.map(\.score) == rhs.activityScores.map(\.score)
            && lhs.portTimeZone == rhs.portTimeZone
    }

    private var calendar: Calendar { Calendar.inTimeZone(portTimeZone) }

    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }

    private var tideState: TideCalculator.TideState? {
        TideCalculator.currentState(at: currentTime, sortedTides: tideData)
    }

    private var twelfthsData: TideCalculator.TwelfthsData? {
        TideCalculator.ruleOfTwelfths(at: currentTime, sortedTides: tideData)
    }

    /// Toutes les marées du jour affiché
    private var dayTides: [TideData] {
        let startOfDay = calendar.startOfDay(for: displayedDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return tideData.filter { $0.date >= startOfDay && $0.date < endOfDay }
    }

    var body: some View {
        VStack(spacing: 32) {
            // Hero centré avec glow radial
            tideHeroSection

            // Toutes les marées du jour
            if !dayTides.isEmpty {
                dayTidesSection
            }

            // Courant (redesigné)
            if twelfthsData != nil {
                currentFlowSection
            }
            // Bandeau de scores d'activité retiré : les activités sont désormais gérées
            // dans l'onglet Alertes (Sorties Parfaites / Pêche à pied).
            // Attribution Apple Weather déplacée tout en bas de TodayView.
        }
    }

    // MARK: - Hero: Centered Tide Height + Radial Glow
    @ViewBuilder
    private var tideHeroSection: some View {
        if let state = tideState, let nextTide = state.nextTide {
            let tideColor: Color = nextTide.isHighTide ? .tideHigh : .tideLow

            ZStack {
                // Glow radial derrière le chiffre
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tideColor.opacity(0.18), tideColor.opacity(0.04), .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)
                    .blur(radius: 30)

                VStack(spacing: DS.spacingLG) {
                    // Countdown en haut
                    if let timeToNext = state.timeToNextTide {
                        VStack(spacing: 3) {
                            AnimatedCountdown(interval: timeToNext, color: tideColor)
                            (Text(verbatim: "→ ") + (nextTide.isHighTide ? Text("Pleine mer") : Text("Basse mer")))
                                .font(.scaled(size: DS.fontCaption, weight: .medium))
                                .foregroundStyle(.gray)
                        }
                    }

                    // Grande hauteur au centre (respecte le système d'unités, comme le
                    // reste de la carte — sinon le plus gros chiffre de l'app restait en m
                    // pour les utilisateurs impériaux).
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", locale: Locale.current, UnitFormatter.heightValue(state.currentHeight, system: themeManager.measureSystem)))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(themeManager.measureSystem.heightUnit)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.gray)
                    }

                    // Badge tendance
                    HStack(spacing: 5) {
                        Image(systemName: state.trend.icon)
                            .font(.system(size: 12, weight: .bold))
                        Text(state.trend.localizedDescription)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(tideColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(tideColor.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .stroke(tideColor.opacity(0.2), lineWidth: 0.5)
                            )
                    )

                    // Progress bar marée
                    tideProgressBar(state: state, nextTide: nextTide, color: tideColor)
                        .padding(.horizontal, DS.spacingXL)
                        .padding(.top, DS.spacingSM)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Tide Progress Bar
    private func tideProgressBar(state: TideCalculator.TideState, nextTide: TideData, color: Color) -> some View {
        VStack(spacing: 6) {
            // Prev → Coef → Next
            HStack {
                if let prev = state.previousTide {
                    HStack(spacing: 3) {
                        Image(systemName: prev.isHighTide ? "arrow.up" : "arrow.down")
                            .font(.system(size: 8))
                        Text(UnitFormatter.height(prev.height, system: themeManager.measureSystem))
                            .font(.scaled(size: DS.fontCaption, weight: .medium))
                        Text(formatTime(prev.date))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(prev.isHighTide ? Color.tideHigh : Color.tideLow)
                }

                Spacer()

                if let coef = nextTide.coefficient {
                    Text("\(coef)")
                        .font(.scaled(size: DS.fontCaption, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.coefficientColor(coef))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.coefficientColor(coef).opacity(0.1)))
                }

                Spacer()

                HStack(spacing: 3) {
                    Text(formatTime(nextTide.date))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(UnitFormatter.height(nextTide.height, system: themeManager.measureSystem))
                        .font(.scaled(size: DS.fontCaption, weight: .medium))
                    Image(systemName: nextTide.isHighTide ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(color)
            }

            // Barre avec glow
            GeometryReader { geo in
                let fillWidth = geo.size.width * CGFloat(state.percentToNextTide)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.glassHighlight.opacity(0.05) : Color.black.opacity(0.06))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.7), color.opacity(0.25)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                        .shadow(color: color.opacity(0.3), radius: 8, y: 2)

                    Circle()
                        .fill(colorScheme == .dark ? Color.white : color)
                        .frame(width: 7, height: 7)
                        .shadow(color: color, radius: 5)
                        .offset(x: max(fillWidth - 3.5, 0))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - All Day Tides (timeline)
    private var dayTidesSection: some View {
        let isToday = calendar.isDate(displayedDate, inSameDayAs: currentTime)

        return VStack(spacing: DS.spacingMD) {
            // Titre discret
            HStack {
                Text("Marées du jour")
                    .font(.scaled(size: DS.fontCaption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }

            // Timeline horizontale de toutes les marées
            HStack(spacing: 0) {
                ForEach(Array(dayTides.enumerated()), id: \.offset) { index, tide in
                    let tideColor: Color = tide.isHighTide ? .tideHigh : .tideLow
                    let isPast = tide.date < currentTime
                    // Prochaine marée = première future dont la précédente est passée
                    let isNextTide = isToday
                        && !isPast
                        && (index == 0 || dayTides[index - 1].date < currentTime)

                    VStack(spacing: 6) {
                        // Heure
                        Text(formatTime(tide.date))
                            .font(.scaled(size: DS.fontCaption, weight: isNextTide ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isPast ? .tertiary : (isNextTide ? .primary : .secondary))

                        // Point + ligne
                        HStack(spacing: 0) {
                            if index > 0 {
                                Rectangle()
                                    .fill(isPast ? tideColor.opacity(0.15) : tideColor.opacity(0.08))
                                    .frame(height: 1)
                            }

                            ZStack {
                                // Anneau pulsant pour la prochaine marée
                                if isNextTide {
                                    Circle()
                                        .stroke(tideColor.opacity(tidePulse ? 0.0 : 0.5), lineWidth: 1.5)
                                        .frame(width: tidePulse ? 22 : 12, height: tidePulse ? 22 : 12)

                                    Circle()
                                        .fill(tideColor.opacity(tidePulse ? 0.08 : 0.15))
                                        .frame(width: tidePulse ? 22 : 12, height: tidePulse ? 22 : 12)
                                }

                                Circle()
                                    .fill(isPast ? tideColor.opacity(0.4) : tideColor)
                                    .frame(width: isNextTide ? 10 : 8, height: isNextTide ? 10 : 8)
                                    .shadow(color: isPast ? .clear : tideColor.opacity(0.5), radius: isNextTide ? 6 : 4)
                            }
                            .frame(width: 24, height: 24)

                            if index < dayTides.count - 1 {
                                Rectangle()
                                    .fill(tideColor.opacity(0.08))
                                    .frame(height: 1)
                            }
                        }
                        .frame(height: 24)

                        // Hauteur + flèche
                        VStack(spacing: 2) {
                            if isNextTide {
                                Image(systemName: tide.isHighTide ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(tideColor)
                                    .shadow(color: tideColor.opacity(0.6), radius: 4)
                                    .phaseAnimator([false, true]) { content, phase in
                                        content.offset(y: phase ? -4 : 4)
                                    } animation: { _ in
                                        .easeInOut(duration: 1.8)
                                    }
                            } else {
                                Image(systemName: tide.isHighTide ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(tideColor)
                            }
                            Text(UnitFormatter.height(tide.height, system: themeManager.measureSystem))
                                .font(.system(size: isNextTide ? DS.fontSubheadline : DS.fontCaption, weight: .bold, design: .rounded))
                                .foregroundStyle(isPast ? tideColor.opacity(0.5) : tideColor)
                        }

                        // Coefficient
                        if let coef = tide.coefficient {
                            Text("\(coef)")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.coefficientColor(coef))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.coefficientColor(coef).opacity(0.1))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    tidePulse = true
                }
            }
        }
    }

    // MARK: - Section 2: Courant (barres justifiées pleine largeur)
    @ViewBuilder
    private var currentFlowSection: some View {
        if let data = twelfthsData {
            let flowColor: Color = data.isRising ? .tideHigh : .tideLow

            VStack(spacing: DS.spacingMD) {
                // Titre section — même style que "Marées du jour"
                HStack {
                    Text("Courant")
                        .font(.scaled(size: DS.fontCaption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()

                    // Badge direction
                    HStack(spacing: 4) {
                        Image(systemName: data.isRising ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        (data.isRising ? Text("Montante") : Text("Descendante"))
                            .font(.scaled(size: DS.fontCaption, weight: .semibold))
                    }
                    .foregroundStyle(flowColor)
                }

                // Barres des douzièmes — pleine largeur, justifiées
                HStack(spacing: 5) {
                    ForEach(0..<6, id: \.self) { i in
                        let isActive = data.currentHour == i + 1
                        let isPast = i + 1 < data.currentHour

                        VStack(spacing: 5) {
                            // Label heure
                            Text("H\(i + 1)")
                                .font(.system(size: 9, weight: isActive ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isActive ? flowColor : .init(.tertiaryLabel))

                            // Barre proportionnelle
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    isActive
                                        ? AnyShapeStyle(LinearGradient(
                                            colors: data.isRising ? [.cyan, .blue] : [.purple, .blue],
                                            startPoint: .top, endPoint: .bottom))
                                        : isPast
                                            ? AnyShapeStyle(flowColor.opacity(0.2))
                                            : AnyShapeStyle(colorScheme == .dark ? Color.glassHighlight.opacity(0.07) : Color.black.opacity(0.04))
                                )
                                .frame(height: CGFloat(data.twelfthsPerHour[i]) * 9 + 8)
                                .overlay(
                                    Text("\(data.twelfthsPerHour[i])")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(
                                            isActive ? Color(.label) : (isPast ? Color(.tertiaryLabel) : Color(.secondaryLabel))
                                        )
                                )
                                .shadow(color: isActive ? flowColor.opacity(0.4) : .clear, radius: 6)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                // Pied : débit cumulé
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "water.waves")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Débit cumulé")
                            .font(.scaled(size: DS.fontCaption, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(data.currentFlowTwelfths)")
                            .font(.scaled(size: DS.fontHeadline, weight: .heavy, design: .rounded))
                            .foregroundStyle(flowColor)
                            .monospacedDigit()
                        Text("/12")
                            .font(.scaled(size: DS.fontCaption, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // Attribution Apple Weather déplacée tout en bas de TodayView.
}

#Preview {
    TodayView(tideService: TideService())
        .preferredColorScheme(.dark)
}

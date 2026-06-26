//
//  ContentView.swift
//  Tide It
//
//  Created by Sébastien Maublanc on 18/03/2025.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var tideService = TideService()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var marineService = MarineWeatherService.shared
    @ObservedObject private var liveActivityManager = LiveActivityManager.shared
    @ObservedObject private var goBadge = GoWindowBadge.shared
    @ObservedObject private var premiumManager = PremiumManager.shared
    @EnvironmentObject var alertService: AlertService
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var showPaywall = false
    /// Annonce « 1 mois offert » : affichée une seule fois, après l'onboarding, à qui a le cadeau.
    @State private var showWelcomeOffer = false
    /// Rappel J-7 : « plus qu'une semaine de Premium offert » (une seule fois).
    @State private var showTrialWeekReminder = false
    // Navigation sans barre d'onglets : Today = le hub plein écran, le reste en sheets.
    @State private var showMap = false
    @State private var showCalendar = false
    @State private var showActivities = false
    @State private var showSettings = false
    @State private var showPorts = false
    @State private var showWeekSummary = false
    /// Pastille de feedback éphémère affichée au-dessus du bouton de mode courbe
    /// quand on cycle marée → vent → surf (couleur = accent néon du mode).
    @State private var curvePillVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Conservé pour compatibilité (bindings de MapView/FavoritesView). La navigation
    /// elle-même passe par les sheets : « aller à Aujourd'hui » = fermer la sheet.
    enum AppTab: String, CaseIterable, Hashable {
        case today = "Aujourd'hui"
        case calendar = "Calendrier"
        case map = "Carte"
        case activities = "Activités"
    }

    var body: some View {
        // Today = la vitrine plein écran ; barre de contrôle en verre flottante en bas.
        ZStack(alignment: .bottom) {
            TodayView(tideService: tideService)
                .appBackground()
                .ignoresSafeArea(edges: .bottom)

            glassControlBar
        }
        .preferredColorScheme(themeManager.resolvedColorScheme)
        .sheet(isPresented: $showMap) { mapSheet }
        .sheet(isPresented: $showCalendar) { calendarSheet }
        .sheet(isPresented: $showActivities) { activitiesSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showPorts) { portsSheet }
        // « Résumé 7 jours » : bottom sheet COURTE (comme les autres fenêtres de l'app),
        // hauteur calée sur le contenu via .presentationDetents (dans la vue).
        .sheet(isPresented: $showWeekSummary) {
            let port = tideService.selectedPort
            WeekSummaryView(
                forecasts: port.flatMap { MarineWeatherService.shared.cachedForecast(for: $0) } ?? [],
                portName: port?.name ?? "",
                isSurfSpot: SurfSpotCatalog.shared.spot(id: port?.id ?? "") != nil
            )
            .sheetBackground()
        }
        .onAppear {
            setupTideService()
            // Économie d'énergie : ne jamais bloquer la mise en veille de l'écran.
            UIApplication.shared.isIdleTimerDisabled = false
            maybeShowWelcomeOffer()        // utilisateurs existants : pas d'onboarding → au lancement
            maybeShowTrialWeekReminder()   // rappel J-7 du mois offert
        }
        .onChange(of: locationManager.location) { _, newLocation in
            if let location = newLocation {
                tideService.updateUserLocation(location)
            }
        }
        .onChange(of: tideService.selectedPort?.id) { _, _ in
            let isSurfSpot = SurfSpotCatalog.shared.spot(id: tideService.selectedPort?.id ?? "") != nil
            if isSurfSpot {
                // Arriver sur un SPOT DE SURF (carte OU « Ports & spots ») → bascule AUTO en mode surf :
                // c'est l'intérêt premier d'un spot. Premium requis (même verrou que le bouton courbe).
                if PremiumManager.shared.canUseWindMode, themeManager.curveMode != .surf {
                    withAnimation(DS.defaultSpring) { themeManager.curveMode = .surf }
                }
            } else if themeManager.curveMode == .surf {
                // Quitter un spot de surf en étant en mode surf → repli en mode VENT (jamais coincé sur
                // une courbe surf vide). Le mode surf n'a de sens que sur un spot du catalogue.
                themeManager.curveMode = .wind
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding, locationManager: locationManager)
        }
        // Annonce « 1 mois offert » : après la fin de l'onboarding (nouveaux) ou au lancement (existants).
        .onChange(of: showOnboarding) { _, isShowing in
            if !isShowing { maybeShowWelcomeOffer() }
        }
        // La vérif d'abonnement vient de se résoudre → on (ré)évalue l'offre maintenant que l'état
        // payé est fiable (un abonné existant ne verra donc jamais l'offre).
        .onChange(of: premiumManager.entitlementChecked) { _, done in
            if done { maybeShowWelcomeOffer(); maybeShowTrialWeekReminder() }
        }
        .fullScreenCover(isPresented: $showWelcomeOffer) {
            WelcomeOfferView(isPresented: $showWelcomeOffer)
        }
        // Rappel J-7 : « plus qu'une semaine de Premium offert » → ensuite, abonnement.
        .alert("Plus qu'une semaine de Premium offert", isPresented: $showTrialWeekReminder) {
            Button("Voir l'abonnement") { showPaywall = true }
            Button("Plus tard", role: .cancel) { }
        } message: {
            Text("Profite-en encore quelques jours. Ensuite, le Premium passe sur abonnement — tu pourras continuer quand tu veux.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Rafraîchir le widget quand l'app revient au premier plan
                tideService.refreshWidgetData()
                // Re-vérifier l'abonnement Premium : récupère l'état si un achat/restaure
                // n'a pas été reflété immédiatement (sandbox, relance depuis Xcode…).
                Task { await PremiumManager.shared.checkEntitlement() }
                // Mois offert : annonce d'accueil si pas encore vue, puis rappel J-7 le moment venu.
                maybeShowWelcomeOffer()
                maybeShowTrialWeekReminder()
                // Scan « Pêche à pied » (retiré du périmètre — gardé sous flag).
                if ThemeManager.pecheAPiedEnabled {
                    Task { await PecheAPiedNotifier.maybeScanAndSchedule(tideService: tideService) }
                }
                // Request review after the user returns to the app (positive engagement signal)
                ReviewManager.shared.requestReviewIfAppropriate()
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheet(isPresented: $showPaywall) {
            PremiumPaywallView()
                .presentationDetents([.large])
                .sheetBackground()
        }
    }

    // MARK: - Barre de contrôle flottante (Liquid Glass, remplace la barre d'onglets)

    private var glassControlBar: some View {
        VStack(spacing: 3) {
        HStack(spacing: DS.spacingMD) {
            // Gauche : Carte (sheet depuis le bas)
            glassRoundButton(icon: "map.fill") {
                HapticManager.shared.impact(.light)
                showMap = true
            }
            .accessibilityLabel("Carte")

            Spacer(minLength: 0)

            // Centre : nom du port → menu contextuel (Calendrier / Activités / Partager / Réglages)
            portMenu

            Spacer(minLength: 0)

            // Droite : rendu de la courbe — cycle classique → vent → surf (premium — paywall sinon).
            // Le mode SURF n'est proposé que sur un SPOT DE SURF (catalogue) ; ailleurs (port classique,
            // spot perso sans houle) le cycle le saute : classique → vent → classique.
            glassRoundButton(icon: themeManager.curveMode.buttonIcon,
                             active: themeManager.curveMode != .classic,
                             accent: themeManager.curveMode.accent) {
                HapticManager.shared.impact(.light)
                if PremiumManager.shared.canUseWindMode {
                    let surfAvailable = SurfSpotCatalog.shared.spot(id: tideService.selectedPort?.id ?? "") != nil
                    withAnimation(DS.defaultSpring) {
                        themeManager.curveMode = themeManager.curveMode.next(surfAvailable: surfAvailable)
                    }
                    flashCurvePill()
                } else {
                    showPaywall = true
                }
            }
            .accessibilityLabel("Mode courbe : marée, vent ou surf")
            // Pastille éphémère : confirme le mode actif sans encombrer la barre.
            .overlay(alignment: .top) {
                if curvePillVisible {
                    Text(themeManager.curveMode.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()   // largeur naturelle : ne PAS replier « Marée » sur 2 lignes
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(themeManager.curveMode.accent.opacity(0.92)))
                        .offset(y: -30)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
        }
        // Libellé « Plus d'infos » retiré (abandonné) → les 3 boutons descendent dans l'espace libéré.
        .padding(.bottom, 2)
    }

    private func glassRoundButton(icon: String, active: Bool = false,
                                  accent: Color = Color.tideHigh,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(active ? accent : .primary)
                .frame(width: 52, height: 52)
                .liquidGlass(in: Circle())
                .contentShape(Circle())   // zone de tap fiable (le verre seul rate des taps)
        }
        .buttonStyle(.plain)
    }

    /// Affiche brièvement la pastille du mode courbe, puis la masque.
    /// `reduceMotion` : pas de ressort, simple fondu.
    private func flashCurvePill() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                   : .spring(response: 0.3, dampingFraction: 0.7)) {
            curvePillVisible = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeIn(duration: 0.25)) { curvePillVisible = false }
        }
    }

    private var portMenu: some View {
        Menu {
            Button {
                showPorts = true
            } label: {
                Label("Ports & spots", systemImage: "star.fill")
            }
            Button {
                showCalendar = true
            } label: {
                Label("Calendrier", systemImage: "calendar")
            }
            Button {
                showActivities = true
            } label: {
                // Badge du nombre de fenêtres GO à venir pour le port actif (« Activités : N »).
                Label(goBadge.count > 0 ? "Activités : \(goBadge.count)" : "Activités", systemImage: "sparkles")
            }
            // Résumé 7 jours — tendance vent (+ houle si spot surf) en paysage, d'un coup d'œil.
            Button {
                HapticManager.shared.impact(.light)
                showWeekSummary = true
            } label: {
                Label("Résumé 7 jours", systemImage: "calendar.day.timeline.left")
            }
            // swiftlint:disable:next force_unwrapping — URL littérale, ne peut pas échouer
            ShareLink(item: URL(string: "https://apps.apple.com/fr/app/tide-it-mar%C3%A9es-vent-r%C3%A9el/id6743555259")!) {
                Label("Partager", systemImage: "square.and.arrow.up")
            }
            Button {
                showSettings = true
            } label: {
                Label("Réglages", systemImage: "gearshape.fill")
            }
            Divider()
            // 3 derniers ports/spots consultés — rendus SOUS « Live Activity » (le menu s'ouvre
            // vers le haut → le dernier élément du code apparaît en tête). Tap = on s'y rend.
            ForEach(tideService.recentPorts) { port in
                Button {
                    HapticManager.shared.impact(.light)
                    tideService.selectedPort = port
                    Task { await tideService.fetchTideData() }
                } label: {
                    Label(port.name, systemImage: "clock.arrow.circlepath")
                }
            }
            // Live Activity (Dynamic Island) — déplacée ici depuis l'ancien bouton de Today.
            Button {
                if liveActivityManager.isActive {
                    Task { await liveActivityManager.stop() }
                } else if PremiumManager.shared.canUseLiveActivity {
                    startLiveActivity()
                } else {
                    showPaywall = true
                }
            } label: {
                Label(liveActivityManager.isActive ? "Arrêter la Live Activity" : "Live Activity",
                      systemImage: liveActivityManager.isActive ? "livephoto.slash" : "livephoto")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.tideHigh)
                Text(tideService.selectedPort?.name ?? String(localized: "Choisir un port"))
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .frame(maxWidth: 240)
            .liquidGlass(in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Port : \(tideService.selectedPort?.name ?? "aucun"). Menu de navigation")
    }

    // MARK: - Sheets (toutes les vues s'ouvrent depuis le bas, fermables)

    /// Titre centré (+ port en sous-titre) pour les barres des sheets.
    @ViewBuilder
    private func sheetTitle(_ title: String, showPort: Bool = true) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if showPort, let name = tideService.selectedPort?.name {
                Text(name)
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Carte des Ports : titre centré + croix, la carte dessous. (Slide-down possible.)
    private var mapSheet: some View {
        VStack(spacing: 0) {
            sheetTitle("Carte des Ports", showPort: false)
            .padding(.horizontal, DS.pagePadding)
            .padding(.top, DS.spacingLG)
            .padding(.bottom, DS.spacingSM)

            MapView(
                tideService: tideService,
                locationManager: locationManager,
                selectedTab: Binding(
                    get: { .map },
                    set: { if $0 == .today { showMap = false } }   // « Voir la marée » ferme la carte
                )
            )
        }
        .sheetBackground()
        .presentationDragIndicator(.visible)
    }

    private var calendarSheet: some View {
        NavigationStack {
            CalendarView(tideService: tideService)
                .toolbar {
                    ToolbarItem(placement: .principal) { sheetTitle("Calendrier") }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheetBackground()
        .presentationDragIndicator(.visible)
    }

    private var activitiesSheet: some View {
        NavigationStack {
            AlertsListView(tideService: tideService)
                .toolbar {
                    ToolbarItem(placement: .principal) { sheetTitle("Activités") }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheetBackground()
        .presentationDragIndicator(.visible)
    }

    private var portsSheet: some View {
        NavigationStack {
            FavoritesView(
                tideService: tideService,
                selectedTab: Binding(
                    get: { .map },
                    set: { if $0 == .today { showPorts = false } }   // sélection → retour à Today
                )
            )
            .toolbar {
                ToolbarItem(placement: .principal) { sheetTitle("Ports & spots", showPort: false) }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheetBackground()
        .presentationDragIndicator(.visible)
    }

    private var settingsSheet: some View {
        NavigationStack {
            SettingsView(tideService: tideService)
                .toolbar {
                    ToolbarItem(placement: .principal) { sheetTitle("Réglages", showPort: false) }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheetBackground()
        .presentationDragIndicator(.visible)
    }

    private func closeAllSheets() {
        showMap = false
        showCalendar = false
        showActivities = false
        showSettings = false
        showPorts = false
    }

    /// Démarre la Live Activity (logique déplacée depuis l'ancien bouton de TodayView).
    private func startLiveActivity() {
        guard let state = tideService.cachedTideState
                ?? TideCalculator.currentState(at: Date(), sortedTides: tideService.tideData),
              let portName = tideService.selectedPort?.name else { return }

        let trendString: String
        switch state.trend {
        case .rising: trendString = "rising"
        case .falling: trendString = "falling"
        case .highSlack: trendString = "highSlack"
        case .lowSlack: trendString = "lowSlack"
        }

        let contentState = TideLiveActivityAttributes.ContentState(
            currentHeight: state.currentHeight,
            trend: trendString,
            nextTideDate: state.nextTide?.date ?? Date(),
            nextTideHeight: state.nextTide?.height ?? 0,
            nextTideIsHigh: state.nextTide?.isHighTide ?? true,
            nextTideCoef: state.nextTide?.coefficient,
            tideProgress: state.percentToNextTide,
            curve: LiveActivityManager.curvePoints(from: tideService.tideData)
        )

        liveActivityManager.start(portName: portName, state: contentState)
        // L'état ci-dessus est marée seule (création immédiate). On enrichit aussitôt
        // avec le VENT + la fenêtre GO via le builder complet → le bandeau « mode vent »
        // s'affiche dès le démarrage, sans attendre le prochain rafraîchissement.
        tideService.updateLiveActivity()
    }

    /// Gère les liens `tideit://…` (taps sur les widgets / complications watchOS).
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "tideit" else { return }
        closeAllSheets()   // toutes les destinations affichent d'abord Aujourd'hui
        if url.host == "paywall" {   // tap sur le widget Vent verrouillé (non-premium)
            showPaywall = true
        }
        // Données fraîches à l'ouverture (cache → instantané)
        Task {
            await tideService.fetchTideData()
            tideService.refreshWidgetData()
        }
    }

    /// Présente l'annonce « 1 mois offert » UNE seule fois, après l'onboarding, à qui profite du cadeau.
    /// ⚠️ N'agit qu'APRÈS la vérification d'abonnement (`entitlementChecked`) : un abonné existant a
    /// `paidPremium = true` → `isInWelcomeTrial = false` → JAMAIS l'offre. Sans ce gate, la course
    /// StoreKit pourrait la lui montrer avant que son abonnement soit résolu.
    private func maybeShowWelcomeOffer() {
        guard premiumManager.entitlementChecked else { return }        // état payé fiable d'abord
        guard !showOnboarding else { return }                          // attendre la fin de l'onboarding
        guard premiumManager.isInWelcomeTrial else { return }          // pas d'offre si déjà abonné
        guard !UserDefaults.standard.bool(forKey: "welcomeOfferShown_v1") else { return }
        UserDefaults.standard.set(true, forKey: "welcomeOfferShown_v1")
        showWelcomeOffer = true
    }

    /// Rappel « plus qu'une semaine » du mois offert : une seule fois, quand il reste ≤ 7 j (et que
    /// l'utilisateur n'a pas encore pris l'abonnement). Après, le Premium passe sur abonnement.
    private func maybeShowTrialWeekReminder() {
        guard premiumManager.entitlementChecked else { return }
        guard !showOnboarding, !showWelcomeOffer else { return }
        let pm = premiumManager
        guard pm.isInWelcomeTrial, pm.welcomeTrialDaysRemaining <= 7 else { return }
        guard !UserDefaults.standard.bool(forKey: "welcomeTrialWeekReminderShown_v1") else { return }
        UserDefaults.standard.set(true, forKey: "welcomeTrialWeekReminderShown_v1")
        showTrialWeekReminder = true
    }

    private func setupTideService() {
        tideService.alertService = alertService
        if let location = locationManager.location {
            tideService.updateUserLocation(location)
        }
        Task {
            await tideService.fetchTideData()
            if let port = tideService.selectedPort {
                await marineService.fetchForPort(port)
            }
            // Démarrer le monitoring périodique des alertes
            tideService.startAlertMonitoring()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AlertService())
        .environmentObject(ThemeManager.shared)
}

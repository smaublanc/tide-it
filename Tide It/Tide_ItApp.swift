//
//  Tide_ItApp.swift
//  Tide It
//
//  Created by Sébastien Maublanc on 18/03/2025.
//

import SwiftUI
import UserNotifications
import WidgetKit
import BackgroundTasks
import CoreLocation
import os.log

@main
struct Tide_ItApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var alertService = AlertService()
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        setupAppearance()
        requestNotificationPermissions()
        // Activer WatchConnectivity pour envoyer les données à l'Apple Watch
        _ = WatchSessionManager.shared
        // Track app launch for intelligent review prompting
        ReviewManager.shared.registerLaunch()
    }

    // MARK: - Apparence globale (transparent pour Liquid Glass iOS 26)
    private func setupAppearance() {
        let transparentAppearance = UINavigationBarAppearance()
        transparentAppearance.configureWithTransparentBackground()
        transparentAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        transparentAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        UINavigationBar.appearance().standardAppearance = transparentAppearance
        UINavigationBar.appearance().compactAppearance = transparentAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = transparentAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        // Police de libellé compacte + cohérente → les 4 onglets FR respirent
        // (évite le tassement/troncature de « Aujourd'hui » et « Calendrier »).
        let tabItem = UITabBarItemAppearance()
        tabItem.normal.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 10, weight: .medium)]
        tabItem.selected.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        tabItem.normal.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: 0)
        tabAppearance.stackedLayoutAppearance = tabItem
        tabAppearance.inlineLayoutAppearance = tabItem
        tabAppearance.compactInlineLayoutAppearance = tabItem
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(alertService)
                .environmentObject(themeManager)
                // Support Dynamic Type étendu. Les polices sont désormais scalables
                // via `Font.scaled(...)` et `DS.fontX` (voir FontScaling.swift) :
                // UIFontMetrics scale la taille de base en fonction de la préférence
                // utilisateur. On borne à `accessibility1` pour préserver la mise
                // en page qui repose sur des tailles de composants fixes.
                .dynamicTypeSize(.xSmall ... .accessibility1)
                .task { scheduleWidgetRefresh() }
        }
        .backgroundTask(.appRefresh("seb.Tide-It.widget-refresh")) {
            await handleWidgetRefresh()
        }
    }

    // MARK: - Background Refresh Scheduling

    /// Programme le prochain background refresh (boucle perpétuelle toutes les 30min)
    private func scheduleWidgetRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "seb.Tide-It.widget-refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // 30 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
            appLogger.info("Background refresh programmé dans 30min")
        } catch {
            appLogger.error("Erreur scheduling background refresh: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Widget Refresh

    @Sendable
    private func handleWidgetRefresh() async {
        // Re-scheduler immédiatement pour la prochaine exécution (boucle perpétuelle)
        scheduleWidgetRefresh()

        // Alerte INTELLIGENTE « le vent s'établit » : on rafraîchit la balise du port suivi et
        // on avance la machine à états (notifie si le vent s'est établi). Cadence = iOS.
        await WindEstablishingService.shared.evaluateInBackground()

        // Notif « fenêtre de GO ici » : pour chaque spot abonné, on rafraîchit SA balise et on
        // notifie si le vent du sport est établi sur 20 min. Premium-only et borné aux spots
        // abonnés → coût batterie maîtrisé (cadence de réveil = iOS).
        if WindEstablishingService.hasGoNotifySpots() {
            await WindEstablishingService.shared.evaluateGoWindowsInBackground()
        }

        // Lire les données actuelles
        guard let defaults = WidgetSharedKeys.sharedDefaults,
              let encoded = defaults.data(forKey: WidgetSharedKeys.dataKey),
              let current = try? JSONDecoder().decode(WidgetSharedData.self, from: encoded),
              !current.portName.isEmpty else {
            appLogger.info("Background refresh: aucune donnée existante")
            return
        }

        let now = Date()

        // Résolution autonome depuis allTides (gère le cas overnight)
        let updated = resolvedSharedData(from: current, at: now)

        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: WidgetSharedKeys.dataKey)
            WidgetCenter.shared.reloadTimelines(ofKind: "TideItWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "TideLockScreenWidget")
            appLogger.info("Background refresh: données résolues → \(String(format: "%.2f", updated.currentHeight))m, next: \(updated.nextTideIsHigh ? "PM" : "BM")")
        }

        // Re-programmer les notifications d'alertes avec les données fraîches
        let alerts = (try? JSONDecoder().decode(
            [TideAlert].self,
            from: UserDefaults.standard.data(forKey: "savedTideAlerts") ?? Data()
        )) ?? []
        if !alerts.isEmpty, !current.allTides.isEmpty {
            let tideData = current.allTides.map {
                TideData(date: $0.date, height: $0.height, isHighTide: $0.isHigh, coefficient: $0.coefficient)
            }
            // Port + localisation réels (transportés dans les données partagées) → les
            // alertes sont filtrées sur le bon port et les conditions soleil restent
            // programmables (sinon notifs sur mauvais port + alertes soleil effacées).
            let portLocation = (current.latitude).flatMap { lat in
                (current.longitude).map { lon in CLLocation(latitude: lat, longitude: lon) }
            }
            await NotificationScheduler.reschedule(
                alerts: alerts,
                tideData: tideData,
                portId: current.portId,
                portLocation: portLocation
            )
        }
    }

    /// Demande les autorisations pour les notifications
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if granted {
                appLogger.info("Autorisations de notification accordées")
            } else if let error = error {
                appLogger.error("Erreur autorisation notifications: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - App Delegate (notifications au premier plan + cooldown)

/// Sans `UNUserNotificationCenterDelegate`, iOS SUPPRIME les bannières quand l'app est
/// au premier plan (les alertes live partant avec un trigger ~1 s n'étaient jamais
/// visibles) et le cooldown des alertes programmées ne démarrait jamais.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Notification reçue alors que l'app est au PREMIER PLAN → on l'affiche quand même.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// L'utilisateur a ouvert une notification → démarrer le cooldown de l'alerte.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        // Format : "tideit.alert.<UUID>.<minute>" (les forecast utilisent "...forecast.<id>").
        let parts = id.components(separatedBy: ".")
        if parts.count >= 4, parts[1] == "alert", parts[2] != "forecast",
           let uuid = UUID(uuidString: parts[2]) {
            AlertService.markTriggeredInStore(id: uuid)
        }
    }
}

/// Extension pour faciliter l'accès au système de notification
extension UNUserNotificationCenter {
    /// Vérifie et demande les autorisations si nécessaire
    func ensureAuthorized() async -> Bool {
        let settings = await notificationSettings()

        if settings.authorizationStatus == .authorized {
            return true
        }

        do {
            return try await requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            appLogger.error("Erreur autorisation notifications: \(error.localizedDescription)")
            return false
        }
    }
}

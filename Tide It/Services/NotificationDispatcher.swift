//
//  NotificationDispatcher.swift
//  Tide It
//
//  Extrait de TideService : regroupe toute la logique de notifications locales,
//  de sons et de vibrations. Permet de garder TideService centré sur l'état
//  et les données de marée.
//

import Foundation
import UIKit
import UserNotifications
import os.log

@MainActor
final class NotificationDispatcher {
    static let shared = NotificationDispatcher()

    private init() {}

    /// Envoie une notification locale. Si l'autorisation n'a jamais été demandée,
    /// la demande à l'utilisateur. Ignore silencieusement si refusée.
    func send(title: String, body: String) async {
        // Défense en profondeur : toute notification de l'app est premium (échoue FERMÉ).
        // Un futur appelant de send() ne peut donc pas réintroduire de fuite.
        guard PremiumManager.shared.isPremium else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        } else if settings.authorizationStatus != .authorized {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            appLogger.error("[NotificationDispatcher] Erreur envoi: \(error.localizedDescription)")
        }
    }

    /// Joue un son (stub — à implémenter via AVFoundation si besoin).
    func playSound(named soundName: String) {
        appLogger.debug("[NotificationDispatcher] Jouer le son: \(soundName)")
    }

    /// Déclenche un retour haptique selon le pattern demandé.
    func triggerVibration(pattern: String) {
        switch pattern {
        case "light":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Exécute une action d'alerte (notification, son, vibration).
    func execute(action: AlertAction, for alert: TideAlert) async {
        switch action.type {
        case .notification:
            if let message = action.message {
                await send(title: alert.name, body: message)
            }
        case .sound:
            playSound(named: action.soundName ?? "default")
        case .vibration:
            triggerVibration(pattern: action.vibrationPattern ?? "default")
        }
    }
}

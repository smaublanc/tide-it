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

    /// Résultat d'une demande d'autorisation faite depuis l'INTERFACE (≠ `send`, qui tourne en
    /// arrière-plan et échoue en silence). Permet à un interrupteur de ne pas s'allumer quand
    /// iOS bloque tout — sinon l'app promet des notifications qu'elle ne pourra jamais délivrer.
    enum AuthOutcome { case authorized, denied }

    /// À appeler AVANT d'activer une option qui promet une notification. Demande l'autorisation
    /// si elle n'a jamais été posée ; sinon rend l'état réel. Ne demande jamais deux fois (iOS
    /// ne représente pas la fenêtre système : un refus ne se répare que dans les Réglages iOS).
    func requestAuthorizationFromUI() async -> AuthOutcome {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .authorized : .denied
        default:
            return .denied
        }
    }

    /// Envoie une notification locale. Si l'autorisation n'a jamais été demandée,
    /// la demande à l'utilisateur. Ignore silencieusement si refusée.
    ///
    /// `target` VOYAGE AVEC la notification. Sans lui, ouvrir « Fenêtre de GO à Leucate »
    /// atterrissait sur le port affiché la dernière fois — donc, la plupart du temps, sur un
    /// autre spot que celui dont on venait de parler, sans rien qui indique le créneau annoncé.
    func send(title: String, body: String, target: NotificationTarget? = nil) async {
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
        if let target { content.userInfo = target.userInfo }

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

// MARK: - Cible portée par une notification (ouvrir SUR le bon spot, au bon créneau)

/// Ce qu'une notification doit emporter pour que l'ouvrir signifie quelque chose.
///
/// Avant, `send(title:body:)` ne posait AUCUN `userInfo` : la bannière disait « fenêtre de GO à
/// Leucate », et le tap rouvrait l'app sur le port affiché la fois précédente, sans rien qui
/// désigne le créneau annoncé. L'information était dans la phrase, pas dans la notification.
struct NotificationTarget: Equatable {
    let portId: String
    let portName: String
    /// Sport concerné (rawValue de `WindSport`) — sert à surligner la BONNE lane de la courbe.
    let sport: String?
    /// Bornes du créneau annoncé. nil pour une notification qui ne parle pas d'une fenêtre.
    let start: Date?
    let end: Date?

    /// `userInfo` doit rester du plist : uniquement des types primitifs, jamais de `Date`.
    var userInfo: [String: Any] {
        var d: [String: Any] = ["portId": portId, "portName": portName]
        if let sport { d["sport"] = sport }
        if let start { d["start"] = start.timeIntervalSince1970 }
        if let end   { d["end"]   = end.timeIntervalSince1970 }
        return d
    }

    init(portId: String, portName: String, sport: String? = nil, start: Date? = nil, end: Date? = nil) {
        self.portId = portId; self.portName = portName
        self.sport = sport; self.start = start; self.end = end
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let portId = userInfo["portId"] as? String, !portId.isEmpty else { return nil }
        self.portId = portId
        self.portName = (userInfo["portName"] as? String) ?? ""
        self.sport = userInfo["sport"] as? String
        self.start = (userInfo["start"] as? Double).map(Date.init(timeIntervalSince1970:))
        self.end   = (userInfo["end"]   as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

/// Boîte aux lettres entre le tap sur la notification et l'interface.
///
/// Le tap arrive dans l'AppDelegate, souvent AVANT que la vue principale n'existe (démarrage à
/// froid) : elle ne peut donc pas l'écouter au moment où il se produit. La cible est déposée
/// ici et RESTE en attente jusqu'à ce que quelqu'un la consomme — sinon un lancement depuis une
/// notification, cas le plus fréquent, serait précisément celui qui ne marcherait jamais.
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()
    private init() {}

    @Published private(set) var pending: NotificationTarget?

    func handle(userInfo: [AnyHashable: Any]) {
        guard let target = NotificationTarget(userInfo: userInfo) else { return }
        pending = target
        appLogger.info("[NotificationRouter] ouverture demandée sur \(target.portName)")
    }

    /// Prend la cible ET la retire : elle ne doit agir qu'une fois. Sans ça, revenir au premier
    /// plan rejouerait la navigation et arracherait l'utilisateur à ce qu'il regardait.
    func take() -> NotificationTarget? {
        defer { pending = nil }
        return pending
    }
}

//
//  LiveActivityManager.swift
//  Tide It
//
//  Gère le cycle de vie des Live Activities (Dynamic Island)
//

import ActivityKit
import Foundation
import os.log

@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    @Published var isActive = false

    private var currentActivity: Activity<TideLiveActivityAttributes>?

    /// Nom du port de l'activité EN COURS (attribut figé à la création) → permet de
    /// détecter un changement de port et de redémarrer avec les bons attributs.
    var currentPortName: String? { currentActivity?.attributes.portName }

    private init() {
        // Reprendre une activité existante au lancement
        if let existing = Activity<TideLiveActivityAttributes>.activities.first {
            currentActivity = existing
            isActive = true
        }
    }

    // MARK: - Start

    func start(portName: String, state: TideLiveActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            appLogger.info("LiveActivity: activités non autorisées")
            return
        }

        // Arrêter l'ANCIENNE en capturant l'instance : sinon le Task async (non awaité) pouvait
        // terminer la NOUVELLE activité — `currentActivity` réassigné juste après par Activity.request,
        // puis `stop()` terminait `currentActivity` devenu la nouvelle. On nulle d'abord, on arrête l'ancienne à part.
        if let old = currentActivity {
            currentActivity = nil
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }

        let attributes = TideLiveActivityAttributes(portName: portName)
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 30 * 60))

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            currentActivity = activity
            isActive = true
            appLogger.info("LiveActivity: démarrée pour \(portName)")
        } catch {
            appLogger.error("LiveActivity: erreur démarrage: \(error.localizedDescription)")
        }
    }

    // MARK: - Update

    func update(state: TideLiveActivityAttributes.ContentState) async {
        guard let activity = currentActivity else { return }

        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 30 * 60))

        await activity.update(content)
        appLogger.debug("LiveActivity: mise à jour → \(String(format: "%.1fm", state.currentHeight)) \(state.trend)")
    }

    // MARK: - Stop

    func stop() async {
        guard let activity = currentActivity else { return }

        await activity.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
        isActive = false
        appLogger.info("LiveActivity: arrêtée")
    }

    // MARK: - Helpers

    /// Crée un ContentState depuis les données de marée actuelles
    static func makeState(from tideState: (
        currentHeight: Double,
        trend: String,
        nextTideDate: Date,
        nextTideHeight: Double,
        nextTideIsHigh: Bool,
        nextTideCoef: Int?,
        progress: Double
    )) -> TideLiveActivityAttributes.ContentState {
        TideLiveActivityAttributes.ContentState(
            currentHeight: tideState.currentHeight,
            trend: tideState.trend,
            nextTideDate: tideState.nextTideDate,
            nextTideHeight: tideState.nextTideHeight,
            nextTideIsHigh: tideState.nextTideIsHigh,
            nextTideCoef: tideState.nextTideCoef,
            tideProgress: tideState.progress
        )
    }

    /// Extrema de marée (PM/BM) autour de « maintenant » pour tracer la courbe signature
    /// dans la Live Activity. Fenêtre ±9 h, plafonnée à 8 points (payload léger).
    nonisolated static func curvePoints(
        from tideData: [TideData],
        around now: Date = Date()
    ) -> [TideLiveActivityAttributes.CurvePoint] {
        let window: TimeInterval = 9 * 3600
        return tideData
            .filter { abs($0.date.timeIntervalSince(now)) <= window }
            .sorted { $0.date < $1.date }
            .prefix(8)
            .map { TideLiveActivityAttributes.CurvePoint(t: $0.date, h: $0.height, high: $0.isHighTide) }
    }
}

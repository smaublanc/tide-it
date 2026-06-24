//
//  ReviewManager.swift
//  Tide It
//
//  Intelligent review prompt using SKStoreReviewController
//  Requests a review only after meaningful engagement thresholds.
//

import StoreKit
import SwiftUI
import os.log

@MainActor
final class ReviewManager {
    static let shared = ReviewManager()

    // MARK: - Thresholds

    private enum Threshold {
        static let minimumLaunches = 3
        static let daysSinceFirstLaunch = 7
        static let daysBetweenReviewRequests = 90
    }

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let launchCount = "reviewLaunchCount"
        static let firstLaunchDate = "reviewFirstLaunchDate"
        static let lastReviewRequestDate = "reviewLastRequestDate"
    }

    // MARK: - State (backed by UserDefaults)

    private var launchCount: Int {
        get { UserDefaults.standard.integer(forKey: Keys.launchCount) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.launchCount) }
    }

    private var firstLaunchDate: Date? {
        get { UserDefaults.standard.object(forKey: Keys.firstLaunchDate) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.firstLaunchDate) }
    }

    private var lastReviewRequestDate: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastReviewRequestDate) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastReviewRequestDate) }
    }

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Call on every app launch to increment the counter and record the first launch date.
    func registerLaunch() {
        if firstLaunchDate == nil {
            firstLaunchDate = Date()
            appLogger.info("[ReviewManager] First launch date recorded")
        }
        launchCount += 1
        appLogger.debug("[ReviewManager] Launch count: \(self.launchCount)")
    }

    /// Request an App Store review if engagement thresholds are met.
    func requestReviewIfAppropriate() {
        let now = Date()

        // 1. Minimum launch count
        guard launchCount >= Threshold.minimumLaunches else {
            appLogger.debug("[ReviewManager] Skipped: launch count \(self.launchCount) < \(Threshold.minimumLaunches)")
            return
        }

        // 2. Minimum days since first launch
        if let firstDate = firstLaunchDate {
            let daysSinceFirst = Calendar.current.dateComponents([.day], from: firstDate, to: now).day ?? 0
            guard daysSinceFirst >= Threshold.daysSinceFirstLaunch else {
                appLogger.debug("[ReviewManager] Skipped: \(daysSinceFirst) days since first launch < \(Threshold.daysSinceFirstLaunch)")
                return
            }
        }

        // 3. Cooldown since last review request
        if let lastRequest = lastReviewRequestDate {
            let daysSinceLastRequest = Calendar.current.dateComponents([.day], from: lastRequest, to: now).day ?? 0
            guard daysSinceLastRequest >= Threshold.daysBetweenReviewRequests else {
                appLogger.debug("[ReviewManager] Skipped: \(daysSinceLastRequest) days since last request < \(Threshold.daysBetweenReviewRequests)")
                return
            }
        }

        // All conditions met — request review
        lastReviewRequestDate = now
        appLogger.info("[ReviewManager] Requesting App Store review")

        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            AppStore.requestReview(in: scene)
        }
    }
}

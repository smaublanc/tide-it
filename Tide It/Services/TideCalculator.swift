//
//  TideCalculator.swift
//  Tide It
//
//  Calculs avancés pour les marées (interpolation, prédiction, tendance)
//

import Foundation

struct TideCalculator {

    // MARK: - Coefficient du cycle en cours

    /// Coefficient de la pleine mer (porteuse du coef) la plus proche de `date`.
    /// Reflète le cycle de marée EN COURS et se met à jour quand on change de cycle,
    /// contrairement à « le premier coef du jour » qui reste figé toute la journée.
    static func currentCoefficient(at date: Date, tides: [TideData]) -> Int? {
        tides
            .lazy
            .filter { $0.isHighTide && $0.coefficient != nil }
            .min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?
            .coefficient
    }

    // MARK: - Current Tide State

    struct TideState {
        let currentHeight: Double
        let trend: TideTrend
        let percentToNextTide: Double
        let previousTide: TideData?
        let nextTide: TideData?
        let timeToNextTide: TimeInterval?

        enum TideTrend {
            case rising
            case falling
            case highSlack  // Étale haute
            case lowSlack   // Étale basse

            var description: String {
                switch self {
                case .rising: return "Montante"
                case .falling: return "Descendante"
                case .highSlack: return "Étale haute"
                case .lowSlack: return "Étale basse"
                }
            }

            /// Version localisée pour l'affichage (`description` reste en français pour la logique interne).
            var localizedDescription: String {
                switch self {
                case .rising: return String(localized: "Montante")
                case .falling: return String(localized: "Descendante")
                case .highSlack: return String(localized: "Étale haute")
                case .lowSlack: return String(localized: "Étale basse")
                }
            }

            var icon: String {
                switch self {
                case .rising: return "arrow.up"
                case .falling: return "arrow.down"
                case .highSlack, .lowSlack: return "equal"
                }
            }
        }
    }

    // MARK: - Recherche binaire des marées encadrantes (O(log n) au lieu de O(n))

    /// Trouve la marée précédente et suivante par recherche binaire
    /// Les données doivent être triées par date croissante
    private static func findBracketingTides(at date: Date, in sorted: [TideData]) -> (previous: TideData?, next: TideData?) {
        guard !sorted.isEmpty else { return (nil, nil) }

        // Recherche binaire : trouver l'index de la première marée APRÈS date
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].date <= date {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // lo = index de la première marée strictement après date
        let previous = lo > 0 ? sorted[lo - 1] : nil
        let next = lo < sorted.count ? sorted[lo] : nil
        return (previous, next)
    }

    // MARK: - Interpolation

    /// Calcule la hauteur de marée à un instant donné par interpolation cosinus
    /// - Parameters:
    ///   - date: Date pour laquelle calculer la hauteur
    ///   - tides: Données de marées (seront triées internement)
    /// - Returns: Hauteur interpolée
    static func interpolatedHeight(at date: Date, tides: [TideData]) -> Double? {
        interpolatedHeight(at: date, sortedTides: tides.sorted { $0.date < $1.date })
    }

    /// Variante pré-triée — évite le tri O(n log n) quand les données sont déjà ordonnées
    static func interpolatedHeight(at date: Date, sortedTides: [TideData]) -> Double? {
        guard sortedTides.count >= 2 else { return nil }

        let (previous, next) = findBracketingTides(at: date, in: sortedTides)

        guard let prev = previous, let nxt = next else {
            return previous?.height ?? next?.height
        }

        // Interpolation cosinus (règle des douzièmes simplifiée)
        let duration = nxt.date.timeIntervalSince(prev.date)
        guard duration > 0 else { return prev.height }

        let progress = date.timeIntervalSince(prev.date) / duration
        let cosProgress = (1 - cos(progress * .pi)) / 2

        return prev.height + (nxt.height - prev.height) * cosProgress
    }

    /// Calcule l'état complet de la marée à un instant donné
    static func currentState(at date: Date, tides: [TideData]) -> TideState? {
        currentState(at: date, sortedTides: tides.sorted { $0.date < $1.date })
    }

    /// Variante pré-triée — évite le tri O(n log n) quand les données sont déjà ordonnées
    static func currentState(at date: Date, sortedTides: [TideData]) -> TideState? {
        guard sortedTides.count >= 2 else { return nil }

        let (previous, next) = findBracketingTides(at: date, in: sortedTides)

        guard let prev = previous else { return nil }

        // Calculer la hauteur actuelle
        let currentHeight: Double
        let percentToNext: Double
        let trend: TideState.TideTrend

        if let nxt = next {
            let duration = nxt.date.timeIntervalSince(prev.date)
            guard duration > 0 else { return nil }

            let elapsed = date.timeIntervalSince(prev.date)
            let progress = elapsed / duration
            percentToNext = progress

            // Interpolation cosinus
            let cosProgress = (1 - cos(progress * .pi)) / 2
            currentHeight = prev.height + (nxt.height - prev.height) * cosProgress

            // Déterminer la tendance. ⚠️ Près d'un bord, l'étale dépend de QUELLE marée
            // on approche : à progress→0 c'est la précédente, à progress→1 la suivante.
            // (L'ancien code utilisait prev des deux côtés → « étale basse » affichée
            //  juste avant chaque pleine mer.)
            if progress < 0.05 {
                trend = prev.isHighTide ? .highSlack : .lowSlack
            } else if progress > 0.95 {
                trend = nxt.isHighTide ? .highSlack : .lowSlack
            } else if nxt.isHighTide {
                trend = .rising
            } else {
                trend = .falling
            }
        } else {
            currentHeight = prev.height
            percentToNext = 1.0
            trend = prev.isHighTide ? .highSlack : .lowSlack
        }

        return TideState(
            currentHeight: currentHeight,
            trend: trend,
            percentToNextTide: percentToNext,
            previousTide: previous,
            nextTide: next,
            timeToNextTide: next?.date.timeIntervalSince(date)
        )
    }

    // MARK: - Statistics

    /// Calcule les statistiques pour une série de marées (1 seule passe)
    static func statistics(for tides: [TideData]) -> TideStatistics {
        var highSum = 0.0, lowSum = 0.0
        var highCount = 0, lowCount = 0
        var maxHigh = -Double.infinity, minLow = Double.infinity
        var coefSum = 0, coefCount = 0

        for tide in tides {
            if tide.isHighTide {
                highSum += tide.height
                highCount += 1
                if tide.height > maxHigh { maxHigh = tide.height }
                if let c = tide.coefficient {
                    coefSum += c
                    coefCount += 1
                }
            } else {
                lowSum += tide.height
                lowCount += 1
                if tide.height < minLow { minLow = tide.height }
            }
        }

        let avgHigh = highCount > 0 ? highSum / Double(highCount) : 0
        let avgLow = lowCount > 0 ? lowSum / Double(lowCount) : 0
        let finalMaxHigh = maxHigh == -Double.infinity ? 0 : maxHigh
        let finalMinLow = minLow == Double.infinity ? 0 : minLow
        let avgCoef: Double? = coefCount > 0 ? Double(coefSum) / Double(coefCount) : nil

        return TideStatistics(
            averageHighTide: avgHigh,
            averageLowTide: avgLow,
            maxHighTide: finalMaxHigh,
            minLowTide: finalMinLow,
            tidalRange: avgHigh - avgLow,
            averageCoefficient: avgCoef
        )
    }

    struct TideStatistics {
        let averageHighTide: Double
        let averageLowTide: Double
        let maxHighTide: Double
        let minLowTide: Double
        let tidalRange: Double
        let averageCoefficient: Double?
    }

    // MARK: - Rule of Twelfths

    struct TwelfthsData {
        let currentHour: Int               // 1-6 : heure de marée en cours
        let twelfthsPerHour: [Int]         // [1, 2, 3, 3, 2, 1]
        let currentFlowTwelfths: Int       // Douzièmes de débit pour l'heure en cours
        let isRising: Bool                 // Marée montante ou descendante
        let progressPercent: Double        // Progression 0-100 entre prev et next
        let estimatedFlowMeters: Double?   // Variation de hauteur estimée cette heure
        let totalRange: Double             // Marnage total prev → next
    }

    /// Calcule la position dans la règle des douzièmes
    static func ruleOfTwelfths(at date: Date, tides: [TideData]) -> TwelfthsData? {
        ruleOfTwelfths(at: date, sortedTides: tides.sorted { $0.date < $1.date })
    }

    /// Variante pré-triée — évite le tri O(n log n)
    static func ruleOfTwelfths(at date: Date, sortedTides: [TideData]) -> TwelfthsData? {
        guard sortedTides.count >= 2 else { return nil }

        let (previous, next) = findBracketingTides(at: date, in: sortedTides)

        guard let prev = previous, let nxt = next else { return nil }

        let duration = nxt.date.timeIntervalSince(prev.date)
        guard duration > 0 else { return nil }

        let elapsed = date.timeIntervalSince(prev.date)
        let progress = elapsed / duration

        // Diviser en 6 heures de marée
        let hourFraction = progress * 6.0
        let currentHour = max(1, min(6, Int(hourFraction) + 1))

        // Règle des douzièmes : 1-2-3-3-2-1
        let twelfths = [1, 2, 3, 3, 2, 1]
        let currentFlowTwelfths = twelfths[currentHour - 1]

        let isRising = nxt.height > prev.height
        let totalRange = abs(nxt.height - prev.height)
        let estimatedFlow = totalRange * Double(currentFlowTwelfths) / 12.0

        return TwelfthsData(
            currentHour: currentHour,
            twelfthsPerHour: twelfths,
            currentFlowTwelfths: currentFlowTwelfths,
            isRising: isRising,
            progressPercent: progress * 100,
            estimatedFlowMeters: estimatedFlow,
            totalRange: totalRange
        )
    }

    // MARK: - Time Formatting

    /// Formate un intervalle de temps en texte lisible
    static func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes) min"
        }
    }
}

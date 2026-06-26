//
//  ForecastBiasService.swift
//  Tide It
//
//  Jauge de confiance — mesure le BIAIS LOCAL du modèle de vent. À chaque nouveau relevé de
//  la balise la plus proche, on compare ce que le MODÈLE prévoyait pour cette heure au vent
//  RÉELLEMENT mesuré, et on accumule l'écart sur un buffer roulant BORNÉ par spot. On expose
//  un verdict honnête ("le modèle tape +4 kt ici ces derniers relevés") et une correction
//  optionnelle (retire le biais appris d'une valeur prévue). Réutilise la pipeline balise +
//  prévision existante ; n'invente aucune donnée. Différenciateur #1 vs concurrents.
//
//  ⚠️ Honnêteté : un verdict n'est "fiable" que si la balise est FRAÎCHE, ASSEZ PROCHE et qu'on
//  a ASSEZ d'échantillons — sinon on mentirait (une balise à 30 km a son propre micro-climat).
//

import Foundation
import Combine

@MainActor
final class ForecastBiasService: ObservableObject {
    static let shared = ForecastBiasService()

    struct Sample: Codable {
        let t: Date
        let model: Double      // vent prévu (km/h) à cette heure
        let observed: Double   // vent mesuré balise (km/h)
        let dist: Double       // distance de la balise (km)
    }

    struct BiasReadout {
        let meanBiasKmh: Double       // modèle − réel : > 0 = modèle OPTIMISTE (tape trop haut)
        let sampleCount: Int
        let scatterKmh: Double        // écart-type des écarts (régularité du biais)
        let lastSampleAge: TimeInterval
        let stationDistanceKm: Double

        /// Verdict affichable seulement si signal suffisant + balise crédible.
        var isReliable: Bool {
            sampleCount >= Self.minSamples
                && stationDistanceKm <= Self.maxStationKm
                && lastSampleAge < Self.maxAge
        }
        /// Biais assez net pour qu'une correction ait du sens (sinon le modèle est déjà bon → on ne
        /// propose pas de « corriger » et on ne déforme pas la courbe pour un écart négligeable).
        var isCorrectable: Bool { isReliable && abs(meanBiasKmh) >= Self.meaningfulBiasKmh }

        static let minSamples = 4
        static let maxStationKm = 25.0
        static let maxAge: TimeInterval = 3 * 3600   // 3 h
        static let meaningfulBiasKmh = 2.5           // seuil verdict amber/cyan ET correction (source unique)
    }

    private var buffers: [String: [Sample]] = [:]
    private let maxSamples = 24
    private let storeKey = "forecastBiasBuffers_v1"

    private init() { load() }

    // MARK: - Écriture

    /// Enregistre un échantillon (appelé à chaque nouveau relevé balise). Anti-doublon par minute.
    func record(portId: String, modelKmh: Double, observedKmh: Double, distanceKm: Double, at: Date) {
        guard !portId.isEmpty, modelKmh.isFinite, observedKmh.isFinite, observedKmh >= 0, modelKmh >= 0 else { return }
        var arr = buffers[portId] ?? []
        if let last = arr.last, abs(last.t.timeIntervalSince(at)) < 60 { return }   // 1 échantillon/min max
        arr.append(Sample(t: at, model: modelKmh, observed: observedKmh, dist: distanceKm))
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }       // borné
        buffers[portId] = arr
        objectWillChange.send()
        save()
    }

    /// Purge l'état d'un spot (à appeler dans TideService.purgePortState).
    func purge(portId: String) {
        guard buffers[portId] != nil else { return }
        buffers.removeValue(forKey: portId)
        objectWillChange.send()
        save()
    }

    // MARK: - Lecture

    /// Verdict de biais pour un spot, ou nil si pas assez d'échantillons.
    func readout(for portId: String) -> BiasReadout? {
        guard let arr = buffers[portId], arr.count >= 2 else { return nil }
        let diffs = arr.map { $0.model - $0.observed }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(diffs.count)
        return BiasReadout(
            meanBiasKmh: mean,
            sampleCount: arr.count,
            scatterKmh: variance.squareRoot(),
            lastSampleAge: Date().timeIntervalSince(arr.last!.t),
            stationDistanceKm: arr.last!.dist
        )
    }

    /// Nombre d'échantillons accumulés (pour l'état "calibration…").
    func sampleCount(for portId: String) -> Int { buffers[portId]?.count ?? 0 }

    /// Corrige une valeur prévue (km/h) avec le biais appris — SI fiable. Sinon valeur brute.
    func debiased(_ kmh: Double, portId: String) -> Double {
        guard let r = readout(for: portId), r.isReliable else { return kmh }
        return max(0, kmh - r.meanBiasKmh)
    }

    /// Corrige TOUTE une série de prévisions (vent moyen + rafale) par le biais local appris — SI
    /// corrigeable. Décale moyen ET rafale du MÊME offset → préserve le facteur de rafale (un biais
    /// SYSTÉMATIQUE du modèle se reporte aussi sur la rafale). Direction inchangée. Sinon série brute.
    /// Alimente la correction premium de la courbe + des fenêtres GO. ⚠️ Ne JAMAIS reboucler vers
    /// l'apprentissage (`record` lit toujours le modèle BRUT) : sinon le biais s'effondrerait à zéro.
    func debiasedSeries(_ series: [HourlyForecast], portId: String) -> [HourlyForecast] {
        guard let r = readout(for: portId), r.isCorrectable else { return series }
        let b = r.meanBiasKmh
        return series.map { f in
            f.withWind(speed: max(0, f.windSpeedKmh - b),
                       gust: f.windGustKmh.map { max(0, $0 - b) },
                       direction: f.windDirection)
        }
    }

    // MARK: - Persistance (locale, bornée)

    private func save() {
        if let d = try? JSONEncoder().encode(buffers) {
            UserDefaults.standard.set(d, forKey: storeKey)
        }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: storeKey),
              let b = try? JSONDecoder().decode([String: [Sample]].self, from: d) else { return }
        buffers = b
    }
}

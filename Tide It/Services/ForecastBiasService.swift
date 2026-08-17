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
        /// Vent PRÉVU (km/h) à cette heure, quand on l'avait sous la main.
        ///
        /// Optionnel depuis l'ajout de la trace : les échantillons pris lors d'un réveil de fond
        /// n'ont pas de prévision disponible, et aller la chercher coûterait une requête réseau
        /// — soit exactement ce que cette fonction s'interdit. Une MESURE existe indépendamment
        /// du fait qu'on ait eu une prévision à lui apparier ; la jauge de biais écarte
        /// simplement ces échantillons (`usableSamples`), la trace les garde.
        var model: Double?
        /// Vent prévu (km/h) par le SECOND modèle, à la même heure et apparié à la même mesure.
        ///
        /// L'app a deux fournisseurs de prévision : Open-Meteo (`model`, sous-échantillonné par
        /// voisinage) et Apple WeatherKit (`modelWK`, point unique), ce dernier servant de repli
        /// quand le premier est muet — silencieusement, jusqu'ici. Les stocker CÔTE À CÔTE contre
        /// la même mesure de balise est le seul moyen honnête de savoir lequel est le plus juste :
        /// même spot, même heure, même anémomètre, aucune excuse possible pour le perdant.
        var modelWK: Double? = nil
        let observed: Double   // vent mesuré balise (km/h)
        let dist: Double       // distance de la balise (km)
        /// Rafale MESURÉE (km/h). Optionnelle à deux titres : toutes les balises n'en publient
        /// pas, et le champ est arrivé après coup — le `Codable` synthétisé décode donc les
        /// anciens tampons intacts (clé absente = nil), comme `SpotConfig` l'a déjà fait.
        var gust: Double? = nil
        /// Identifiant de la balise qui a fourni CETTE mesure.
        ///
        /// Indispensable au tracé : la station arbitrée peut changer d'un échantillon à l'autre
        /// (celle qui se tait sort des 30 min, une autre prend le relais). Deux stations n'ont
        /// pas la même exposition, et relier leurs points d'un trait continu ferait passer un
        /// CHANGEMENT DE SOURCE pour une bascule de vent. Le tracé coupe donc le trait quand cet
        /// identifiant change — cf. `trace(for:)`.
        var station: String? = nil
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

        static let minSamples = 4
        /// ⚠️ RAMENÉ DE 25 km À 8 km — et c'est un correctif, pas un réglage.
        ///
        /// Sur une côte, le régime de vent change en quelques kilomètres : l'océan et un bassin
        /// abrité n'ont rien à voir. À 25 km, une balise du Bassin d'Arcachon « corrigeait » la
        /// prévision du Cap Ferret et de Lacanau, pourtant plein océan. Elle mesure forcément
        /// moins que le modèle ne prévoit au large → le biais était positif → la correction
        /// RETIRAIT du vent aux spots océan pendant qu'elle en AJOUTAIT à Andernos.
        ///
        /// Résultat constaté à 18 h : l'app affichait Andernos 15 nds contre Cap Ferret 12,
        /// quand le modèle brut disait Cap Ferret 17,2 et Andernos 11,4. L'ORDRE PHYSIQUE ÉTAIT
        /// INVERSÉ — le Bassin abrité paraissait plus venté que le front de mer.
        ///
        /// 8 km, c'est la distance en deçà de laquelle une balise partage encore l'exposition du
        /// spot. Au-delà, pas de correction : montrer la prévision brute vaut infiniment mieux
        /// que la déformer avec une mesure prise dans un autre régime.
        static let maxStationKm = 8.0
        static let maxAge: TimeInterval = 3 * 3600   // 3 h
        static let meaningfulBiasKmh = 2.5           // seuil verdict amber/cyan ET correction (source unique)
        /// Âge maximal d'un échantillon RETENU dans la moyenne. Le tampon est borné en NOMBRE
        /// (24) mais pas en durée : sans ce filtre, un spot rouvert après des mois moyennait le
        /// biais du printemps avec celui d'aujourd'hui — et, la balise arbitrée ayant pu changer
        /// entre-temps, deux balises différentes. Le biais d'un modèle est saisonnier et local :
        /// au-delà de quelques jours, un vieil échantillon décrit une autre situation.
        static let maxSampleAge: TimeInterval = 48 * 3600   // 48 h
        /// Au-delà, l'écart n'est plus un biais de modèle mais le signe que la balise ne décrit
        /// pas ce spot (abri, relief, capteur mal exposé). On garde alors la JAUGE — l'écart est
        /// une information — mais on ne touche PAS à la prévision : appliquer 10 km/h de décalage
        /// à tout un horizon de 7 jours sur la foi d'une poignée d'échantillons ferait plus de
        /// dégâts que le biais lui-même.
        static let maxCorrectableBiasKmh = 10.0
    }

    private var buffers: [String: [Sample]] = [:]
    /// 300 échantillons ≈ 48 h à la cadence de publication d'une balise (une mesure toutes les
    /// ~10 min). Était 24, ce qui suffisait à la JAUGE de biais mais couvrait à peine 4 h — donc
    /// pas de quoi dessiner la trace du réel sur la courbe.
    ///
    /// Relever ce plafond ne fausse pas la jauge : `usableSamples` filtrait déjà sur 48 h et 8 km,
    /// et le cap de 24 ne faisait que TRONQUER arbitrairement cette fenêtre aux 24 derniers
    /// relevés. La moyenne porte désormais sur toute la fenêtre que la jauge dit utiliser — elle
    /// devient plus fidèle à sa propre définition, et moins bruitée.
    private let maxSamples = 300
    /// Nombre de ports dont on garde un tampon. Chaque port visité en ouvrait un, purgé
    /// seulement à la suppression du favori : parcourir le catalogue en accumulait indéfiniment.
    /// Invisible tant qu'un tampon pesait 24 échantillons, plus du tout à 300 avec la rafale.
    /// On conserve les plus RÉCEMMENT alimentés — ceux qu'on regarde vraiment.
    private let maxPorts = 8
    private let storeKey = "forecastBiasBuffers_v1"

    private init() { load() }

    // MARK: - Écriture

    /// Enregistre un échantillon (appelé à chaque nouveau relevé balise). Anti-doublon par minute.
    func record(portId: String, modelKmh: Double?, observedKmh: Double, distanceKm: Double,
                at: Date, gustKmh: Double? = nil, stationID: String? = nil,
                modelWKKmh: Double? = nil) {
        guard !portId.isEmpty, observedKmh.isFinite, observedKmh >= 0 else { return }
        // Une prévision aberrante est écartée, mais SANS jeter la mesure : la trace du réel
        // reste valable, seule la jauge de biais perd cet échantillon.
        let m = modelKmh.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        var arr = buffers[portId] ?? []
        if let last = arr.last, abs(last.t.timeIntervalSince(at)) < 60 { return }   // 1 échantillon/min max
        // Une rafale INFÉRIEURE à la moyenne est impossible : la balise a publié un champ
        // aberrant. On garde la mesure et on jette la seule rafale, plutôt que de tracer une
        // courbe de rafale qui passerait sous celle du vent moyen.
        let g = gustKmh.flatMap { $0.isFinite && $0 >= observedKmh ? $0 : nil }
        let wk = modelWKKmh.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        arr.append(Sample(t: at, model: m, modelWK: wk, observed: observedKmh, dist: distanceKm,
                          gust: g, station: stationID))
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }       // borné
        buffers[portId] = arr
        trimPorts(keeping: portId)
        objectWillChange.send()
        save()
    }

    /// Ne garde que les `maxPorts` tampons les plus récemment alimentés. Le port qu'on vient
    /// d'écrire est toujours conservé — c'est celui qu'on regarde.
    private func trimPorts(keeping portId: String) {
        guard buffers.count > maxPorts else { return }
        let ordre = buffers
            .filter { $0.key != portId }
            .sorted { ($0.value.last?.t ?? .distantPast) > ($1.value.last?.t ?? .distantPast) }
        for (cle, _) in ordre.dropFirst(maxPorts - 1) { buffers.removeValue(forKey: cle) }
    }

    /// Purge l'état d'un spot (à appeler dans TideService.purgePortState).
    func purge(portId: String) {
        guard buffers[portId] != nil else { return }
        buffers.removeValue(forKey: portId)
        objectWillChange.send()
        save()
    }

    // MARK: - Lecture

    /// Échantillons RETENUS pour le verdict : assez récents ET issus d'une balise assez proche.
    /// SOURCE UNIQUE du filtre — `readout` et `sampleCount` doivent voir le même ensemble, sinon
    /// l'app annonce « calibration : 6 échantillons » puis rend un verdict fondé sur 2.
    private func usableSamples(for portId: String, now: Date = Date()) -> [Sample] {
        (buffers[portId] ?? []).filter {
            // `model != nil` : un échantillon pris en arrière-plan n'a pas de prévision appariée
            // (cf. `Sample.model`). Il nourrit la TRACE, jamais le calcul d'un écart — sans quoi
            // la jauge comparerait une mesure à rien.
            $0.model != nil
                && now.timeIntervalSince($0.t) <= BiasReadout.maxSampleAge
                && $0.dist <= BiasReadout.maxStationKm
        }
    }

    /// Verdict de biais pour un spot, ou nil si pas assez d'échantillons.
    func readout(for portId: String) -> BiasReadout? {
        let now = Date()
        let arr = usableSamples(for: portId, now: now)
        guard arr.count >= 2, let last = arr.last else { return nil }
        // `usableSamples` a déjà écarté les échantillons sans prévision : le déballage est sûr.
        let diffs = arr.compactMap { s in s.model.map { $0 - s.observed } }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(diffs.count)
        return BiasReadout(
            meanBiasKmh: mean,
            sampleCount: arr.count,
            scatterKmh: variance.squareRoot(),
            lastSampleAge: now.timeIntervalSince(last.t),
            // Distance la PLUS DÉFAVORABLE des échantillons retenus, et non celle du dernier :
            // la fiabilité d'une moyenne se juge sur le pire de ses termes, pas sur le meilleur.
            stationDistanceKm: arr.map(\.dist).max() ?? last.dist
        )
    }

    /// Nombre d'échantillons accumulés (pour l'état "calibration…") — même filtre que le verdict.
    func sampleCount(for portId: String) -> Int { usableSamples(for: portId).count }

    // MARK: - Duel des deux modèles de prévision

    /// Qui est le plus juste, Open-Meteo ou WeatherKit ? Jugés sur les MÊMES mesures.
    struct ModelDuel {
        let n: Int                 // échantillons où les DEUX modèles étaient présents
        let biasOM: Double         // Open-Meteo − réel (> 0 = tape trop haut)
        let rmseOM: Double
        let biasWK: Double         // WeatherKit − réel
        let rmseWK: Double
        let firstSample: Date
        let stationDistanceKm: Double

        /// Écart de RMSE. > 0 = WeatherKit fait PIRE ; < 0 = WeatherKit fait mieux.
        var rmseGapWKminusOM: Double { rmseWK - rmseOM }

        /// Verdict prudent : sous 20 échantillons appariés, ou sous 0,5 km/h d'écart, on ne
        /// tranche PAS. Le dépôt a déjà mesuré que départager deux modèles à moins de ça, c'est
        /// trancher sur du bruit — l'audit des six méthodes d'échantillonnage tenait dans
        /// 0,13 km/h et n'a rien départagé.
        var verdict: String {
            guard n >= 20 else { return "calibration" }
            if abs(rmseGapWKminusOM) < 0.5 { return "égalité" }
            return rmseGapWKminusOM > 0 ? "Open-Meteo" : "WeatherKit"
        }
    }

    /// Compare les deux modèles sur les échantillons où TOUS DEUX étaient renseignés.
    ///
    /// L'appariement est la clé : un modèle jugé sur d'autres heures que son concurrent aurait
    /// une excuse. Ici, même spot, même heure, même anémomètre — le perdant n'en a aucune.
    /// Filtre de distance conservé (8 km) : une balise plus loin ne décrit plus ce spot, et
    /// jugerait les deux modèles sur un vent qui n'est pas le leur.
    func modelDuel(for portId: String, now: Date = Date()) -> ModelDuel? {
        let arr = (buffers[portId] ?? []).filter {
            $0.model != nil && $0.modelWK != nil
                && now.timeIntervalSince($0.t) <= BiasReadout.maxSampleAge
                && $0.dist <= BiasReadout.maxStationKm
        }
        guard arr.count >= 2, let first = arr.map(\.t).min() else { return nil }
        func stats(_ pick: (Sample) -> Double?) -> (bias: Double, rmse: Double) {
            let d = arr.compactMap { s in pick(s).map { $0 - s.observed } }
            guard !d.isEmpty else { return (0, 0) }
            return (d.reduce(0, +) / Double(d.count),
                    (d.reduce(0) { $0 + $1 * $1 } / Double(d.count)).squareRoot())
        }
        let om = stats { $0.model }, wk = stats { $0.modelWK }
        return ModelDuel(n: arr.count, biasOM: om.bias, rmseOM: om.rmse,
                         biasWK: wk.bias, rmseWK: wk.rmse, firstSample: first,
                         stationDistanceKm: arr.map(\.dist).max() ?? 0)
    }

    // MARK: - Trace du réel (superposée à la courbe de vent)

    /// Un point de la trace : ce que la balise a RÉELLEMENT mesuré à cet instant.
    struct TracePoint {
        let t: Date
        let speedKmh: Double
        let gustKmh: Double?
    }

    /// Au-delà de ce silence entre deux mesures, le trait se COUPE.
    ///
    /// 40 min : une balise publie toutes les ~10 min, et l'app n'échantillonne qu'au premier
    /// plan ou lors d'un réveil de fond dont iOS décide seul. Les trous sont donc la règle, pas
    /// l'exception — téléphone éteint, app fermée, réveil refusé. Relier deux points distants de
    /// six heures dessinerait un vent qui n'a jamais été mesuré : c'est précisément ce que la
    /// règle d'honnêteté interdit. Le trou se voit, et c'est ce qu'on veut.
    static let traceMaxGap: TimeInterval = 40 * 60

    /// Trace du vent réellement mesuré sur les 48 dernières heures, découpée en SEGMENTS
    /// CONTINUS. Chaque segment se dessine d'un trait ; entre deux segments, on ne relie rien.
    ///
    /// Une coupure survient pour deux raisons, et les deux comptent :
    /// 1. un SILENCE de plus de `traceMaxGap` (cf. ci-dessus) ;
    /// 2. un CHANGEMENT DE BALISE — la station arbitrée peut changer quand la plus proche se
    ///    tait. Deux stations n'ont pas la même exposition ; relier leurs points ferait passer
    ///    un changement de source pour une bascule de vent, ce qui est un mensonge plus subtil
    ///    et plus grave qu'un trou.
    ///
    /// Pas de filtre de distance ici, contrairement à `usableSamples` : la trace doit montrer
    /// EXACTEMENT ce que l'app a affiché comme « réel » (rayon 15 km), pas le sous-ensemble
    /// plus strict que la jauge de biais s'impose (8 km). Sinon la courbe et la pastille se
    /// contrediraient sous les yeux de l'utilisateur.
    func trace(for portId: String, now: Date = Date()) -> [[TracePoint]] {
        let arr = (buffers[portId] ?? [])
            .filter { now.timeIntervalSince($0.t) <= BiasReadout.maxSampleAge }
            .sorted { $0.t < $1.t }
        guard !arr.isEmpty else { return [] }

        var segments: [[TracePoint]] = []
        var courant: [TracePoint] = []
        var precedent: Sample?
        for s in arr {
            if let p = precedent,
               s.t.timeIntervalSince(p.t) > Self.traceMaxGap || s.station != p.station {
                if courant.count >= 2 { segments.append(courant) }
                courant = []
            }
            courant.append(TracePoint(t: s.t, speedKmh: s.observed, gustKmh: s.gust))
            precedent = s
        }
        if courant.count >= 2 { segments.append(courant) }
        // Un segment d'UN point ne se dessine pas comme une ligne : il est écarté ci-dessus.
        // La pastille « réel » de l'en-tête montre déjà la mesure isolée du moment.
        return segments
    }

    // ⚠️ AUCUNE FONCTION DE CORRECTION ICI, ET C'EST VOULU.
    //
    // Ce service MESURE l'écart entre le modèle et la balise, et s'arrête là. Il ne retouche
    // aucune prévision. Deux corrections existaient (`debiased`, `debiasedSeries`) : elles
    // retiraient de l'horizon un décalage appris sur une balise, et elles ont produit
    // exactement ce qu'on pouvait craindre — une balise abritée tirait vers le bas la prévision
    // d'un spot océan, et une balise tombée en panne la veille continuait de déformer sept
    // jours de prévision avec ses derniers échantillons.
    //
    // La prévision est ce que disent les modèles. La balise est ce qu'il fait maintenant.
    // Les deux se COMPARENT — c'est le rôle de `readout` — elles ne se mélangent jamais.

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

//
//  PremiumCurveCanvas.swift
//  Tide It
//
//  Extrait de TodayView.swift (decoupe du god-file) : la courbe scrollable maree + vent.
//  Math de courbe + rendu Canvas, isoles pour la testabilite et le futur mode surf.
//

import SwiftUI
import WeatherKit
import ActivityKit
import CoreLocation

/// Compteur partagé du nombre de fenêtres GO À VENIR pour le PORT ACTIF → affiché en badge
/// « Activités : N » dans le menu central. Alimenté par `PremiumCurveCanvas.updateGoBadge`, qui
/// dérive du prop `goWindows` (source UNIQUE : mêmes fenêtres que les rectangles de la courbe et que
/// le calendrier) — zéro second calcul.
@MainActor
final class GoWindowBadge: ObservableObject {
    static let shared = GoWindowBadge()
    @Published var count: Int = 0
    private init() {}
}

struct PremiumCurveCanvas: View {
    let tideData: [TideData]
    let startDate: Date
    let totalDuration: TimeInterval
    let totalWidth: CGFloat
    let currentTime: Date
    let viewHeight: CGFloat
    let screenWidth: CGFloat
    var sunTimes: [(sunrise: Date, sunset: Date)] = []
    var hourlyForecast: [HourWeather] = []
    @EnvironmentObject private var themeManager: ThemeManager
    var weatherService: WeatherService?
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    /// Mode de rendu de la courbe : classique (marée) / vent / surf.
    var curveMode: CurveMode = .classic
    var openMeteoForecasts: [HourlyForecast] = []
    var observedWindKmh: Double? = nil
    var observedGustKmh: Double? = nil
    /// Creux (lull) réel de l'instant — brin bas de la moustache rafale. nil si la source ne le fournit pas.
    var observedMinKmh: Double? = nil
    var observedWindDirection: Double? = nil
    var observedWindAgeMinutes: Int? = nil
    /// Une balise de vent réel est disponible pour ce spot → active le label « Go X% » vivant.
    var hasBalise: Bool = false
    var riderMinKmh: Double = 12
    var riderMaxKmh: Double = 65
    /// Hauteur d'eau minimale du spot (m) — fenêtres GO exclues quand la marée est plus basse.
    var minWaterHeight: Double? = nil
    /// Orientation plage/mer (cap, deg) — fenêtres GO exclues quand le vent est de terre (offshore).
    var windShoreOrientation: Double? = nil
    /// Sports suivis (conditions) → zones GO colorées + nommées par sport, synchro avec le calendrier.
    var sportSetups: [SportSetup] = []
    /// TOUTES les fenêtres GO (tous sports), calculées par TodayView via le MÊME `ActivityGoPlanner.plan`
    /// que le calendrier → rendu IDENTIQUE en mode vent ET surf, parfaitement corrélé au calendrier.
    var goWindows: [GoCurveWindow] = []

    @Environment(\.colorScheme) private var colorScheme

    private var isLight: Bool { colorScheme == .light }
    /// Encre neutre adaptée au thème : NOIR en clair, BLANC en sombre. Le mode vent utilisait
    /// du blanc partout → invisible en thème clair.
    private var windInk: Color { isLight ? .black : .white }

    /// Shim rétro-compat : tout le code « mode vent » existant continue de marcher tel quel.
    private var windMode: Bool { curveMode == .wind }
    /// La marée est APLATIE/neutralisée (vent OU surf) → libère le haut pour le calque dédié.
    private var curveFlattened: Bool { curveMode != .classic && !openMeteoForecasts.isEmpty }

    /// Formate une heure dans le fuseau du port. Formatter MÉMOÏSÉ : `formatTime` est
    /// appelé pour chaque label d'heure de la courbe à chaque redraw (scroll) — créer un
    /// `DateFormatter` à chaque appel était coûteux.
    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }

    @State private var scrubState: CurveScrubState? = nil
    /// Dérivés vent MÉMOÏSÉS (reconstruits seulement quand les données changent, jamais par frame) :
    /// le dégradé et les prévisions triées UNE fois. Avant, `drawWindLayer`
    /// retriait ~360 prévisions et recalculait les fenêtres GO (1×/sport) À CHAQUE frame + sur le
    /// timer 60 s → gaspillage batterie/fluidité sur l'écran héro.
    @State private var cachedWindGradient: Gradient = Gradient(colors: [Color.tideHigh, Color.tideLow])
    @State private var sortedForecasts: [HourlyForecast] = []
    /// TideMetrics MÉMOÏSÉ (pur de la taille/du scroll) : reconstruit 1× par changement de donnée
    /// dans rebuildWindDerived (windDerivedInputs inclut tideData) au lieu de ~6 reconstructions
    /// O(n)+alloc PAR FRAME pendant le scrub. Les 6 sites lisent `cachedTideMetrics ?? recompute`.
    @State private var cachedTideMetrics: TideMetrics?

    /// Prévisions triées (cache) avec repli direct au tout 1ᵉʳ rendu, avant que `rebuildWindDerived` n'ait tourné.
    private var windSorted: [HourlyForecast] {
        !sortedForecasts.isEmpty ? sortedForecasts : openMeteoForecasts.sorted { $0.time < $1.time }
    }

    /// Toutes les entrées qui affectent les dérivés vent, regroupées en UNE valeur Equatable →
    /// permet un SEUL `.onChange` (au lieu de 8, qui rendait la chaîne de modificateurs du `body`
    /// trop lourde pour le type-checker), tout en restant robuste (compare le CONTENU des tableaux).
    private struct WindDerivedInputs: Equatable {
        let forecasts: [HourlyForecast]
        let startDate: Date
        let sportSetups: [SportSetup]
        let tideData: [TideData]
        let riderMin: Double
        let riderMax: Double
        let minWaterHeight: Double?
        let shoreOrientation: Double?
    }
    private var windDerivedInputs: WindDerivedInputs {
        WindDerivedInputs(forecasts: openMeteoForecasts, startDate: startDate, sportSetups: sportSetups,
                          tideData: tideData, riderMin: riderMinKmh, riderMax: riderMaxKmh,
                          minWaterHeight: minWaterHeight, shoreOrientation: windShoreOrientation)
    }

    private func rebuildWindDerived() {
        sortedForecasts = openMeteoForecasts.sorted { $0.time < $1.time }
        cachedWindGradient = Self.makeWindGradient(forecasts: openMeteoForecasts,
                                                   startDate: startDate, totalDuration: totalDuration)
        cachedTideMetrics = TideMetrics(tideData: tideData)   // mémoïsé (les 6 sites le lisent)
    }

    /// Badge « Activités : N » = nombre de fenêtres GO À VENIR. SOURCE UNIQUE : le prop `goWindows`
    /// — le MÊME que les rectangles de la courbe ET le calendrier (ActivityGoPlanner.plan, scoré).
    /// Avant, le badge se calculait à part via windows(for:) NON scoré → il pouvait contredire les
    /// rectangles (sports AUTO + fenêtres à cheval sur minuit). Désormais badge == rectangles == calendrier.
    private func updateGoBadge() {
        let n = goWindows.filter { $0.end >= Date() }.count
        if GoWindowBadge.shared.count != n { GoWindowBadge.shared.count = n }
    }

    /// Trouve la prévision vent la plus proche d'une date donnée
    private func closestForecast(for date: Date) -> HourlyForecast? {
        guard !openMeteoForecasts.isEmpty else { return nil }
        return openMeteoForecasts.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }


    /// Couleur du bandeau météo (icônes + halo) : en mode vent, suit la couleur du vent
    /// de la courbe au même instant → l'ensemble forme une unité. Sinon, couleur de température.
    private func weatherStripColor(at date: Date, celsius: Double) -> Color {
        if windMode, let fc = closestForecast(for: date) {
            return Self.windColorSmooth(fc.windSpeedKmh)
        }
        return Self.temperatureColor(celsius)
    }

    // Pré-calcul compact : extension virtuelle + bounds en une seule passe
    struct TideMetrics {
        let sorted: [TideData]
        let adjustedMin: Double
        let span: Double

        init?(tideData: [TideData]) {
            guard tideData.count >= 2 else { return nil }

            // Calculer les hauteurs moyennes par type pour les points virtuels
            var highSum = 0.0, highCount = 0, lowSum = 0.0, lowCount = 0
            for t in tideData {
                if t.isHighTide { highSum += t.height; highCount += 1 }
                else { lowSum += t.height; lowCount += 1 }
            }
            let avgHigh = highCount > 0 ? highSum / Double(highCount) : tideData[0].height + 3
            let avgLow = lowCount > 0 ? lowSum / Double(lowCount) : tideData[0].height - 3

            var extended = tideData

            // Point virtuel AVANT la première marée (continue le cycle naturel)
            let first = tideData[0], second = tideData[1]
            let halfPeriod = second.date.timeIntervalSince(first.date)
            let prevHeight = first.isHighTide ? avgLow : avgHigh
            extended.insert(
                TideData(date: first.date.addingTimeInterval(-halfPeriod),
                         height: prevHeight, isHighTide: !first.isHighTide, coefficient: nil),
                at: 0
            )

            // Point virtuel APRÈS la dernière marée
            let last = tideData[tideData.count - 1]
            let secondLast = tideData[tideData.count - 2]
            let lastHalfPeriod = last.date.timeIntervalSince(secondLast.date)
            let nextHeight = last.isHighTide ? avgLow : avgHigh
            extended.append(
                TideData(date: last.date.addingTimeInterval(lastHalfPeriod),
                         height: nextHeight, isHighTide: !last.isHighTide, coefficient: nil)
            )

            // Bounds sur les données étendues
            var minH = Double.infinity, maxH = -Double.infinity
            for tide in extended {
                if tide.height < minH { minH = tide.height }
                if tide.height > maxH { maxH = tide.height }
            }
            let padding = (maxH - minH) * 0.12
            let span = (maxH + padding) - (minH - padding)
            guard span > 0 else { return nil }
            self.sorted = extended
            self.adjustedMin = minH - padding
            self.span = span
        }
    }

    // Constantes de layout
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

    // MARK: Géométrie du mode vent (partagée parent ↔ enfant ↔ barre de temps)

    /// Mode vent : la marée est compressée verticalement à ce facteur (fine vague ambiante
    /// dans une bande basse) → tout le haut est libéré pour les courbes de vent.
    static let tideFlattenScale: CGFloat = 0.28
    /// Y aplati d'un point de marée (même transform que la courbe en mode vent).
    static func flattenedTideY(_ y: CGFloat, topMargin: CGFloat, drawHeight: CGFloat) -> CGFloat {
        let bottomY = topMargin + drawHeight
        return tideFlattenScale * y + bottomY * (1 - tideFlattenScale)
    }
    /// Région verticale dédiée aux courbes de vent (ratios de hauteur). Démarre SOUS la pastille
    /// de lecture (elle-même sous l'en-tête) et reste compacte → courbes aplaties, lisibles.
    static func windRegion(_ h: CGFloat) -> (top: CGFloat, height: CGFloat) {
        (h * 0.20, h * 0.32)
    }
    /// Échelle haute de l'axe vent (km/h). S'ADAPTE sans plafond aux vents extrêmes (tempête) :
    /// pas de 5 en conditions normales, pas de 10 au-delà de 60 km/h pour des graduations nettes
    /// à fort vent. SOURCE UNIQUE : parent (échelle fixe) et enfant (courbes) → jamais de dérive.
    static func windScaleMaxKmh(_ forecasts: [HourlyForecast]) -> Double {
        let m = forecasts.map { max($0.windSpeedKmh, $0.windGustKmh ?? 0) }.max() ?? 30
        let headroom = m * 1.12
        let step: Double = headroom > 60 ? 10 : 5
        return max(25, (headroom / step).rounded(.up) * step)
    }

    // Gradients adaptatifs dark/light
    private var fillGradient: Gradient {
        if isLight {
            // Light mode : fill très subtil, quasi transparent
            return Gradient(stops: [
                .init(color: Color.tideHigh.opacity(0.08), location: 0.0),
                .init(color: Color.tideMid.opacity(0.06), location: 0.2),
                .init(color: Color.tideLow.opacity(0.04), location: 0.45),
                .init(color: .clear, location: 0.7)
            ])
        }
        return Gradient(stops: [
            .init(color: Color.tideHigh.opacity(0.22), location: 0.0),
            .init(color: Color.tideHigh.opacity(0.32), location: 0.06),
            .init(color: Color.tideMid.opacity(0.25), location: 0.2),
            .init(color: Color.tideLow.opacity(0.18), location: 0.38),
            .init(color: Color.tideLow.opacity(0.10), location: 0.55),
            .init(color: Color.tideLow.opacity(0.05), location: 0.72),
            .init(color: Color.tideLow.opacity(0.015), location: 0.88),
            .init(color: .clear, location: 1.0)
        ])
    }

    private var strokeGradient: Gradient {
        Gradient(colors: [
            Color.tideHigh,
            Color.curveMidBlue,
            Color.curveMidPurple,
            Color.tideLow
        ])
    }

    // (trail épais défini dans thickTrailOverlay)

    private var glowGradient: Gradient {
        Gradient(colors: [
            Color.tideHigh,
            Color.curveGlowBlue,
            Color.tideLow,
            Color.curveGlowPink
        ])
    }

    // Layers de glow optimisés (réduit à 2 layers pour éviter le ghosting)
    // En light mode : pas de glow (inutile sur fond clair)
    private var glowLayers: [(blur: CGFloat, opacity: Double, width: CGFloat)] {
        if isLight { return [] }
        return [
            (15, 0.3, 12),
            (6, 0.5, 6),
        ]
    }

    var body: some View {
        Canvas { context, size in
            guard let metrics = (cachedTideMetrics ?? TideMetrics(tideData: tideData)) else { return }

            let topMargin = size.height * topMarginRatio
            let bottomMargin = size.height * bottomMarginRatio
            let drawHeight = size.height - topMargin - bottomMargin

            let windOn = curveMode == .wind && !openMeteoForecasts.isEmpty
            let surfOn = curveMode == .surf && !openMeteoForecasts.isEmpty
            let flattened = windOn || surfOn   // vent ET surf aplatissent la marée

            // Courbe de marée. EN MODE VENT/SURF : APLATIE dans une bande basse (≈ 38 % de hauteur)
            // → vague ambiante neutre qui ne concurrence plus le calque du haut.
            var path = createWavePath(
                sortedTides: metrics.sorted,
                size: size,
                topMargin: topMargin,
                drawHeight: drawHeight,
                adjustedMin: metrics.adjustedMin,
                heightSpan: metrics.span
            )
            let bottomY = topMargin + drawHeight
            if flattened {
                let d = Self.tideFlattenScale
                path = path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: d, tx: 0, ty: bottomY * (1 - d)))
            }

            // Arc solaire. En mode marée : grand arc dans toute la zone. En mode vent : petit arc
            // AU NIVEAU de la marée aplatie (apex au sommet de la bande, base en bas) → il ne
            // surcharge plus le vent et reste lisible avec la courbe de marée.
            for sunTime in sunTimes {
                if flattened {
                    drawSolarArc(context: &context, size: size, topMargin: topMargin, drawHeight: drawHeight,
                                 sunrise: sunTime.sunrise, sunset: sunTime.sunset,
                                 apexY: Self.flattenedTideY(topMargin, topMargin: topMargin, drawHeight: drawHeight),
                                 baseY: bottomY)
                } else {
                    drawSolarArc(context: &context, size: size, topMargin: topMargin, drawHeight: drawHeight,
                                 sunrise: sunTime.sunrise, sunset: sunTime.sunset)
                }
            }

            // Fill sous la courbe
            var fillPath = path
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            if flattened {
                // Fill marée NEUTRE très discret (pas de couleur).
                context.fill(fillPath, with: .color(windInk.opacity(isLight ? 0.04 : 0.06)))
            } else {
                context.fill(
                    fillPath,
                    with: .linearGradient(
                        fillGradient,
                        startPoint: CGPoint(x: size.width / 2, y: topMargin),
                        endPoint: CGPoint(x: size.width / 2, y: size.height)
                    )
                )
            }

            if flattened {
                // Marée : trait NEUTRE (gris/blanc faible), sans couleur ni glow.
                context.stroke(path, with: .color(windInk.opacity(isLight ? 0.30 : 0.18)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                if surfOn { drawSurfLayer(context: &context, size: size) }
                else { drawWindLayer(context: &context, size: size) }
            } else {
                // Default mode: glow + gradient stroke
                for layer in glowLayers {
                    var glowCtx = context
                    glowCtx.addFilter(.blur(radius: layer.blur))
                    glowCtx.opacity = layer.opacity

                    glowCtx.stroke(
                        path,
                        with: .linearGradient(
                            glowGradient,
                            startPoint: CGPoint(x: 0, y: size.height / 2),
                            endPoint: CGPoint(x: size.width, y: size.height / 2)
                        ),
                        style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round)
                    )
                }

                context.stroke(
                    path,
                    with: .linearGradient(
                        strokeGradient,
                        startPoint: CGPoint(x: 0, y: size.height / 2),
                        endPoint: CGPoint(x: size.width, y: size.height / 2)
                    ),
                    style: StrokeStyle(lineWidth: isLight ? 3.0 : 2.5, lineCap: .round, lineJoin: .round)
                )
            }

        }
        .drawingGroup() // Rendu en une seule texture pour éviter le ghosting
        .mask(
            // Fondu bas progressif et haut (~38 % de la hauteur) : la zone pleine
            // se dissout doucement dans le fond, plus d'arrêt net.
            VStack(spacing: 0) {
                Color.white
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white.opacity(0.85), location: 0.25),
                        .init(color: .white.opacity(0.45), location: 0.55),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: viewHeight * 0.40)
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Courbe des marées")
        .accessibilityHint("Affiche la hauteur d'eau sur plusieurs jours")
        // Pictos météo (effet dock) sous la courbe — SAUF en mode surf (remplacé par le bandeau
        // direction de houle, posé au même endroit).
        .overlay {
            if curveMode != .surf { weatherStripOverlay }
        }
        .overlay {
            // En mode vent/surf la marée est aplatie/neutre → on masque son trait vif et son point.
            if !curveFlattened { thickTrailOverlay }
        }
        .overlay {
            if !curveFlattened { curveTrackingDotOverlay }
        }
        .overlay {
            GeometryReader { geo in
                ZStack {
                    tidePointsOverlay(in: geo.size)

                    UnifiedTimeBar(
                        tideData: tideData,
                        startDate: startDate,
                        totalDuration: totalDuration,
                        totalWidth: geo.size.width,
                        viewHeight: geo.size.height,
                        currentTime: currentTime,
                        scrubState: scrubState,
                        portTimeZone: portTimeZone,
                        windMode: curveFlattened
                    )
                }
                .overlay {
                    let scrubMetrics = (cachedTideMetrics ?? TideMetrics(tideData: tideData))
                    CurveScrubGesture(
                        onBegan: { x in
                            let clamped = max(0, min(x, geo.size.width))
                            let progress = clamped / geo.size.width
                            let date = startDate.addingTimeInterval(progress * totalDuration)
                            if let m = scrubMetrics {
                                let h = Self.interpolateOnCurve(at: date, metrics: m)
                                HapticManager.shared.impact(.medium)
                                withAnimation(.interactiveSpring(response: 0.12)) {
                                    scrubState = CurveScrubState(offsetX: clamped, date: date, height: h)
                                }
                            }
                        },
                        onChanged: { x in
                            let clamped = max(0, min(x, geo.size.width))
                            let progress = clamped / geo.size.width
                            let date = startDate.addingTimeInterval(progress * totalDuration)
                            if let m = scrubMetrics {
                                let h = Self.interpolateOnCurve(at: date, metrics: m)
                                withAnimation(.interactiveSpring(response: 0.12)) {
                                    scrubState = CurveScrubState(offsetX: clamped, date: date, height: h)
                                }
                                HapticManager.shared.selection()
                            }
                        },
                        onEnded: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                scrubState = nil
                            }
                        }
                    )
                }
            }
        }
        // Mode surf : bandeau DIRECTION (dock) au-dessus de la courbe.
        .overlay {
            if curveMode == .surf, !openMeteoForecasts.isEmpty {
                surfDirectionStripOverlay
            }
        }
        // Mode vent : points prévu + rafale qui suivent le centre du scroll + pastille de lecture.
        // Mode surf : 2 points de suivi (hauteur + période) + échelles.
        .overlay {
            if windMode, !openMeteoForecasts.isEmpty {
                windTrackingOverlay
            } else if curveMode == .surf, !openMeteoForecasts.isEmpty {
                surfTrackingOverlay
            }
        }
        .onAppear { rebuildWindDerived(); updateGoBadge() }
        // Reconstruit les dérivés vent (dégradé + tri + fenêtres GO) UNIQUEMENT quand une donnée
        // change. `HourlyForecast` est désormais Equatable → on compare le CONTENU complet : deux
        // ports à même grille horaire (même count/heures) mais valeurs différentes déclenchent bien
        // le recalcul (l'ancien `.first?.time` restait figé sur le port précédent — même bug que le
        // bandeau météo 7 j). La comparaison O(n) reste bien moins chère que les tris/GO par frame.
        // UN SEUL onChange (regroupe forecasts/startDate/sports/marée/plages/hauteur/orientation) →
        // chaîne de modificateurs courte pour le type-checker, robustesse préservée (Equatable contenu).
        .onChange(of: windDerivedInputs) { _, _ in rebuildWindDerived() }
        // Badge GO = prop `goWindows` (source unique, scorée, == calendrier) — voir updateGoBadge.
        .onChange(of: goWindows) { _, _ in updateGoBadge() }
    }

    /// Interpole la hauteur en utilisant les mêmes données étendues que la courbe (TideMetrics)
    /// pour que le dot reste toujours collé au path, y compris aux extrêmes.
    static func interpolateOnCurve(at date: Date, metrics: TideMetrics) -> Double {
        let sorted = metrics.sorted
        // Recherche binaire du segment
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].date <= date { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && lo < sorted.count {
            let prev = sorted[lo - 1], next = sorted[lo]
            let duration = next.date.timeIntervalSince(prev.date)
            guard duration > 0 else { return prev.height }
            let t = date.timeIntervalSince(prev.date) / duration
            let cosT = (1 - cos(t * .pi)) / 2
            return prev.height + (next.height - prev.height) * cosT
        }
        return lo > 0 ? sorted[lo - 1].height : (sorted.first?.height ?? 0)
    }

    // MARK: - Thick Trail (stroke épais à gauche du dot, même gradient, simple clip)
    @ViewBuilder
    private var thickTrailOverlay: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("scroll"))
            let dotX = -frame.origin.x + screenWidth / 2

            Canvas { context, size in
                guard let metrics = (cachedTideMetrics ?? TideMetrics(tideData: tideData)) else { return }

                let topMargin = size.height * topMarginRatio
                let drawHeight = size.height - topMargin - size.height * bottomMarginRatio

                // Clip uniquement à gauche du dot
                let clipRect = CGRect(x: 0, y: 0, width: max(0, dotX), height: size.height)
                var ctx = context
                ctx.clip(to: Path(clipRect))

                let path = createWavePath(
                    sortedTides: metrics.sorted,
                    size: size,
                    topMargin: topMargin,
                    drawHeight: drawHeight,
                    adjustedMin: metrics.adjustedMin,
                    heightSpan: metrics.span
                )

                let gradient = windMode && !openMeteoForecasts.isEmpty
                    ? windGradient(size: size)
                    : strokeGradient

                let shading = GraphicsContext.Shading.linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2)
                )

                ctx.stroke(
                    path,
                    with: shading,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
            }
            // PAS de .drawingGroup() ici : ce Canvas n'est QU'UN seul trait clippé (pas de
            // couches glow à fusionner comme la courbe principale). Le Canvas rastérise déjà
            // et le .mask s'applique directement → on évite une passe Metal offscreen PAR FRAME
            // (ce clip suit le scroll → redessiné en continu). Rendu identique, scroll plus léger.
            .mask(
                VStack(spacing: 0) {
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                }
            )
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Tracking Dot (suit le centre du scroll, même technique que weather icons)
    @ViewBuilder
    private var curveTrackingDotOverlay: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("scroll"))
            let visibleCenterX = -frame.origin.x + screenWidth / 2

            // Date et hauteur au centre du viewport
            let centerProgress = Double(visibleCenterX / geo.size.width)
            let centerDate = startDate.addingTimeInterval(centerProgress * totalDuration)

            if let tideMetrics = (cachedTideMetrics ?? TideMetrics(tideData: tideData)) {
                // Interpoler sur la courbe étendue (inclut les points virtuels)
                let height = Self.interpolateOnCurve(at: centerDate, metrics: tideMetrics)
                let topMargin = geo.size.height * topMarginRatio
                let drawHeight = geo.size.height - topMargin - geo.size.height * bottomMarginRatio

                let normalizedH = tideMetrics.span > 0 ? (height - tideMetrics.adjustedMin) / tideMetrics.span : 0.5
                let dotY = topMargin + drawHeight * CGFloat(1 - normalizedH)

                // Dot sur la courbe (même style rond classique)
                TrackingDotView()
                    .position(x: visibleCenterX, y: dotY)

                // Soleil animé sur l'arc, à l'heure courante (jour uniquement) →
                // matérialise la « course du soleil ».
                if let sun = sunTimes.first(where: { currentTime >= $0.sunrise && currentTime <= $0.sunset }) {
                    let srX = xPosition(for: sun.sunrise)
                    let ssX = xPosition(for: sun.sunset)
                    if ssX > srX {
                        let cx = xPosition(for: currentTime)
                        let tt = max(0, min(1, (cx - srX) / (ssX - srX)))
                        let apexY = topMargin + drawHeight * 0.08
                        let baseY = topMargin + drawHeight * 0.75
                        let sy = baseY - (baseY - apexY) * 4 * tt * (1 - tt)
                        SunArcGlyph()
                            .position(x: cx, y: sy)
                            .allowsHitTesting(false)
                    }
                }

                // Tendance locale (pente de la courbe)
                let heightAfter = Self.interpolateOnCurve(
                    at: centerDate.addingTimeInterval(60),
                    metrics: tideMetrics
                )
                let isRising = heightAfter > height
                let trendColor: Color = isRising ? .tideHigh : .tideLow

                // Label glass box — flèche tendance + hauteur (+ vent si mode vent)
                HStack(spacing: 5) {
                    Image(systemName: isRising ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(trendColor)

                    Text(UnitFormatter.height(height, system: themeManager.measureSystem, decimals: 2))
                        .font(.scaled(size: DS.fontCaption, weight: .bold, design: .rounded))
                        .foregroundStyle(trendColor)
                        .monospacedDigit()

                    if windMode, let forecast = closestForecast(for: centerDate) {
                        let wColor = Self.windColorSmooth(forecast.windSpeedKmh)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(forecast.windDirection + 180))
                            .foregroundStyle(wColor)
                        Text("\(UnitFormatter.windSpeedInt(forecast.windSpeedKmh, unit: themeManager.windUnit)) \(themeManager.windUnit.label)")
                            .font(.scaled(size: DS.fontCaption, weight: .bold, design: .rounded))
                            .foregroundStyle(wColor)
                            .monospacedDigit()
                    }
                }
                // Conteneur UNIFIÉ pour les 3 modes (marée / vent / surf) : même pilule glass.
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
                .animation(nil, value: height)
                // Même emplacement que la pastille du mode vent (windTrackingOverlay) → le
                // libellé hors-courbe ne saute pas en basculant classique ↔ vent.
                .position(
                    x: min(max(visibleCenterX, 70), geo.size.width - 70),
                    y: geo.size.height * 0.15
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Weather Strip Overlay (atmospheric glow + Dock effect every 3h)
    private static let weatherHours = [0, 3, 6, 9, 12, 15, 18, 21]

    /// Dock magnification parameters
    private static let dockRadius: CGFloat = 120    // zone d'influence (pts)
    private static let dockMinScale: CGFloat = 0.85
    private static let dockMaxScale: CGFloat = 2.2   // zoom max au centre (plus prononcé)
    private static let tempShowRadius: CGFloat = 70   // rayon pour afficher la température

    /// Maps temperature (°C) to a color: blue → cyan → orange → red
    private static func temperatureColor(_ celsius: Double) -> Color {
        let t = min(max((celsius - 0) / 35, 0), 1)
        if t < 0.3 { return .blue }
        else if t < 0.45 { return .cyan }
        else if t < 0.6 { return .tideHigh }
        else if t < 0.8 { return .orange }
        else { return .red }
    }

    /// Dock-style scale: cosine falloff from center
    private static func dockScale(distance: CGFloat) -> CGFloat {
        guard distance < dockRadius else { return dockMinScale }
        let t = distance / dockRadius
        return dockMinScale + (dockMaxScale - dockMinScale) * (1 + cos(t * .pi)) / 2
    }

    @ViewBuilder
    private var weatherStripOverlay: some View {
        if !hourlyForecast.isEmpty, let ws = weatherService {
            ZStack {
                // Halo STATIQUE (rastérisé une seule fois, blur compris) : il fait partie du
                // contenu défilant → le GPU le translate au scroll, AUCUN recalcul de flou
                // par frame. C'était le principal coût du bandeau.
                weatherGlowLayer
                // Icônes dock : ne dépend du scroll que pour l'échelle/position (léger).
                weatherIconsLayer(ws)
            }
            .allowsHitTesting(false)
        }
    }

    /// Halo coloré statique sous la courbe (température, ou vent en mode vent).
    private var weatherGlowLayer: some View {
        Canvas { context, size in
            guard hourlyForecast.count >= 2 else { return }
            let glowY = size.height * 0.80
            let glowRect = CGRect(x: 0, y: glowY - 1, width: size.width, height: 2)

            var stops: [Gradient.Stop] = []
            for hour in hourlyForecast {
                let progress = CGFloat(hour.date.timeIntervalSince(startDate) / totalDuration)
                guard progress >= 0 && progress <= 1 else { continue }
                let celsius = hour.temperature.converted(to: .celsius).value
                stops.append(.init(color: weatherStripColor(at: hour.date, celsius: celsius).opacity(0.6),
                                   location: progress))
            }
            guard !stops.isEmpty else { return }
            stops.sort { $0.location < $1.location }

            var glowCtx = context
            glowCtx.addFilter(.blur(radius: 18))
            glowCtx.opacity = 0.3
            glowCtx.fill(
                Path(roundedRect: glowRect, cornerRadius: 1),
                with: .linearGradient(Gradient(stops: stops),
                                      startPoint: CGPoint(x: 0, y: glowY),
                                      endPoint: CGPoint(x: size.width, y: glowY))
            )
        }
        .allowsHitTesting(false)
    }

    /// Icônes météo (toutes les 3 h) avec effet dock (zoom près du centre).
    private func weatherIconsLayer(_ ws: WeatherService) -> some View {
        let calendar = Calendar.inTimeZone(portTimeZone)
        let keyHours = hourlyForecast.filter { Self.weatherHours.contains(calendar.component(.hour, from: $0.date)) }

        return GeometryReader { geo in
            let frame = geo.frame(in: .named("scroll"))
            let visibleCenterX = -frame.origin.x + screenWidth / 2
            let iconY = geo.size.height * 0.80

            ForEach(Array(keyHours.enumerated()), id: \.offset) { _, hour in
                let x = CGFloat(hour.date.timeIntervalSince(startDate) / totalDuration) * geo.size.width
                let celsius = hour.temperature.converted(to: .celsius).value
                let color = weatherStripColor(at: hour.date, celsius: celsius)

                let distance = abs(x - visibleCenterX)
                let scale = Self.dockScale(distance: distance)
                let tempOpacity = distance < Self.tempShowRadius ? Double(1 - distance / Self.tempShowRadius) : 0
                let glowIntensity = max(0, 1 - distance / 50)
                let iconOpacity = 0.35 + 0.65 * glowIntensity

                VStack(spacing: 3) {
                    Image(systemName: ws.getWeatherSymbol(for: hour.condition))
                        .font(.system(size: 16))
                        .foregroundStyle(color.opacity(iconOpacity))
                    Text(UnitFormatter.temp(celsius, system: themeManager.measureSystem))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(color.opacity(tempOpacity * 0.9))
                        .opacity(tempOpacity)
                }
                .scaleEffect(scale)
                .position(x: x, y: iconY)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Create Wave Path (optimisé : curseur séquentiel, pas de recherche par pixel)
    private func createWavePath(
        sortedTides: [TideData],
        size: CGSize,
        topMargin: CGFloat,
        drawHeight: CGFloat,
        adjustedMin: Double,
        heightSpan: Double
    ) -> Path {
        var path = Path()
        guard !sortedTides.isEmpty else { return path }

        var isFirst = true
        var cursor = 0 // Index courant dans sortedTides

        let step: CGFloat = 2
        for x in stride(from: 0, through: size.width, by: step) {
            let progress = x / size.width
            let date = startDate.addingTimeInterval(progress * totalDuration)

            // Avancer le curseur (les X sont ordonnés → le curseur avance toujours)
            while cursor < sortedTides.count - 1 && sortedTides[cursor + 1].date <= date {
                cursor += 1
            }

            // Interpolation cosinus standard (les points virtuels aux bords assurent la continuité)
            let height: Double
            if cursor < sortedTides.count - 1 {
                let prev = sortedTides[cursor]
                let next = sortedTides[cursor + 1]
                let duration = next.date.timeIntervalSince(prev.date)
                if duration > 0 {
                    let t = date.timeIntervalSince(prev.date) / duration
                    let cosT = (1 - cos(t * .pi)) / 2
                    height = prev.height + (next.height - prev.height) * cosT
                } else {
                    height = prev.height
                }
            } else {
                height = sortedTides.last?.height ?? 5.0
            }

            let normalizedHeight = (height - adjustedMin) / heightSpan
            let y = topMargin + drawHeight * (1 - CGFloat(normalizedHeight))

            if isFirst {
                path.move(to: CGPoint(x: x, y: y))
                isFirst = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }

    // MARK: - Couche vent (mode vent enrichi : vent + rafales + zone de sortie + observé)

    private func windX(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(startDate) / totalDuration) * width
    }

    /// Points HORAIRES (x,y) du vent (ou des rafales) dans la fenêtre visible, déjà LISSÉS
    /// par un noyau [0.25, 0.5, 0.25] sur les valeurs → enlève le jitter heure-à-heure avant
    /// le spline (sinon la courbe garde de petites bosses « dégueu »).
    private func windPoints(size: CGSize, topMargin: CGFloat, drawHeight: CGFloat,
                            maxWind: Double, gust: Bool) -> [CGPoint] {
        func wy(_ k: Double) -> CGFloat { topMargin + drawHeight * (1 - CGFloat(min(k, maxWind) / max(maxWind, 0.001))) }
        let sorted = windSorted
        let n = sorted.count
        guard n >= 1 else { return [] }
        func val(_ i: Int) -> Double { gust ? (sorted[i].windGustKmh ?? sorted[i].windSpeedKmh) : sorted[i].windSpeedKmh }
        var out: [CGPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let x = windX(sorted[i].time, width: size.width)
            guard x >= -6, x <= size.width + 6 else { continue }
            // Lissage léger [0.25, 0.5, 0.25] calculé à la volée (bords préservés) → zéro
            // tableau intermédiaire par frame.
            let v = (i > 0 && i < n - 1) ? val(i - 1) * 0.25 + val(i) * 0.5 + val(i + 1) * 0.25 : val(i)
            out.append(CGPoint(x: x, y: wy(v)))
        }
        return out
    }

    /// Spline LISSE (Catmull-Rom → Bézier cubique) : C1 continue → plus aucune cassure à
    /// chaque heure (l'ancien échantillonnage cosinus par segment laissait des angles).
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count >= 2 else { if let p = pts.first { path.move(to: p) }; return path }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Échantillonne DENSÉMENT le MÊME spline Catmull-Rom→Bézier que `smoothPath` en une
    /// polyligne lisse. Sert à colorer la courbe vent SEGMENT PAR SEGMENT tout en gardant
    /// EXACTEMENT la forme lisse de la courbe rafale (qui, elle, est tracée d'un seul `smoothPath`).
    private func smoothPolyline(_ pts: [CGPoint], perSegment: Int = 8) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        var out: [CGPoint] = [pts[0]]
        out.reserveCapacity((pts.count - 1) * perSegment + 1)
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            for s in 1...perSegment {
                let t = CGFloat(s) / CGFloat(perSegment), mt = 1 - t
                let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
                out.append(CGPoint(x: a * p1.x + b * c1.x + c * c2.x + d * p2.x,
                                   y: a * p1.y + b * c1.y + c * c2.y + d * p2.y))
            }
        }
        return out
    }

    /// Y EXACTE de la courbe (spline Catmull-Rom→Bézier, identique à smoothPolyline) à une
    /// abscisse → le point de suivi colle PILE au tracé (l'interpolation linéaire de
    /// interpolatedWind divergeait de ~1-5 px en milieu de segment du spline cubique).
    private func windCurveY(atX x: CGFloat, size: CGSize, topMargin: CGFloat, drawHeight: CGFloat, maxWind: Double, gust: Bool) -> CGFloat? {
        let pts = windPoints(size: size, topMargin: topMargin, drawHeight: drawHeight, maxWind: maxWind, gust: gust)
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var i = 0
        while i < pts.count - 1 && pts[i + 1].x < x { i += 1 }
        let p0 = i > 0 ? pts[i - 1] : pts[i]
        let p1 = pts[i], p2 = pts[i + 1]
        let p3 = i + 2 < pts.count ? pts[i + 2] : p2
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        let dx = p2.x - p1.x
        let t = dx > 0 ? max(0, min(1, (x - p1.x) / dx)) : 0  // x ≈ linéaire en t (pas horaire ~uniforme)
        let mt = 1 - t
        return mt * mt * mt * p1.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p2.y
    }

    /// Valeur LISSÉE (même noyau [0.25,0.5,0.25] que la courbe) du vent ou de la rafale,
    /// interpolée linéairement à une date → le point de suivi colle au tracé.
    private func interpolatedWind(at date: Date, gust: Bool) -> Double? {
        let sorted = windSorted
        let n = sorted.count
        guard n >= 1 else { return nil }
        func raw(_ i: Int) -> Double { gust ? (sorted[i].windGustKmh ?? sorted[i].windSpeedKmh) : sorted[i].windSpeedKmh }
        func sm(_ i: Int) -> Double { (i > 0 && i < n - 1) ? raw(i - 1) * 0.25 + raw(i) * 0.5 + raw(i + 1) * 0.25 : raw(i) }
        if date <= sorted[0].time { return sm(0) }
        if date >= sorted[n - 1].time { return sm(n - 1) }
        var hi = 1
        while hi < n && sorted[hi].time < date { hi += 1 }
        let lo = hi - 1
        let span = sorted[hi].time.timeIntervalSince(sorted[lo].time)
        let f = span > 0 ? date.timeIntervalSince(sorted[lo].time) / span : 0
        return sm(lo) + (sm(hi) - sm(lo)) * f
    }

    // MARK: - Surf : courbes façon mode VENT (points/heure + spline + Y-exacte-à-l'abscisse)

    static let surfPLo = 4.0, surfPHi = 16.0   // échelle période FIXE (s)
    private func surfBand(_ h: CGFloat) -> (crestCeil: CGFloat, baseline: CGFloat, bandH: CGFloat) {
        let c = h * 0.16, b = h * 0.50; return (c, b, b - c)
    }
    private var surfMaxH: Double { max(0.6, windSorted.compactMap { swellTrains($0).p1?.h }.max() ?? 1) }

    /// Points de contrôle HAUTEUR (1 par heure, lissage léger [0.25,0.5,0.25]) → exactement comme `windPoints`.
    private func surfHeightPoints(_ size: CGSize) -> [CGPoint] {
        let band = surfBand(size.height), maxH = surfMaxH
        let fc = windSorted, n = fc.count
        guard n >= 1 else { return [] }
        func v(_ i: Int) -> Double { swellTrains(fc[i]).p1?.h ?? 0 }
        var out: [CGPoint] = []; out.reserveCapacity(n)
        for i in 0..<n {
            let x = windX(fc[i].time, width: size.width)
            guard x >= -6, x <= size.width + 6 else { continue }
            let h = (i > 0 && i < n - 1) ? v(i - 1) * 0.25 + v(i) * 0.5 + v(i + 1) * 0.25 : v(i)
            out.append(CGPoint(x: x, y: band.baseline - CGFloat(min(h, maxH) / maxH) * band.bandH))
        }
        return out
    }
    /// Points de contrôle PÉRIODE (1 par heure) sur l'échelle s fixe 4–16.
    private func surfPeriodPoints(_ size: CGSize) -> [CGPoint] {
        let band = surfBand(size.height)
        let fc = windSorted, n = fc.count
        guard n >= 1 else { return [] }
        func v(_ i: Int) -> Double { swellTrains(fc[i]).p1?.t ?? Self.surfPLo }
        var out: [CGPoint] = []; out.reserveCapacity(n)
        for i in 0..<n {
            let x = windX(fc[i].time, width: size.width)
            guard x >= -6, x <= size.width + 6 else { continue }
            let t = (i > 0 && i < n - 1) ? v(i - 1) * 0.25 + v(i) * 0.5 + v(i + 1) * 0.25 : v(i)
            let norm = (min(max(t, Self.surfPLo), Self.surfPHi) - Self.surfPLo) / (Self.surfPHi - Self.surfPLo)
            out.append(CGPoint(x: x, y: band.baseline - CGFloat(norm) * band.bandH))
        }
        return out
    }
    /// Y EXACTE d'une spline Catmull-Rom→Bézier à l'abscisse x (identique à `windCurveY`) → le point colle PILE.
    private func splineY(atX x: CGFloat, in pts: [CGPoint]) -> CGFloat? {
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var i = 0
        while i < pts.count - 1 && pts[i + 1].x < x { i += 1 }
        let p0 = i > 0 ? pts[i - 1] : pts[i]
        let p1 = pts[i], p2 = pts[i + 1]
        let p3 = i + 2 < pts.count ? pts[i + 2] : p2
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        let dx = p2.x - p1.x
        let t = dx > 0 ? max(0, min(1, (x - p1.x) / dx)) : 0
        let mt = 1 - t
        return mt * mt * mt * p1.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p2.y
    }

    /// Mode vent : points VENT + RAFALE qui suivent le centre du viewport pendant le défilement
    /// (même technique de centrage que la courbe de marée classique), + pastille de lecture
    /// (direction / vent / rafale) au centre, placée sous l'en-tête.
    @ViewBuilder
    private var windTrackingOverlay: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("scroll"))
            let centerX = -frame.origin.x + screenWidth / 2
            // Appui long (scrub) → le curseur SUIT LE DOIGT et révèle les valeurs sur les
            // courbes vent/rafale ; sinon les points suivent le centre du viewport.
            let scrubbing = scrubState != nil
            let activeX = scrubState?.offsetX ?? centerX
            let activeDate: Date = scrubState?.date
                ?? startDate.addingTimeInterval(Double(centerX / max(geo.size.width, 1)) * totalDuration)
            let region = PremiumCurveCanvas.windRegion(geo.size.height)
            let maxW = PremiumCurveCanvas.windScaleMaxKmh(openMeteoForecasts)
            let wy: (Double) -> CGFloat = { k in region.top + region.height * (1 - CGFloat(min(k, maxW) / maxW)) }
            let unit = themeManager.windUnit
            let clampX: (CGFloat, CGFloat) -> CGFloat = { x, pad in min(max(x, pad), geo.size.width - pad) }

            ZStack {
                if let g = interpolatedWind(at: activeDate, gust: true) {
                    // y PILE sur le spline rafale (pas l'interpolation linéaire) → point collé au tracé.
                    let gy = windCurveY(atX: activeX, size: geo.size, topMargin: region.top, drawHeight: region.height, maxWind: maxW, gust: true) ?? wy(g)
                    WindTrackDot(color: windInk.opacity(isLight ? 0.55 : 0.8), filled: false)
                        .position(x: activeX, y: gy)
                    if scrubbing {
                        // Écarté vers la GAUCHE (le vent part à droite) → les 2 labels ne se chevauchent
                        // plus au centre.
                        windScrubLabel("raf \(UnitFormatter.windSpeedInt(g, unit: unit))", color: windInk.opacity(0.75))
                            .position(x: clampX(activeX - 58, 40), y: gy - 18)
                    }
                }
                if let w = interpolatedWind(at: activeDate, gust: false) {
                    // y PILE sur le spline vent → point collé au tracé (couleur = vitesse réelle).
                    let wpy = windCurveY(atX: activeX, size: geo.size, topMargin: region.top, drawHeight: region.height, maxWind: maxW, gust: false) ?? wy(w)
                    WindTrackDot(color: Self.windColorSmooth(w), filled: true)
                        .position(x: activeX, y: wpy)
                    if scrubbing {
                        // Écarté vers la DROITE (la rafale part à gauche) → plus de chevauchement au centre.
                        windScrubLabel("\(UnitFormatter.windSpeedInt(w, unit: unit)) \(unit.label)", color: Self.windColorSmooth(w))
                            .position(x: clampX(activeX + 58, 40), y: wpy + 20)
                    }
                }
                // Hauteur d'eau au scrub, PILE sur la courbe de marée APLATIE du mode vent (même
                // transform `flattenedTideY`), même position active (doigt) que vent/rafale → le
                // label n'apparaît QUE pendant l'appui long, pas en permanence.
                if scrubbing, let tideMetrics = (cachedTideMetrics ?? TideMetrics(tideData: tideData)) {
                    let h = Self.interpolateOnCurve(at: activeDate, metrics: tideMetrics)
                    let tm = geo.size.height * topMarginRatio
                    let dh = geo.size.height - tm - geo.size.height * bottomMarginRatio
                    let nH = tideMetrics.span > 0 ? (h - tideMetrics.adjustedMin) / tideMetrics.span : 0.5
                    let flatY = Self.flattenedTideY(tm + dh * CGFloat(1 - nH), topMargin: tm, drawHeight: dh)
                    windScrubLabel(UnitFormatter.height(h, system: themeManager.measureSystem, decimals: 1),
                                   color: Color.tideHigh)
                        .position(x: clampX(activeX, 46), y: flatY + 18)
                }
                windReadout(at: activeDate)
                    .position(x: clampX(activeX, 70), y: geo.size.height * 0.15)

                // Légende DÉPORTÉE du point VENT RÉEL (violet), façon repère AutoCAD : étiquette
                // décalée en BAS-gauche (plus de collision avec les rectangles d'activité, en
                // HAUT), reliée au point par un trait FIN. Vent + rafale balise.
                if let obs = observedWindKmh {
                    let nowX = windX(currentTime, width: geo.size.width)
                    let py = wy(obs)
                    let v = Color(red: 0.61, green: 0.5, blue: 0.88)

                    // MOUSTACHE rafale — « I-beam » INSTANTANÉ et mesuré : tige verticale
                    // creux ↔ moyen ↔ rafale au « maintenant ». La zone de rafale (moyen→rafale)
                    // s'efface vers le haut (drapeau de vent), mais HONNÊTE : que des valeurs réelles
                    // de l'instant — aucun historique fabriqué (décision « pas de comète »).
                    let capW: CGFloat = 7
                    // Brin RAFALE (moyen → rafale), dégradé qui s'estompe vers le haut.
                    if let g = observedGustKmh, g > obs {
                        let gy = wy(g)
                        Path { p in p.move(to: CGPoint(x: nowX, y: py)); p.addLine(to: CGPoint(x: nowX, y: gy)) }
                            .stroke(LinearGradient(colors: [v.opacity(0.85), v.opacity(0.10)],
                                                   startPoint: .bottom, endPoint: .top),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        Path { p in p.move(to: CGPoint(x: nowX - capW / 2, y: gy)); p.addLine(to: CGPoint(x: nowX + capW / 2, y: gy)) }
                            .stroke(v.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                    // Brin CREUX (lull → moyen), discret, seulement si la source le mesure.
                    if let m = observedMinKmh, m < obs {
                        let my = wy(m)
                        Path { p in p.move(to: CGPoint(x: nowX, y: py)); p.addLine(to: CGPoint(x: nowX, y: my)) }
                            .stroke(v.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        Path { p in p.move(to: CGPoint(x: nowX - capW / 2, y: my)); p.addLine(to: CGPoint(x: nowX + capW / 2, y: my)) }
                            .stroke(v.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }

                    // Étiquette en BAS-gauche du point.
                    let boxX = clampX(nowX - 96, 64)
                    let boxY = min(py + 46, geo.size.height - 22)
                    Path { p in
                        p.move(to: CGPoint(x: nowX, y: py))
                        p.addLine(to: CGPoint(x: boxX + 8, y: boxY - 9))
                    }
                    .stroke(v.opacity(0.6), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    Circle().fill(v).frame(width: 3, height: 3).position(x: nowX, y: py)
                    realWindLegend(obs: obs).position(x: boxX, y: boxY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Pastille déportée « vent réel » (mesure balise) reliée au point violet.
    private func realWindLegend(obs: Double) -> some View {
        let v = Color(red: 0.61, green: 0.5, blue: 0.88)
        let unit = themeManager.windUnit
        return HStack(spacing: 5) {
            Circle().fill(v).frame(width: 6, height: 6)
            Text("réel").font(.system(size: 8, weight: .semibold)).foregroundStyle(v.opacity(0.9))
            // Direction du vent RÉEL (balise) — manquait sur la pastille. Flèche + cardinal,
            // même convention (dir + 180 = sens vers lequel le vent souffle) que la pastille prévision.
            if let dir = observedWindDirection {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(v.opacity(0.9))
                    .rotationEffect(.degrees(dir + 180))
                Text(WindTidePlanner.cardinal(dir))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            (Text("\(UnitFormatter.windSpeedInt(obs, unit: unit)) ").font(.system(size: 13, weight: .bold, design: .rounded))
                + Text(unit.label).font(.system(size: 8, weight: .medium)))
                .foregroundStyle(.primary)
            if let g = observedGustKmh {
                Text("raf \(UnitFormatter.windSpeedInt(g, unit: unit))")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(v.opacity(0.4), lineWidth: 0.5))
        .fixedSize()
    }

    // MARK: - Mode surf : lecture houle (centre + scrub)

    /// Lecture permanente (centre du viewport) de la houle dominante en mode surf : chevron orienté
    /// au sens de propagation + « 1,4 m · 12 s · O », période teintée surfColor. Si aucune donnée de
    /// houle → « houle indisponible (modèle) » (jamais 0 m, jamais une valeur fabriquée).
    private func surfReadout(_ dom: (h: Double, t: Double, dir: Double?)?) -> some View {
        let sys = themeManager.measureSystem
        return Group {
            if let d = dom {
                let c = Self.surfColor(period: d.t)
                HStack(spacing: 7) {
                    // Même glyphe de direction que partout (dock, card, dashboard) : flèche nav iOS, orange.
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .rotationEffect(.degrees((d.dir ?? 0) + 180))
                    (Text(UnitFormatter.height(d.h, system: sys, decimals: 1)).font(.system(size: 16, weight: .bold, design: .rounded))
                        + Text(" · \(Int(d.t.rounded())) s").font(.system(size: 11, weight: .semibold)))
                        .foregroundStyle(c)
                    if d.dir != nil {
                        Text(WindTidePlanner.cardinal(d.dir ?? 0))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .padding(.horizontal, 11).padding(.vertical, 5.5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
                .fixedSize()
            } else {
                Text("houle indisponible")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 5.5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
                    .fixedSize()
            }
        }
    }

    /// Overlay du mode SURF : lecture permanente au centre, pastille au scrub (triplet + casse en
    /// PLAGE, jamais un chiffre spot), clé de lecture des lignes. Lit `scrubState` (geste partagé,
    /// aucun geste concurrent). N'apparaît qu'en mode surf — windTrackingOverlay est mode-vent only.

    private var surfTrackingOverlay: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("scroll"))
            let centerX = -frame.origin.x + screenWidth / 2
            let activeX = scrubState?.offsetX ?? centerX
            let activeDate: Date = scrubState?.date
                ?? startDate.addingTimeInterval(Double(centerX / max(geo.size.width, 1)) * totalDuration)
            let clampX: (CGFloat, CGFloat) -> CGFloat = { x, pad in min(max(x, pad), geo.size.width - pad) }
            let sys = themeManager.measureSystem
            let dom = closestForecast(for: activeDate).flatMap { dominantSwell($0) }

            // Géométrie + SPLINES identiques à drawSurfLayer (technique vent) → les points collent pile.
            let band = surfBand(geo.size.height)
            let bandH = band.bandH, bLine = band.baseline
            let wMax = surfMaxH
            let heightPts = surfHeightPoints(geo.size)
            let periodPts = surfPeriodPoints(geo.size)
            let yHscale: (Double) -> CGFloat = { bLine - CGFloat(min($0, wMax) / wMax) * bandH }
            let yPscale: (Double) -> CGFloat = { bLine - CGFloat((min(max($0, Self.surfPLo), Self.surfPHi) - Self.surfPLo) / (Self.surfPHi - Self.surfPLo)) * bandH }
            let stp: Double = wMax <= 1 ? 0.25 : (wMax <= 2 ? 0.5 : (wMax <= 4 ? 1 : 2))
            let rightX = clampX(centerX + screenWidth / 2 - 20, 20)
            let leftX = clampX(centerX - screenWidth / 2 + 16, 16)
            let cyan = Self.surfHeight

            ZStack {
                // Échelle HAUTEUR « m » à DROITE.
                ForEach(Array(stride(from: stp, through: Double(wMax), by: stp)), id: \.self) { hv in
                    Text(UnitFormatter.height(hv, system: sys, decimals: 1))
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        .position(x: rightX, y: yHscale(hv))
                }
                // Échelle PÉRIODE « s » à GAUCHE.
                ForEach([6.0, 10.0, 14.0], id: \.self) { pv in
                    Text("\(Int(pv)) s")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Self.surfColor(period: pv)).monospacedDigit()
                        .position(x: leftX, y: yPscale(pv))
                }

                // 2 POINTS de suivi : lisent la SPLINE à l'abscisse (collent pile sur la courbe). Les
                // LABELS, eux, sont à HAUTEUR FIXE (2 slots en haut de la bande) — ils ne montent /
                // descendent PAS avec le point. Ce sont les LIGNES de connexion (animées) qui s'étirent
                // du label fixe jusqu'au point qui bouge sur la courbe → jamais de chevauchement.
                if let d = dom {
                    let dotX = clampX(activeX, 8)
                    let hy = splineY(atX: activeX, in: heightPts) ?? yHscale(d.h)
                    let py = splineY(atX: activeX, in: periodPts) ?? yPscale(d.t)
                    let pCol = Self.surfColor(period: d.t)
                    // Labels « légende » posés JUSTE À GAUCHE de leur propre point (plus de lignes de
                    // connexion) : la hauteur derrière le point hauteur, la période derrière le point
                    // période. Léger décalage vertical (±11) → aucun chevauchement même quand les deux
                    // courbes se croisent. Décalés à gauche pour rester « derrière » le curseur.
                    let hLabelX = clampX(dotX - 34, 30)
                    let pLabelX = clampX(dotX - 34, 30)
                    // Chaque label s'écarte de l'AUTRE : le point le plus haut prend son label au-dessus,
                    // le plus bas en dessous → jamais de chevauchement, même quand les courbes se croisent.
                    let hAbove = hy <= py

                    // Curseur « maintenant » de la HAUTEUR (repère principal) : une fine règle néon
                    // verticale (donne le sens « position sur la courbe ») + un cœur en verre sombre
                    // cerclé de néon. Remplace l'ancien bullseye plat « on ne sait pas ce que c'est ».
                    Capsule()
                        .fill(LinearGradient(colors: [cyan.opacity(0.0), cyan.opacity(0.55)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5, height: 14)
                        .position(x: dotX, y: hy - 7)
                    ZStack {
                        Circle().fill(Self.surfDotCore)
                            .background(.ultraThinMaterial, in: Circle())
                            .frame(width: 16, height: 16)
                        Circle().stroke(cyan, lineWidth: 1.5).frame(width: 16, height: 16)
                        Circle().fill(cyan).frame(width: 5, height: 5)
                    }
                    .shadow(color: cyan.opacity(0.8), radius: 6)
                    .shadow(color: cyan.opacity(0.4), radius: 12)
                    .position(x: dotX, y: hy)
                    // Marqueur PÉRIODE (subordonné) : anneau creux discret, ne rivalise pas avec le curseur.
                    Circle().stroke(pCol.opacity(0.9), lineWidth: 2).frame(width: 8, height: 8)
                        .background(Circle().fill(Self.surfDotCore))
                        .shadow(color: pCol.opacity(0.6), radius: 4)
                        .position(x: dotX, y: py)

                    surfDotLabel(UnitFormatter.height(d.h, system: sys, decimals: 1), color: cyan)
                        .position(x: hLabelX, y: hy + (hAbove ? -12 : 12))
                    surfDotLabel("\(Int(d.t.rounded())) s", color: pCol)
                        .position(x: pLabelX, y: py + (hAbove ? 12 : -12))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Bandeau DIRECTION (mode surf) façon bandeau météo, avec effet DOCK (l'arrivée au centre du
    /// scroll grossit). Posé au-dessus de la courbe ; remplace la boussole. Suit le défilement.
    @ViewBuilder
    private var surfDirectionStripOverlay: some View {
        if !openMeteoForecasts.isEmpty {
            GeometryReader { geo in
                let frame = geo.frame(in: .named("scroll"))
                let visibleCenterX = -frame.origin.x + screenWidth / 2
                let stripY = geo.size.height * 0.80   // EN BAS (remplace le bandeau météo en mode surf)
                let cal = Calendar.inTimeZone(portTimeZone)
                let keyHours = windSorted.filter { Self.weatherHours.contains(cal.component(.hour, from: $0.time)) }
                ForEach(Array(keyHours.enumerated()), id: \.offset) { _, f in
                    let dom = dominantSwell(f)
                    let x = windX(f.time, width: geo.size.width)
                    let dist = abs(x - visibleCenterX)
                    let scale = Self.dockScale(distance: dist)
                    let col = Self.surfColor(period: dom?.t ?? 10)
                    VStack(spacing: 2) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(col)
                            .shadow(color: col.opacity(0.7), radius: dist < 50 ? 4 : 0)
                            .rotationEffect(.degrees((dom?.dir ?? 0) + 180))
                        if dist < Self.tempShowRadius, let dir = dom?.dir {
                            Text(WindTidePlanner.cardinal(dir))
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(Double(1 - dist / Self.tempShowRadius)))
                        }
                    }
                    .scaleEffect(scale)
                    .opacity(dom == nil ? 0 : (0.4 + 0.6 * Double(max(0, 1 - dist / 120))))
                    .position(x: x, y: stripY)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Pastille de valeur d'un point de suivi (hauteur ou période).
    private func surfDotLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(color).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
    }

    /// Petit libellé de valeur posé sur la courbe pendant le scrub (mode vent).
    private func windScrubLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
    }

    /// Pastille de lecture : direction (flèche + cardinal), vent coloré Beaufort, rafale —
    /// au temps `date` (le centre du viewport), valeurs lissées.
    @ViewBuilder
    private func windReadout(at date: Date) -> some View {
        if let fc = closestForecast(for: date) {
            let unit = themeManager.windUnit
            let windKmh = interpolatedWind(at: date, gust: false) ?? fc.windSpeedKmh
            HStack(spacing: 7) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .rotationEffect(.degrees(fc.windDirection + 180))
                Text(WindTidePlanner.cardinal(fc.windDirection))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                (Text("\(UnitFormatter.windSpeedInt(windKmh, unit: unit))").font(.system(size: 16, weight: .bold, design: .rounded))
                    + Text(" \(unit.label)").font(.system(size: 9, weight: .medium)))
                    .foregroundStyle(Self.windColorSmooth(windKmh))
                if fc.windGustKmh != nil, let g = interpolatedWind(at: date, gust: true) {
                    Text("raf \(UnitFormatter.windSpeedInt(g, unit: unit))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
            .animation(nil, value: windKmh)
        }
    }

    /// Fenêtre « imminente » : commence dans ≤ 2 h (ou déjà en cours) → on y affiche le « Go X% »
    /// vivant basé sur le vent réel observé juste avant.
    private func isImminent(_ start: Date, _ end: Date) -> Bool {
        start <= currentTime.addingTimeInterval(2 * 3600) && end >= currentTime
    }

    /// Indice de confiance 0–100 % : à quel point le vent RÉELLEMENT observé (balise, frais)
    /// colle aux conditions du sport pour cette fenêtre. nil si pas de mesure fraîche/exploitable.
    private func goPercentage(for setup: SportSetup) -> Int? {
        guard let obs = observedWindKmh else { return nil }
        if let age = observedWindAgeMinutes, age > 20 { return nil }   // mesure trop vieille → pas de %
        guard let wind = setup.conditions.first(where: { $0.type == .windSpeed }) else { return nil }
        // Bornes min/max selon l'opérateur (avant : seul .between donnait un %).
        let minKmh: Double
        let maxKmh: Double?
        switch wind.operator1 {
        case .between:     minKmh = wind.value1; maxKmh = wind.value2
        case .greaterThan: minKmh = wind.value1; maxKmh = nil
        case .lessThan:    minKmh = 0;           maxKmh = wind.value1
        case .equals:      minKmh = wind.value1; maxKmh = wind.value1
        }

        var score = 100.0
        if obs < minKmh { score = max(0, 100 - (minKmh - obs) * 8) }              // -8 %/km/h sous le mini
        else if let hi = maxKmh, obs > hi { score = max(0, 100 - (obs - hi) * 6) } // -6 %/km/h au-dessus du maxi

        if let g = observedGustKmh, let hi = maxKmh, g > hi {
            score = max(0, score - (g - hi) * 3)                                  // rafale au-dessus → pénalité
        }
        if let dir = observedWindDirection,
           let dc = setup.conditions.first(where: { $0.type == .windDirection }) {
            let center = dc.windDirectionCenter ?? dc.value1
            let spread = dc.windDirectionSpread ?? dc.value2 ?? 45
            let off = WindTidePlanner.angularDistance(dir, center) - spread
            if off > 0 { score = max(0, score - off * 0.8) }              // hors secteur → pénalité
        }
        return Int(score.rounded())
    }

    private func drawWindLayer(context: inout GraphicsContext, size: CGSize) {
        // Région DÉDIÉE en haut (la marée aplatie occupe le bas) → courbes remontées.
        let region = Self.windRegion(size.height)
        let topMargin = region.top, drawHeight = region.height
        let maxWind = Self.windScaleMaxKmh(openMeteoForecasts)
        func wy(_ k: Double) -> CGFloat { topMargin + drawHeight * (1 - CGFloat(min(k, maxWind) / max(maxWind, 0.001))) }
        // GO — rendu UNIFIÉ (mêmes fenêtres + même style qu'en mode surf ; corrélé au calendrier).
        drawGoWindows(&context, size: size, top: topMargin, height: drawHeight)

        // Rafales — spline lisse, pointillé.
        let gustPath = smoothPath(windPoints(size: size, topMargin: topMargin, drawHeight: drawHeight, maxWind: maxWind, gust: true))
        context.stroke(gustPath, with: .color(windInk.opacity(isLight ? 0.42 : 0.44)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [3, 4]))

        // Vent — MÊME spline lisse que la rafale (windPoints + Catmull-Rom), mais échantillonné
        // densément et coloré SEGMENT PAR SEGMENT avec windColorSmooth → forme aussi lisse que la
        // rafale ET couleur exacte du point (le point de suivi, qui lit windPoints, colle au tracé).
        let windPts = windPoints(size: size, topMargin: topMargin, drawHeight: drawHeight, maxWind: maxWind, gust: false)
        let dense = smoothPolyline(windPts)
        if dense.count >= 2 {
            // Glow néon (flou → couleur approximative invisible) : un seul tracé via le gradient.
            if !isLight {
                var glowPath = Path()
                glowPath.move(to: dense[0])
                for p in dense.dropFirst() { glowPath.addLine(to: p) }
                let shading = GraphicsContext.Shading.linearGradient(
                    cachedWindGradient, startPoint: CGPoint(x: 0, y: size.height / 2), endPoint: CGPoint(x: size.width, y: size.height / 2))
                var glow = context; glow.addFilter(.blur(radius: 9)); glow.opacity = 0.4
                glow.stroke(glowPath, with: shading, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }
            // Trait net : UN SEUL tracé coloré par le gradient vent (couleur ≈ exacte par heure, le
            // gradient étant construit des couleurs de vent horaires). Remplace ~1300 strokes par
            // segment par 1 — le glow ci-dessus prouvait déjà l'équivalence visuelle du gradient.
            let lw: CGFloat = isLight ? 3.0 : 2.8
            var netPath = Path()
            netPath.move(to: dense[0])
            for p in dense.dropFirst() { netPath.addLine(to: p) }
            context.stroke(netPath,
                           with: .linearGradient(cachedWindGradient,
                                                 startPoint: CGPoint(x: 0, y: size.height / 2),
                                                 endPoint: CGPoint(x: size.width, y: size.height / 2)),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }

        // Vent OBSERVÉ (réel, ancré à « maintenant ») : anneau violet seul. La VALEUR est
        // déportée dans la légende animée en pied de TodayView (ObservedWindCard).
        if let obs = observedWindKmh {
            let nx = windX(currentTime, width: size.width)
            let p = CGPoint(x: nx, y: wy(obs))
            let v = Color(red: 0.61, green: 0.5, blue: 0.88)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(v.opacity(0.22)))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(v), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2.4, y: p.y - 2.4, width: 4.8, height: 4.8)), with: .color(v))
        }
    }

    // MARK: - Surf Layer (mode surf)

    /// Couleur « période » du mode surf, source UNIQUE (courbe période, échelle, point de suivi,
    /// particules). DÉGRADÉ honnête : période COURTE = clapot → ROUGE-ORANGE ; période LONGUE =
    /// groundswell propre → VERT. Rampe à 5 arrêts (rouge-orange → orange → ambre → lime → vert)
    /// sur une fenêtre RESSERRÉE 6–15 s : la plage surf utile occupe tout le dégradé → forte
    /// sensibilité (un écart de 1-2 s se voit). Couleurs saturées → lisibles AUSSI en mode clair.
    /// (La HAUTEUR garde son cyan adaptatif `surfHeight` → les deux courbes restent distinctes.)
    static func surfColor(period: Double) -> Color {
        let t = min(max((period - 6) / 9, 0), 1)   // 6 s → 0, 15 s → 1 (fenêtre utile)
        let stops: [(Double, Double, Double)] = [
            (0.96, 0.36, 0.12),   // rouge-orange (clapot très court)
            (0.99, 0.55, 0.12),   // orange
            (0.92, 0.72, 0.10),   // ambre saturé
            (0.52, 0.74, 0.14),   // lime
            (0.14, 0.70, 0.36)    // vert (groundswell long)
        ]
        let seg = stops.count - 1
        let p = t * Double(seg), i = min(Int(p), seg - 1), f = p - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f,
                     green: a.1 + (b.1 - a.1) * f,
                     blue: a.2 + (b.2 - a.2) * f)
    }

    /// Couleur HAUTEUR du mode surf — ADAPTATIVE : cyan pâle sur fond sombre, cyan PROFOND sur fond
    /// clair (le pâle `(0.85,0.96,1.0)` était quasi-blanc → courbe/curseur/label invisibles en clair).
    static let surfHeight = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.85, green: 0.96, blue: 1.0, alpha: 1)
            : UIColor(red: 0.10, green: 0.52, blue: 0.72, alpha: 1)
    })

    /// Cœur des points/curseur surf — ADAPTATIF : disque sombre sur fond sombre, disque CLAIR sur
    /// fond clair (le noir fixe ressortait comme une grosse pastille noire en mode clair).
    static let surfDotCore = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor.white.withAlphaComponent(0.92)
    })

    /// Calque SURF : zones GO (par-sport, identiques au calendrier) + TRAINS DE HOULE = sets
    /// parallèles en PERSPECTIVE (espacement ∝ période, corps flou de relief, luminosité ∝ hauteur),
    /// vus « depuis la dune ». Aligné sur le même axe temps que la marée. Les zones GO lisent le prop
    /// `goWindows` (source unique, scorée, == calendrier) ; les trains lisent `windSorted`.
    /// Dessin UNIFIÉ des fenêtres GO (mode vent ET surf, MÊME rendu) : pour chaque fenêtre de chaque
    /// sport, une capsule colorée-sport labellisée « 7h–22h » en haut de la bande + tint très léger.
    /// `goWindows` vient du MÊME `ActivityGoPlanner.plan` que le calendrier → parfaitement corrélé.
    private func drawGoWindows(_ context: inout GraphicsContext, size: CGSize, top: CGFloat, height: CGFloat) {
        guard !goWindows.isEmpty else { return }
        // Lanes = sports présents, ordre stable (sportSetups) → empilées pour voir plusieurs activités
        // sur le même créneau.
        var sports: [WindSport] = []
        for s in sportSetups where !sports.contains(s.sport) && goWindows.contains(where: { $0.sport == s.sport }) {
            sports.append(s.sport)
        }
        for g in goWindows where !sports.contains(g.sport) { sports.append(g.sport) }
        guard !sports.isEmpty else { return }

        let n = sports.count
        let gap: CGFloat = n > 1 ? 3 : 0
        // Lane assez HAUTE pour 2 lignes (nom + durée en haut, étoiles dessous) : la bande GRANDIT
        // avec le nombre de sports (effet « étagé »), bornée pour ne pas couvrir le bandeau du bas.
        // Avant : bandH = 0,40 × une sous-région déjà petite (~0,32 H) → lanes de 6-12 px à 3-5
        // sports, donc labels/étoiles coupés par les gates (12/26 px) = fenêtres « invisibles ».
        let idealLane: CGFloat = 26
        let bandTop = top + height * 0.04
        let maxBand = size.height * 0.42
        let wantBand = CGFloat(n) * idealLane + CGFloat(max(0, n - 1)) * gap
        // Le plancher (avant 0,40 × sous-région déjà petite) gonflait 1-2 sports en une bande
        // couvrant ~40-52 % de la hauteur. On laisse le BESOIN réel (wantBand) piloter : 1 sport
        // = 26 px (passe le gate étoiles >24 + nom/durée >12), N sports grandissent par paliers
        // jusqu'au plafond 0,42 → ~10 % de hauteur rendue à la courbe.
        let bandH = min(maxBand, max(height * 0.26, wantBand))
        let laneH = (bandH - gap * CGFloat(n - 1)) / CGFloat(n)

        for (li, sport) in sports.enumerated() {
            let color = sport.color
            let y = bandTop + CGFloat(li) * (laneH + gap)
            let setup = sportSetups.first(where: { $0.sport == sport })
            for g in goWindows where g.sport == sport {
                let x0 = windX(g.start, width: size.width), x1 = windX(g.end, width: size.width)
                guard x1 > -12, x0 < size.width + 12 else { continue }
                let w = max(x1 - x0, 5)
                let rr = Path(roundedRect: CGRect(x: x0, y: y, width: w, height: laneH), cornerRadius: 7)
                context.fill(rr, with: .color(color.opacity(0.14)))
                context.stroke(rr, with: .color(color.opacity(0.5)), lineWidth: 1)
                if g.isPeak {
                    // « LE meilleur créneau » à venir : bande accentuée + couronne au centre-haut.
                    context.fill(rr, with: .color(color.opacity(0.12)))
                    context.stroke(rr, with: .color(color.opacity(0.95)), style: StrokeStyle(lineWidth: 1.6))
                    if w > 24 {
                        let crown = context.resolve(Text(Image(systemName: "crown.fill"))
                            .font(.system(size: 8.5, weight: .bold)).foregroundColor(color))
                        context.draw(crown, at: CGPoint(x: (x0 + x1) / 2, y: y + 8), anchor: .center)
                    }
                }
                let topY = y + 9
                // NOM de l'activité (HAUT-gauche)
                if w > 48, laneH > 12 {
                    let label = context.resolve(Text(sport.localizedName)
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(color))
                    context.draw(label, at: CGPoint(x: x0 + 6, y: topY), anchor: .leading)
                }
                // « Go X% » live (imminent + balise) SINON durée (HAUT-droite)
                let goPct: Int? = (hasBalise && isImminent(g.start, g.end)) ? setup.flatMap { goPercentage(for: $0) } : nil
                if let pct = goPct, w > 60, laneH > 12 {
                    let tag = context.resolve(Text("Go \(pct)%")
                        .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(color))
                    context.draw(tag, at: CGPoint(x: x1 - 6, y: topY), anchor: .trailing)
                } else if w > 56, laneH > 12 {
                    let mins = max(0, Int(g.end.timeIntervalSince(g.start) / 60))
                    let durText = mins >= 60
                        ? (mins % 60 == 0 ? "\(mins / 60) h" : "\(mins / 60) h\(String(format: "%02d", mins % 60))")
                        : "\(mins) min"
                    let dur = context.resolve(Text(durText)
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(color.opacity(0.85)))
                    context.draw(dur, at: CGPoint(x: x1 - 6, y: topY), anchor: .trailing)
                }
                // ÉTOILES de qualité de session (SOUS le nom) — AUTO uniquement. Le jour J, près de la
                // fenêtre, la note RÉELLE (refinedStars, relevés balise/bouée) remplace la prévision,
                // étoiles en blanc + petit point « live » (teal = calé sur bouée, blanc = balise vent).
                let usingLive = isImminent(g.start, g.end) && g.refinedStars != nil
                let shownStars = usingLive ? g.refinedStars : g.stars
                if let st0 = shownStars, w > 40, laneH > 24 {
                    let st = max(1, min(5, st0))
                    // RATING PIPS (remplace les ★ unicode illisibles à 9pt) : 5 pastilles rondes
                    // dessinées en géométrie pure → nettes à toute taille, indépendantes de la police.
                    // Pleines = note, vides = cadre (on COMPTE filled/total). Live = blanc, prévi = couleur.
                    let pipD: CGFloat = 5            // diamètre pastille
                    let pipGap: CGFloat = 3          // espace entre pastilles
                    let pipStep = pipD + pipGap      // 8pt
                    let pipX0 = x0 + 6
                    // Centré verticalement dans l'espace SOUS la ligne nom (entre topY et le bas de lane).
                    let pipY = min(topY + 13, y + laneH - pipD - 3)
                    let fillCol = usingLive ? Color.white : color
                    for i in 0..<5 {
                        let r = CGRect(x: pipX0 + CGFloat(i) * pipStep, y: pipY, width: pipD, height: pipD)
                        let pip = Path(ellipseIn: r)
                        if i < st {
                            context.fill(pip, with: .color(fillCol))
                        } else {
                            // pastille vide = anneau discret (cadre comptable)
                            context.fill(pip, with: .color(fillCol.opacity(0.18)))
                            context.stroke(pip, with: .color(fillCol.opacity(0.5)), lineWidth: 0.75)
                        }
                    }
                    if usingLive {
                        // point « live » déterministe juste après la 5e pastille
                        let dotX = pipX0 + 5 * pipStep + 1
                        let live = g.provenance == .buoyAnchored ? Color(red: 0.20, green: 0.86, blue: 0.62) : Color.white
                        context.fill(Path(ellipseIn: CGRect(x: dotX, y: pipY, width: pipD, height: pipD)), with: .color(live))
                    }
                }
            }
        }
    }

    private func drawSurfLayer(context: inout GraphicsContext, size: CGSize) {
        let fc = windSorted
        guard !fc.isEmpty, size.width > 1 else { return }

        // ── 2 COURBES (technique mode VENT) : HAUTEUR (m, droite) + PÉRIODE (s, gauche) ───────────
        // Points 1/heure + spline Catmull-Rom (smoothPath) → ULTRA-LISSE. Les points de suivi lisent
        // la spline À L'ABSCISSE (splineY) → ils collent pile. GO surf présentés comme le mode vent.
        let band = surfBand(size.height)
        let crestCeil = band.crestCeil, baseline = band.baseline, bandH = band.bandH
        let maxH = surfMaxH
        let daylight: (Date) -> Bool = { date in
            sunTimes.isEmpty ? true : sunTimes.contains { date >= $0.sunrise && date <= $0.sunset }
        }

        let ptsH = surfHeightPoints(size)
        let ptsP = surfPeriodPoints(size)
        guard ptsH.count >= 2 else { return }

        // Gridlines HAUTEUR (faibles ; labels « m » à droite dans l'overlay).
        let step: Double = maxH <= 1 ? 0.25 : (maxH <= 2 ? 0.5 : (maxH <= 4 ? 1 : 2))
        var hk = step
        while hk <= maxH + 0.001 {
            let gy = baseline - CGFloat(min(hk, maxH) / maxH) * bandH
            var gl = Path(); gl.move(to: CGPoint(x: 0, y: gy)); gl.addLine(to: CGPoint(x: size.width, y: gy))
            context.stroke(gl, with: .color(.gray.opacity(0.10)), style: StrokeStyle(lineWidth: 0.5))
            hk += step
        }

        // GO — rendu UNIFIÉ (mêmes fenêtres + même style qu'en mode vent ; corrélé au calendrier).
        drawGoWindows(&context, size: size, top: crestCeil, height: bandH)
        _ = daylight   // (gardé pour un éventuel repli ; évite l'avertissement « inutilisé »)

        // COURBE PÉRIODE (s) — trait fin coloré par période (cyan→violet), derrière.
        let periodStops: [Gradient.Stop] = windSorted.compactMap { f in
            let gx = windX(f.time, width: size.width)
            guard gx >= 0, gx <= size.width else { return nil }
            return Gradient.Stop(color: Self.surfColor(period: swellTrains(f).p1?.t ?? 8), location: min(max(gx / size.width, 0), 1))
        }
        if periodStops.count >= 2 {
            context.stroke(smoothPath(ptsP),
                           with: .linearGradient(Gradient(stops: periodStops), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)),
                           style: StrokeStyle(lineWidth: isLight ? 2.8 : 2.4, lineCap: .round, lineJoin: .round))
        }

        // COURBE HAUTEUR (m) — principale : trait écume + glow (PAS de remplissage plein).
        let crestLight = Self.surfHeight
        if !isLight {
            var g = context; g.addFilter(.blur(radius: 6)); g.opacity = 0.5
            g.stroke(smoothPath(ptsH), with: .color(crestLight.opacity(0.5)),
                     style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        context.stroke(smoothPath(ptsH), with: .color(crestLight),
                       style: StrokeStyle(lineWidth: isLight ? 3.0 : 2.5, lineCap: .round, lineJoin: .round))
    }

    /// Deux trains de houle dominants (par énergie Hs²·T) : primaire (courbe pleine) + secondaire
    /// (courbe pointillée), à la manière vent/rafale. Même convention que TodayView.partitions.
    private func swellTrains(_ f: HourlyForecast) -> (p1: (h: Double, t: Double, dir: Double?)?, p2: (h: Double, t: Double, dir: Double?)?) {
        let ps = SurfMetrics.partitions(f)   // SOURCE UNIQUE du tri (cf. SurfMetrics.partitions)
        let p1 = ps.first.map { (h: $0.height, t: $0.period, dir: $0.direction) }
        let p2 = ps.count > 1 ? (h: ps[1].height, t: ps[1].period, dir: ps[1].direction) : nil
        return (p1, p2)
    }


    /// Partition de houle DOMINANTE (par énergie Hs²·T) d'une prévision — même convention que
    /// TodayView.partitions : houle primaire (période pic préférée) → 2nde → 3e → houle totale en
    /// secours, chacune exigeant h > 0,05 m et t > 0. Source unique pour la courbe ET la légende surf.
    private func dominantSwell(_ f: HourlyForecast) -> (h: Double, t: Double, dir: Double?)? {
        SurfMetrics.partitions(f).first.map { (h: $0.height, t: $0.period, dir: $0.direction) }   // source unique
    }

    // MARK: - Wind Colored Curve

    /// Construit un gradient horizontal dont les stops reprennent la couleur du vent
    /// à chaque heure de prévision. Un seul stroke, zéro lag.
    private func windGradient(size: CGSize) -> Gradient {
        cachedWindGradient
    }

    /// (Re)construit le dégradé vent SOUS-ÉCHANTILLONNÉ (~24 stops max). Le vent varie en
    /// douceur → peu de stops suffisent, et un dégradé à peu de stops est bien moins
    /// coûteux à rendre par frame (le « thick trail » le re-rend pendant le scroll).
    static func makeWindGradient(forecasts: [HourlyForecast], startDate: Date, totalDuration: TimeInterval) -> Gradient {
        let fallback = Gradient(colors: [Color.tideHigh, Color.tideLow])
        guard forecasts.count >= 2, totalDuration > 0 else { return fallback }
        let sorted = forecasts.sorted { $0.time < $1.time }

        // Résolution HORAIRE (un stop par heure) : le sous-échantillonnage à 24 stops faisait
        // diverger la couleur interpolée du dégradé de la couleur réelle (vitesse) du point animé.
        // Avec un stop par point horaire, le dégradé colle au mapping windColorSmooth du point.
        let maxStops = 240
        let step = max(1, sorted.count / maxStops)
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(min(sorted.count, maxStops) + 1)

        func appendStop(_ fc: HourlyForecast) {
            let progress = fc.time.timeIntervalSince(startDate) / totalDuration
            guard progress >= -0.05 && progress <= 1.05 else { return }
            stops.append(.init(color: windColorSmooth(fc.windSpeedKmh), location: min(max(progress, 0), 1)))
        }

        var i = 0
        while i < sorted.count { appendStop(sorted[i]); i += step }
        if let last = sorted.last { appendStop(last) }  // toujours fermer sur le dernier point

        guard stops.count >= 2 else { return fallback }
        stops.sort { $0.location < $1.location }
        return Gradient(stops: stops)
    }

    /// Palette vent douce et harmonieuse : bleu → vert → jaune → rouge
    /// Interpolation continue (pas de sauts de couleur)
    static func windColorSmooth(_ kmh: Double) -> Color {
        // 0→8: bleu profond, 8→15: bleu-vert, 15→25: vert-jaune, 25→35: jaune-orange, 35+: rouge
        let t = min(max(kmh, 0), 50)

        if t < 8 {
            // Bleu profond → bleu-teal
            let p = t / 8
            return Color(
                red: 0.1 * (1 - p) + 0.0 * p,
                green: 0.5 * (1 - p) + 0.75 * p,
                blue: 0.9 * (1 - p) + 0.85 * p
            )
        } else if t < 15 {
            // Bleu-teal → vert
            let p = (t - 8) / 7
            return Color(
                red: 0.0 * (1 - p) + 0.2 * p,
                green: 0.75 * (1 - p) + 0.8 * p,
                blue: 0.85 * (1 - p) + 0.3 * p
            )
        } else if t < 25 {
            // Vert → jaune
            let p = (t - 15) / 10
            return Color(
                red: 0.2 * (1 - p) + 0.95 * p,
                green: 0.8 * (1 - p) + 0.85 * p,
                blue: 0.3 * (1 - p) + 0.1 * p
            )
        } else if t < 35 {
            // Jaune → orange-rouge
            let p = (t - 25) / 10
            return Color(
                red: 0.95 * (1 - p) + 0.95 * p,
                green: 0.85 * (1 - p) + 0.3 * p,
                blue: 0.1 * (1 - p) + 0.1 * p
            )
        } else {
            // Orange-rouge → rouge vif
            let p = min((t - 35) / 15, 1)
            return Color(
                red: 0.95 * (1 - p) + 0.85 * p,
                green: 0.3 * (1 - p) + 0.1 * p,
                blue: 0.1 * (1 - p) + 0.2 * p
            )
        }
    }

    // MARK: - Helpers
    private func xPosition(for date: Date) -> CGFloat {
        let offset = date.timeIntervalSince(startDate)
        return CGFloat(offset / totalDuration) * totalWidth
    }

    /// Positions X de chaque minuit dans l'espace Canvas (pas totalWidth)
    private func midnightXPositions(size: CGSize) -> [CGFloat] {
        let cal = Calendar.inTimeZone(portTimeZone)
        var positions: [CGFloat] = []
        let endDate = startDate.addingTimeInterval(totalDuration)
        var midnight = cal.startOfDay(for: startDate)
        if midnight <= startDate {
            midnight = cal.date(byAdding: .day, value: 1, to: midnight) ?? midnight
        }
        while midnight < endDate {
            let x = CGFloat(midnight.timeIntervalSince(startDate) / totalDuration) * size.width
            positions.append(x)
            midnight = cal.date(byAdding: .day, value: 1, to: midnight) ?? endDate
        }
        return positions
    }

    // MARK: - Solar Arc
    /// Draws an inverted parabolic arc from sunrise to sunset, with the apex at solar noon.
    /// The arc represents the sun's path: high at noon, touching the horizon at sunrise/sunset.
    private func drawSolarArc(context: inout GraphicsContext, size: CGSize, topMargin: CGFloat, drawHeight: CGFloat,
                              sunrise: Date, sunset: Date, apexY: CGFloat? = nil, baseY: CGFloat? = nil) {
        let sunriseX = xPosition(for: sunrise)
        let sunsetX = xPosition(for: sunset)
        guard sunsetX > sunriseX else { return }

        // Apex/base par défaut (mode marée). En mode vent, on les passe au niveau de la marée
        // aplatie pour que l'arc solaire reste « au niveau de la courbe de marée ».
        let arcApexY = apexY ?? (topMargin + drawHeight * 0.08)
        let arcBaseY = baseY ?? (topMargin + drawHeight * 0.75)
        let arcWidth = sunsetX - sunriseX

        // Build the arc path
        var arcPath = Path()
        let steps = max(Int(arcWidth / 3), 20)

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = sunriseX + t * arcWidth
            // Parabolic: y = base - (apex-base) * 4t(1-t)
            let y = arcBaseY - (arcBaseY - arcApexY) * 4 * t * (1 - t)

            if i == 0 {
                arcPath.move(to: CGPoint(x: x, y: y))
            } else {
                arcPath.addLine(to: CGPoint(x: x, y: y))
            }
        }

        // Fill under the arc (soft daylight zone)
        var arcFill = arcPath
        arcFill.addLine(to: CGPoint(x: sunsetX, y: arcBaseY + 10))
        arcFill.addLine(to: CGPoint(x: sunriseX, y: arcBaseY + 10))
        arcFill.closeSubpath()

        context.fill(arcFill, with: .linearGradient(
            Gradient(colors: [
                Color.yellow.opacity(0.06),
                Color.orange.opacity(0.03),
                Color.clear
            ]),
            startPoint: CGPoint(x: (sunriseX + sunsetX) / 2, y: arcApexY),
            endPoint: CGPoint(x: (sunriseX + sunsetX) / 2, y: arcBaseY + 10)
        ))

        // Stroke the arc
        context.stroke(arcPath, with: .linearGradient(
            Gradient(colors: [
                Color.orange.opacity(0.0),
                Color.yellow.opacity(0.25),
                Color.orange.opacity(0.3),
                Color.yellow.opacity(0.25),
                Color.orange.opacity(0.0)
            ]),
            startPoint: CGPoint(x: sunriseX, y: arcBaseY),
            endPoint: CGPoint(x: sunsetX, y: arcBaseY)
        ), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        // Sunrise dot + label
        let sunriseIconY = arcBaseY - 2
        let sunIcon = Path(ellipseIn: CGRect(x: sunriseX - 4, y: sunriseIconY - 4, width: 8, height: 8))
        context.fill(sunIcon, with: .color(Color.orange.opacity(0.5)))

        let sunriseFormatted = CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: sunrise)

        let sunriseText = context.resolve(
            Text("☀︎ " + sunriseFormatted)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.7))
        )
        context.draw(sunriseText, at: CGPoint(x: sunriseX + 10, y: sunriseIconY + 1), anchor: .leading)

        // Sunset dot + label
        let sunsetIconY = arcBaseY - 2
        let sunsetIcon = Path(ellipseIn: CGRect(x: sunsetX - 4, y: sunsetIconY - 4, width: 8, height: 8))
        context.fill(sunsetIcon, with: .color(Color.orange.opacity(0.5)))

        let sunsetFormatted = CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: sunset)

        let sunsetText = context.resolve(
            Text(sunsetFormatted + " ☾")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.7))
        )
        context.draw(sunsetText, at: CGPoint(x: sunsetX - 10, y: sunsetIconY + 1), anchor: .trailing)

        // Sun position on the arc at current time
        let now = currentTime
        if now >= sunrise && now <= sunset {
            let t = CGFloat(now.timeIntervalSince(sunrise) / sunset.timeIntervalSince(sunrise))
            let sunX = sunriseX + t * arcWidth
            let sunY = arcBaseY - (arcBaseY - arcApexY) * 4 * t * (1 - t)

            // Glow
            let glowRect = CGRect(x: sunX - 10, y: sunY - 10, width: 20, height: 20)
            context.fill(Circle().path(in: glowRect), with: .radialGradient(
                Gradient(colors: [Color.yellow.opacity(0.25), Color.clear]),
                center: CGPoint(x: sunX, y: sunY),
                startRadius: 0,
                endRadius: 12
            ))

            // Sun dot
            let dotRect = CGRect(x: sunX - 4, y: sunY - 4, width: 8, height: 8)
            context.fill(Circle().path(in: dotRect), with: .color(Color.yellow.opacity(0.9)))
        }
    }

    // MARK: - Tide Points Overlay (utilise TideMetrics pour éviter le re-tri)
    private func tidePointsOverlay(in size: CGSize) -> some View {
        let metrics = (cachedTideMetrics ?? TideMetrics(tideData: tideData))

        let topMargin: CGFloat = size.height * topMarginRatio
        let bottomMargin: CGFloat = size.height * bottomMarginRatio
        let drawHeight = size.height - topMargin - bottomMargin

        let endDate = startDate.addingTimeInterval(totalDuration)
        let visibleTides = (metrics?.sorted ?? []).filter { $0.date >= startDate && $0.date <= endDate }
        let adjMin = metrics?.adjustedMin ?? 0
        let hSpan = metrics?.span ?? 1

        return ZStack {
            ForEach(visibleTides) { tide in
                let x = xPosition(for: tide.date)
                let normalizedHeight = (tide.height - adjMin) / hSpan
                let y0 = topMargin + drawHeight * (1 - CGFloat(normalizedHeight))
                // En mode vent/surf la courbe de marée est aplatie : les points/labels suivent.
                let y = curveFlattened ? Self.flattenedTideY(y0, topMargin: topMargin, drawHeight: drawHeight) : y0

                TidePointWithLabel(tide: tide, portTimeZone: portTimeZone, compact: curveFlattened)
                    .position(x: x, y: y)
            }
        }
    }
}


/// Fenêtre GO « aplatie » (tous sports) passée à la courbe — issue du MÊME `ActivityGoPlanner.plan`
/// que le calendrier. Equatable (WindSport l'est) → rebuild propre.
struct GoCurveWindow: Equatable {
    let start: Date
    let end: Date
    let sport: WindSport
    /// Note de qualité de la session 1–5 (★) sur PRÉVISION — UNIQUEMENT en AUTO (sinon nil → pas d'étoiles).
    var stars: Int? = nil
    /// Note RÉINTERPRÉTÉE le jour J avec les relevés réels (balise + bouée). nil hors horizon imminent
    /// ou sans relevé → on retombe sur `stars` (prévision). Affichée seulement près de la fenêtre.
    var refinedStars: Int? = nil
    /// Provenance de la houle qui a affiné (`.buoyAnchored` si une bouée fraîche a nourri la fenêtre).
    var provenance: MarineProvenance? = nil
    /// LA meilleure fenêtre à venir (plus d'étoiles, puis la plus proche) → couronnée sur la courbe.
    var isPeak: Bool = false
}

//
//  ContentView.swift
//  Tide Watch Watch App
//
//  App Apple Watch — Affichage des marées en temps réel
//

import SwiftUI
import Combine

// MARK: - Watch Design System

private enum WDS {
    // Colors
    static let text1    = Color.white
    static let text2    = Color.white.opacity(0.7)
    static let text3    = Color.white.opacity(0.4)
    static let high     = Color.cyan
    static let low      = Color.purple
    static let mid      = Color.blue

    /// Fond bleu nuit (inspiré des apps marée de référence) — dégradé vertical profond.
    static let nightBackground = LinearGradient(
        colors: [
            Color(red: 0.03, green: 0.06, blue: 0.18),
            Color(red: 0.04, green: 0.10, blue: 0.24),
            Color(red: 0.02, green: 0.05, blue: 0.14)
        ],
        startPoint: .top, endPoint: .bottom
    )

    // Spacing
    static let spacingSM: CGFloat = 4
    static let spacingMD: CGFloat = 8
}

// MARK: - Helpers

private let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private func tideColor(isHigh: Bool) -> Color {
    isHigh ? WDS.high : WDS.low
}

private func coeffColor(_ coef: Int) -> Color {
    switch coef {
    case ..<45:   return .green
    case 45..<70: return .yellow
    case 70..<95: return .orange
    default:      return .red
    }
}

private func bestCoef(from data: WidgetSharedData) -> Int? {
    data.todayCoef ?? data.nextTideCoef ?? data.secondTideCoef
}

private func interpolatedHeight(from data: WidgetSharedData, at date: Date) -> Double {
    guard let prevDate = data.previousTideDate,
          let prevHeight = data.previousTideHeight else {
        return data.currentHeight
    }
    let totalDuration = data.nextTideDate.timeIntervalSince(prevDate)
    guard totalDuration > 0 else { return data.currentHeight }
    let elapsed = date.timeIntervalSince(prevDate)
    let fraction = min(max(elapsed / totalDuration, 0), 1)
    let cosineProgress = (1 - cos(fraction * .pi)) / 2
    return prevHeight + (data.nextTideHeight - prevHeight) * cosineProgress
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var dataManager = WatchDataManager.shared
    @State private var currentTime = Date()

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let rawData = dataManager.tideData {
                // Résolution autonome depuis allTides (gère overnight)
                let main = resolvedSharedData(from: rawData, at: currentTime)
                let favs = dataManager.favorites.map { resolvedSharedData(from: $0, at: currentTime) }
                if favs.isEmpty {
                    TideMainView(data: main, currentTime: currentTime, showDirectWind: true)
                } else {
                    // Carrousel Digital Crown : port principal (vent direct possible) puis favoris.
                    TabView {
                        TideMainView(data: main, currentTime: currentTime, showDirectWind: true)
                        ForEach(Array(favs.enumerated()), id: \.offset) { _, fav in
                            TideMainView(data: fav, currentTime: currentTime)
                        }
                    }
                    .tabViewStyle(.verticalPage)
                }
            } else {
                WatchEmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WDS.nightBackground.ignoresSafeArea())
        .onReceive(timer) { _ in
            currentTime = Date()
            refreshDirectWind()
        }
        .task(id: dataManager.tideData?.portName) { refreshDirectWind() }
    }

    /// Fetch DIRECT de la balise (sans tel) pour le port actif — premium seulement, et seulement
    /// si la position est connue. Le service est throttlé + défensif (échec = vent du tel conservé).
    private func refreshDirectWind() {
        guard let d = dataManager.tideData, d.realtimeWindLocked != true,
              let lat = d.latitude, let lon = d.longitude else { return }
        Task { await WatchWindService.shared.refresh(lat: lat, lon: lon) }
    }
}

// MARK: - Main Tide View

private struct TideMainView: View {
    let data: WidgetSharedData
    let currentTime: Date
    /// Port actif → autorise le fetch vent DIRECT (balise Watch, sans tel). Faux pour les favoris.
    var showDirectWind: Bool = false
    @State private var showCredits = false
    @ObservedObject private var directWind = WatchWindService.shared

    private var liveHeight: Double {
        interpolatedHeight(from: data, at: currentTime)
    }
    private var isRising: Bool { data.nextTideIsHigh }
    private var trendColor: Color { isRising ? WDS.high : WDS.low }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: WDS.spacingSM) {
                    heroBlock          // courbe remontée + infos dé-cadrées (tout au-dessus du pli)
                    nextTideRow
                    secondTideRow
                    sunRow
                    updatedFooter
                    creditsButton
                }
                .padding(.horizontal, WDS.spacingMD)
                .padding(.bottom, 20)
            }
            .defaultScrollAnchor(.top)   // au lancement : courbe en HAUT (pas besoin de scroller)
            // Nom du port DANS la barre système, en haut à gauche (face à l'heure) :
            // zéro ligne de contenu gaspillée, la courbe remonte d'autant.
            .navigationTitle(data.portName)
            .sheet(isPresented: $showCredits) { WatchCreditsView() }
        }
    }

    /// Accès discret aux crédits/sources (attribution CC-BY obligatoire pour Pioupiou).
    private var creditsButton: some View {
        Button { showCredits = true } label: {
            Text("Sources des donn\u{00e9}es")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(WDS.text3)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: Wave Hero — la courbe en GRAND, badges aux coins (inspiré des meilleures apps marée)

    /// La courbe est le héros plein écran. Coins discrets : coef (haut-droite), compte à
    /// rebours (bas-gauche), vent (bas-droite). Pas de gros chiffre qui gaspille le haut —
    /// la hauteur va dans la pastille basse (`liveInfoPill`).
    /// Bloc héros COMPACT : courbe bord à bord en haut, remplissage qui descend et se FOND
    /// à transparent en bas (jamais d'arrêt net), infos dé-cadrées ancrées en bas — le tout
    /// sur une grille stricte (même bord gauche que le header, aucun espace mort).
    private var heroBlock: some View {
        ZStack(alignment: .bottom) {
            Canvas { ctx, size in drawTideCurve(context: &ctx, size: size) }
                .padding(.horizontal, -WDS.spacingMD)   // bord à bord

            VStack(alignment: .leading, spacing: 4) {
                // Stat principale + COEF à droite (rangé avec les stats, plus de flottement).
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: isRising ? "arrow.up" : "arrow.down")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(trendColor)
                    Text(SharedUnitFormatter.height(liveHeight))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(WDS.text1)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(isRising ? "Montante" : "Descendante")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(trendColor)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    coefPill
                }
                // Compte à rebours + vent : visibles d'un coup d'œil, même grille.
                HStack(spacing: 0) {
                    countdownChip
                    Spacer(minLength: 8)
                    windPill
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 168)
    }

    /// Pastille coefficient (haut-droite du héros).
    @ViewBuilder
    private var coefPill: some View {
        if let coef = bestCoef(from: data) {
            VStack(spacing: -2) {
                Text("\(coef)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(coeffColor(coef))
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("COEF")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(WDS.text3).tracking(0.5)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(coeffColor(coef).opacity(0.16)))
            .overlay(Capsule().stroke(coeffColor(coef).opacity(0.35), lineWidth: 0.5))
        }
    }

    /// Compte à rebours vers la prochaine marée (bas-gauche du héros).
    private var countdownChip: some View {
        HStack(spacing: 3) {
            Image(systemName: data.nextTideIsHigh ? "arrow.up" : "arrow.down")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(tideColor(isHigh: data.nextTideIsHigh))
            Text(data.nextTideIsHigh ? "PM" : "BM")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(tideColor(isHigh: data.nextTideIsHigh))
            // Rendu natif par le système : défile à la seconde sans re-render → fluide.
            if data.nextTideDate > currentTime {
                Text(timerInterval: currentTime...data.nextTideDate, countsDown: true)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(WDS.text1)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: 58)
            } else {
                Text("maintenant")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(WDS.text1)
            }
        }
    }

    /// Vent effectif à afficher : balise DIRECTE (fetchée sur la Watch, port actif) si plus fraîche
    /// que celle du tel — sinon vent fourni par le tel (comportement existant). nil = rien à montrer.
    private struct EffWind { let speed: Double; let dir: Double; let station: String?; let date: Date? }

    private var effectiveWind: EffWind? {
        let now = Date()
        // 1) Balise DIRECTE (sans tel) — uniquement pour le port actif, et si < 90 min.
        if showDirectWind, let s = directWind.speedKmh, let dir = directWind.directionDeg,
           let d = directWind.date, now.timeIntervalSince(d) <= 90 * 60,
           d > (data.observedWindDate ?? .distantPast) {   // préférée si plus fraîche que le tel
            return EffWind(speed: s, dir: dir, station: directWind.stationName, date: d)
        }
        // 2) Vent fourni par le tel (gate 90 min existant).
        if let speed = data.observedWindKmh, let dir = data.observedWindDirDeg,
           data.observedWindDate.map({ data.updatedAt.timeIntervalSince($0) <= 90 * 60 }) ?? true,
           speed > 0 || (data.observedWindStation?.isEmpty == false) {
            return EffWind(speed: speed, dir: dir, station: data.observedWindStation, date: data.observedWindDate)
        }
        return nil
    }

    /// Vent observé temps réel (dé-cadré), si une balise (directe ou via tel) est disponible.
    @ViewBuilder
    private var windPill: some View {
        if let w = effectiveWind {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.teal)
                        .rotationEffect(.degrees(w.dir + 180))
                    Text(SharedUnitFormatter.windSpeed(w.speed))
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(WDS.text1)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(SharedUnitFormatter.windCardinal(w.dir))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.teal)
                }
                if let label = windSourceLabel(w) {
                    Text(label)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(WDS.text3)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
        }
    }

    /// « Station · il y a X min » — provenance et fraîcheur de la balise vent affichée.
    private func windSourceLabel(_ w: EffWind) -> String? {
        let station = (w.station?.isEmpty == false) ? w.station : nil
        let age: String? = w.date.map { d in
            let mins = max(0, Int(Date().timeIntervalSince(d) / 60))
            return mins == 0 ? "à l'instant" : "il y a \(mins) min"
        }
        switch (station, age) {
        case let (s?, a?): return "\(s) · \(a)"
        case let (s?, nil): return s
        case let (nil, a?): return "balise · \(a)"
        default: return nil
        }
    }

    // MARK: Next Tide Row

    private var nextTideRow: some View {
        WatchTideRow(
            label: "PROCHAINE",
            date: data.nextTideDate,
            height: data.nextTideHeight,
            isHigh: data.nextTideIsHigh,
            coef: data.nextTideCoef,
            timeZone: data.timeZone
        )
    }

    // MARK: Second Tide Row

    @ViewBuilder
    private var secondTideRow: some View {
        if let d = data.secondTideDate,
           let h = data.secondTideHeight,
           let high = data.secondTideIsHigh {
            WatchTideRow(
                label: "SUIVANTE",
                date: d,
                height: h,
                isHigh: high,
                coef: data.secondTideCoef,
                timeZone: data.timeZone
            )
        }
    }

    // MARK: Tide Curve (rendu de la vague — fond du héros « niveau d'eau »)

    private func drawTideCurve(context: inout GraphicsContext, size: CGSize) {
        // Utiliser allTides si disponible (±3 marées autour de now)
        var anchors: [(date: Date, height: Double, isHigh: Bool)] = []

        if !data.allTides.isEmpty {
            // allTides déjà trié par date — pas de re-sort
            let nowTs = currentTime.timeIntervalSince1970
            // Index de la première marée future (recherche binaire)
            var lo = 0, hi = data.allTides.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if data.allTides[mid].date.timeIntervalSince1970 <= nowTs { lo = mid + 1 } else { hi = mid }
            }
            let futureIdx = lo
            // Fenêtre RESSERRÉE (≈1,5 cycle) centrée sur « maintenant » → courbe lisible,
            // on voit d'un coup d'œil où on en est (moins de fréquence que le jour entier).
            let startIdx = max(0, futureIdx - 2)
            let endIdx = min(data.allTides.count, futureIdx + 2)
            for i in startIdx..<endIdx {
                let t = data.allTides[i]
                anchors.append((t.date, t.height, t.isHigh))
            }
        } else {
            // Fallback legacy : previous, next, second
            if let pDate = data.previousTideDate, let pH = data.previousTideHeight {
                anchors.append((pDate, pH, !data.nextTideIsHigh))
            }
            anchors.append((data.nextTideDate, data.nextTideHeight, data.nextTideIsHigh))
            if let sDate = data.secondTideDate, let sH = data.secondTideHeight, let sHigh = data.secondTideIsHigh {
                anchors.append((sDate, sH, sHigh))
            }
        }

        guard anchors.count >= 2 else { return }

        // Pré-calculer les timestamps (évite les appels répétés à timeIntervalSince1970)
        let anchorTimes = anchors.map { $0.date.timeIntervalSince1970 }
        guard let minTime = anchorTimes.first, let maxTime = anchorTimes.last else { return }

        let timeRange = maxTime - minTime
        guard timeRange > 0 else { return }

        var minH = Double.infinity, maxH = -Double.infinity
        for a in anchors { if a.height < minH { minH = a.height }; if a.height > maxH { maxH = a.height } }
        // Marge de hauteur GÉNÉREUSE → amplitude DOUCE (la vague n'occupe pas tout l'écran).
        let span = max(maxH - minH, 0.5)
        minH -= span * 0.5; maxH += span * 0.5
        let hRange = maxH - minH
        guard hRange > 0 else { return }

        // Bande : crête près du HAUT (pas de place perdue), creux à mi-hauteur → bas libre
        // pour les badges (coef / compte à rebours / vent).
        let pad: CGFloat = 0          // BORD À BORD : la courbe touche les bords de l'écran.
        let topMargin: CGFloat = 14
        // Courbe dans les ~60 % hauts ; le remplissage descend derrière les infos ancrées
        // en bas du bloc (pas d'espace mort entre les deux).
        let bottomMargin: CGFloat = size.height * 0.42
        let drawW = size.width - pad * 2
        let drawH = max(size.height - topMargin - bottomMargin, 1)

        // Generate curve points with cosine interpolation (curseur séquentiel O(n))
        func mapPoint(time: Double, height: Double) -> CGPoint {
            let x = pad + CGFloat((time - minTime) / timeRange) * drawW
            let y = topMargin + CGFloat(1 - (height - minH) / hRange) * drawH
            return CGPoint(x: x, y: y)
        }

        var curvePoints: [CGPoint] = []
        let steps = Int(drawW)
        var segIdx = 0 // Curseur séquentiel (avance toujours → O(n) au lieu de O(n²))

        for step in 0...steps {
            let t = minTime + (Double(step) / Double(steps)) * timeRange
            // Avancer le curseur séquentiellement
            while segIdx < anchors.count - 2 && anchorTimes[segIdx + 1] <= t {
                segIdx += 1
            }
            let segDur = anchorTimes[min(segIdx + 1, anchors.count - 1)] - anchorTimes[segIdx]
            let frac: Double = segDur > 0 ? min(max((t - anchorTimes[segIdx]) / segDur, 0), 1) : 0
            let cosP = (1 - cos(frac * .pi)) / 2
            let h = anchors[segIdx].height + (anchors[min(segIdx + 1, anchors.count - 1)].height - anchors[segIdx].height) * cosP
            curvePoints.append(mapPoint(time: t, height: h))
        }

        guard let firstCPt = curvePoints.first, let lastCPt = curvePoints.last else { return }

        // Fill gradient under curve
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: firstCPt.x, y: size.height))
        for pt in curvePoints { fillPath.addLine(to: pt) }
        fillPath.addLine(to: CGPoint(x: lastCPt.x, y: size.height))
        fillPath.closeSubpath()

        // Remplissage qui DESCEND sous la courbe jusqu'en bas du bloc, puis se FOND à
        // transparent : il se mélange au fond bleu nuit, AUCUN arrêt net possible.
        context.fill(
            fillPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.cyan.opacity(0.36), location: 0.0),
                    .init(color: Color.blue.opacity(0.22), location: 0.35),
                    .init(color: Color.purple.opacity(0.13), location: 0.68),
                    .init(color: Color.purple.opacity(0.0), location: 1.0)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: topMargin),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )

        // Stroke curve
        var strokePath = Path()
        strokePath.move(to: curvePoints.first!)
        for pt in curvePoints.dropFirst() { strokePath.addLine(to: pt) }

        // Glow doux sous le trait.
        var glowCtx = context
        glowCtx.addFilter(.blur(radius: 5))
        glowCtx.opacity = 0.45
        glowCtx.stroke(strokePath, with: .color(.cyan),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

        // 2 COULEURS de part et d'autre de « maintenant » : passé = cyan · futur = violet.
        let nowTs = currentTime.timeIntervalSince1970
        let nowXsplit: CGFloat = (nowTs >= minTime && nowTs <= maxTime)
            ? CGFloat((nowTs - minTime) / timeRange) * drawW + pad
            : -1
        let lineStyle = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        if nowXsplit >= 0 {
            var past = context
            past.clip(to: Path(CGRect(x: 0, y: 0, width: nowXsplit, height: size.height)))
            past.stroke(strokePath, with: .color(WDS.high), style: lineStyle)
            var future = context
            future.clip(to: Path(CGRect(x: nowXsplit, y: 0, width: size.width - nowXsplit, height: size.height)))
            future.stroke(strokePath, with: .color(WDS.low), style: lineStyle)
        } else {
            context.stroke(strokePath, with: .color(WDS.high), style: lineStyle)
        }

        // Tide point dots + étiquette d'heure (esprit des apps marée de référence).
        let labelFmt = DateFormatter()
        labelFmt.timeZone = data.timeZone
        labelFmt.dateFormat = "HH:mm"
        for (i, anchor) in anchors.enumerated() {
            let pt = mapPoint(time: anchorTimes[i], height: anchor.height)
            let dotColor = anchor.isHigh ? Color.cyan : Color.purple
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)),
                with: .color(dotColor)
            )
            // Heure : au-dessus des PM, en dessous des BM ; x borné pour ne pas couper.
            let label = Text(labelFmt.string(from: anchor.date))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
            let ly = anchor.isHigh ? pt.y - 11 : pt.y + 11
            let lx = min(max(pt.x, 20), size.width - 20)
            context.draw(label, at: CGPoint(x: lx, y: ly), anchor: .center)
        }

        // Point « maintenant » — MÊME rendu que l'app iOS (TrackingDotView) :
        // halo cyan 24 + anneau cyan 16 + cœur blanc lumineux.
        if nowTs >= minTime && nowTs <= maxTime {
            let nowPt = mapPoint(time: nowTs, height: liveHeight)
            context.fill(Path(ellipseIn: CGRect(x: nowPt.x - 12, y: nowPt.y - 12, width: 24, height: 24)),
                         with: .color(Color.cyan.opacity(0.15)))
            context.stroke(Path(ellipseIn: CGRect(x: nowPt.x - 8, y: nowPt.y - 8, width: 16, height: 16)),
                           with: .color(Color.cyan.opacity(0.4)), lineWidth: 1.5)
            var dotGlow = context
            dotGlow.addFilter(.blur(radius: 4))
            dotGlow.fill(Path(ellipseIn: CGRect(x: nowPt.x - 5, y: nowPt.y - 5, width: 10, height: 10)),
                         with: .color(.cyan))
            context.fill(Path(ellipseIn: CGRect(x: nowPt.x - 4, y: nowPt.y - 4, width: 8, height: 8)),
                         with: .color(.white))
        }
    }

    // MARK: Footer

    private var updatedFooter: some View {
        Text("Mis \u{00e0} jour \(timeFmt.string(from: data.updatedAt))")
            .font(.system(size: 9))
            .foregroundStyle(WDS.text3)
            .frame(maxWidth: .infinity)
            .padding(.top, WDS.spacingSM)
    }

    // MARK: Lever / coucher du soleil

    @ViewBuilder
    private var sunRow: some View {
        if let sunrise = data.sunrise, let sunset = data.sunset {
            HStack(spacing: 0) {
                sunCell(icon: "sunrise.fill", time: sunrise, tint: WDS.high)
                Spacer(minLength: 0)
                sunCell(icon: "sunset.fill", time: sunset, tint: WDS.low)
            }
            .padding(.horizontal, 4)
        }
    }

    private func sunCell(icon: String, time: Date, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(formatTideTime(time, in: data.timeZone))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(WDS.text2)
        }
    }
}

// MARK: - Watch Tide Row

private struct WatchTideRow: View {
    let label: String
    let date: Date
    let height: Double
    let isHigh: Bool
    let coef: Int?
    var timeZone: TimeZone = .current

    private var accent: Color { isHigh ? WDS.high : WDS.low }

    var body: some View {
        VStack(alignment: .leading, spacing: WDS.spacingSM) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(WDS.text3)
                .tracking(0.5)

            HStack(spacing: 4) {
                Image(systemName: isHigh ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(accent)
                Text(isHigh ? "PM" : "BM")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(accent)

                Spacer(minLength: 0)

                Text(formatTideTime(date, in: timeZone))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(WDS.text1)

                Text(SharedUnitFormatter.height(height))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WDS.text2)

                if let c = coef {
                    Text("\(c)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(coeffColor(c))
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        // Dé-cadré : ligne ouverte sur le fond bleu nuit, séparée par un fin filet.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 2)
        }
    }
}

// MARK: - Empty State

private struct WatchEmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.cyan.opacity(0.15), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 35
                        )
                    )
                    .frame(width: 70, height: 70)

                Image(systemName: "water.waves")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [WDS.high.opacity(0.7), WDS.low.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("Premi\u{00e8}re synchro")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(WDS.text2)

            Text("Ouvre Tide It sur ton iPhone\nune fois pour charger tes spots.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(WDS.text3)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Previews

private let previewData: WidgetSharedData = {
    let prevDate = Date().addingTimeInterval(-2 * 3600)
    let nextDate = Date().addingTimeInterval(4 * 3600 + 31 * 60)
    let secondDate = Date().addingTimeInterval(10 * 3600 + 45 * 60)
    let tides = [
        SimpleTide(date: prevDate, height: 0.45, isHigh: false, coefficient: nil),
        SimpleTide(date: nextDate, height: 3.50, isHigh: true, coefficient: 52),
        SimpleTide(date: secondDate, height: 0.82, isHigh: false, coefficient: 48),
    ]
    return WidgetSharedData(
        portName: "Arcachon Eyrac",
        nextTideDate: nextDate,
        nextTideHeight: 3.50,
        nextTideIsHigh: true,
        nextTideCoef: 52,
        currentHeight: 1.72,
        trend: "Montante",
        updatedAt: Date(),
        todayCoef: 52,
        previousTideDate: prevDate,
        previousTideHeight: 0.45,
        secondTideDate: secondDate,
        secondTideHeight: 0.82,
        secondTideIsHigh: false,
        secondTideCoef: 48,
        allTides: tides
    )
}()

// MARK: - Crédits / sources des données (attribution CC-BY — Pioupiou notamment)

private struct WatchCreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources des donn\u{00e9}es")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(WDS.text1)
                Text("Mar\u{00e9}es : SHOM, NOAA.")
                    .font(.system(size: 11)).foregroundStyle(WDS.text2)
                Text("Vent observ\u{00e9} : Pioupiou (CC-BY 4.0), winds.mobi, NDBC, METAR / NOAA.")
                    .font(.system(size: 11)).foregroundStyle(WDS.text2)
                Text("Pr\u{00e9}visions : Open-Meteo.")
                    .font(.system(size: 11)).foregroundStyle(WDS.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

#Preview("Tide Watch") {
    ContentView()
}

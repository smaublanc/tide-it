//
//  TideParticleField.swift
//  Tide It
//
//  Champ de particules ambiant qui monte/descend selon le sens de la marée.
//  Rendu LÉGER : un seul Canvas piloté par TimelineView(.animation) dessine ~130
//  particules réparties sur 4 plans de profondeur (pas de vues SwiftUI par
//  particule). Parallaxe gyroscopique optionnelle via CoreMotion, lue sans
//  déclencher de re-render SwiftUI. Activable/désactivable dans les Réglages.
//  Respecte « Réduire les animations » (accessibilité) : champ figé + gyro coupé.
//

import SwiftUI
import CoreMotion
import UIKit   // UIColor : décomposition RGB pour teinter la crête de houle (Crest Cadence)

// MARK: - Générateur pseudo-aléatoire déterministe (layout stable)

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Inclinaison gyroscopique (parallaxe), lissée, lue par le Canvas

final class TiltMotionManager {
    static let shared = TiltMotionManager()
    private let manager = CMMotionManager()
    /// Inclinaison lissée ~[-1, 1]. Propriété simple (pas @Published) : le Canvas
    /// la lit à chaque frame, sans invalider la vue.
    private(set) var tilt: CGSize = .zero
    private var clients = 0

    private init() {}

    func start() {
        clients += 1
        guard clients == 1,
              manager.isDeviceMotionAvailable,
              !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let tx = CGFloat(max(-1, min(1, m.attitude.roll / 0.8)))
            let ty = CGFloat(max(-1, min(1, m.attitude.pitch / 0.8)))
            // Passe-bas pour un mouvement doux
            self.tilt.width  += (tx - self.tilt.width)  * 0.10
            self.tilt.height += (ty - self.tilt.height) * 0.10
        }
    }

    func stop() {
        clients = max(0, clients - 1)
        if clients == 0 {
            manager.stopDeviceMotionUpdates()
            tilt = .zero
        }
    }
}

// MARK: - Bus de flux horizontal (scroll de la courbe → parallaxe « fluide épais »)

/// La courbe de marée écrit son offset de scroll ici ; le Canvas des particules
/// le lit chaque frame et applique un décalage amorti par plan (effet fluide).
/// Pas de @Published → aucune invalidation SwiftUI parasite.
/// Pilote du « front de houle » du mode SURF (Crest Cadence) — écrit par la courbe (throttle
/// minute), lu en direct par le Canvas. nil hors surf ⇒ champ identique à la marée seule.
struct SwellDrive: Equatable {
    var period: Double       // s → cadence du balayage du front
    var punch: Double        // 0…1 (énergie × exposition) → contraste + regroupement à la crête
    var bearingDeg: Double?  // provenance de la houle (deg) → cap du balayage
    var exposure: Double     // 0…1
    var trend: SwellTrend
}

final class ParticleFlowBus {
    static let shared = ParticleFlowBus()
    var scrollX: CGFloat = 0       // offset courant de la courbe (écrit par la courbe)
    var prevScrollX: CGFloat = 0   // valeur de la frame précédente
    var velocity: CGFloat = 0      // vitesse latérale (modèle fluide)
    var offset: CGFloat = 0        // décalage latéral PERSISTANT (s'accumule, ne recentre pas)
    var verticalFlow: CGFloat = 0  // dérive verticale intégrée (continue → pas de saut à l'étale)
    var lastTick: Date?
    /// Mode vent : couleur de la force du vent au CENTRE de la courbe, écrite par le scroll.
    /// Objet simple (pas de @Published) → lue en direct par le Canvas à chaque frame, SANS
    /// réévaluer la vue → suit le défilement sans aucun lag. `nil` hors mode vent.
    var windTint: Color?
    /// Mode SURF (Crest Cadence) : un FRONT de houle quasi-vertical balaie le champ latéralement.
    /// Lu en direct par le Canvas (comme `windTint`), n'altère JAMAIS le sens vertical (marée).
    var swell: SwellDrive?
    var crestPhase: CGFloat = 0      // position de la bande ∈ [0,1[ (décroît : balayage droite→gauche)
    var punchSmoothed: CGFloat = 0   // amplitude lissée (glisse à l'arrivée d'un set / changement de spot)
    /// Dernière date « centre de courbe » notifiée à TodayView (throttle d'en-tête).
    var lastReportedDate: Date?
    private init() {}
}

/// Composantes RGB d'une Color (0…1). Une seule conversion UIColor par appel — utilisé 2×/frame
/// (teinte de base + orange de crête), pas par particule.
private func rgbComponents(_ c: Color) -> (r: Double, g: Double, b: Double) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Double(r), Double(g), Double(b))
}

// MARK: - Particule

private struct Particle {
    let x: CGFloat          // 0...1
    let baseY: CGFloat      // 0...1
    let size: CGFloat       // rayon du halo (pt)
    let plane: Int          // 0 = loin, 1 = milieu, 2 = proche, 3 = premier plan fin
    let speed: CGFloat      // unités normalisées / s
    let swayAmp: CGFloat    // amplitude oscillation horizontale (0...1)
    let swayFreq: CGFloat
    let phase: CGFloat
    let twinkleAmp: CGFloat // profondeur du scintillement (0...1)
    let twinkleFreq: CGFloat
    let twinklePhase: CGFloat
}

// MARK: - Champ de particules

struct TideParticleField: View, Equatable {
    /// +1 montante (vers le haut), -1 descendante (vers le bas), ~0 étale.
    let direction: Double
    /// Couleur d'accent (cyan montante / violet descendante).
    let tint: Color
    /// Parallaxe gyroscopique.
    var gyro: Bool = true

    /// Ne dépend que de direction/teinte/gyro : SwiftUI saute le re-render quand
    /// TodayView se rafraîchit (scrub de la courbe) tant que la marée ne change pas.
    /// L'animation des particules est pilotée en interne par TimelineView.
    static func == (lhs: TideParticleField, rhs: TideParticleField) -> Bool {
        lhs.direction == rhs.direction && lhs.tint == rhs.tint && lhs.gyro == rhs.gyro
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particles: [Particle] = TideParticleField.makePool()
    @State private var start = Date()

    // Réglages par plan : loin → milieu → proche → premier plan fin
    private let gyroParallax: [CGFloat] = [7, 16, 30, 52]   // px par unité d'inclinaison
    private let flowParallax: [CGFloat] = [0.05, 0.12, 0.22, 0.38] // réponse au swipe (réduite)
    // loin (très discret) → milieu → proche → premier plan fin (très lumineux)
    private let baseAlpha:   [Double]  = [0.035, 0.075, 0.13, 0.55]

    var body: some View {
        // « Réduire les animations » → on fige le rendu (paused) et on coupe le gyro :
        // le champ reste visible en version statique, sans mouvement ni CoreMotion.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: scenePhase != .active || reduceMotion)) { timeline in
            Canvas { ctx, size in
                guard size.width > 1, size.height > 1 else { return }   // évite tout %0 / NaN si layout 0×0
                let now = timeline.date
                let t = now.timeIntervalSince(start)
                let tilt = (gyro && !reduceMotion) ? TiltMotionManager.shared.tilt : .zero

                // Modèle « fluide » : le swipe de la courbe imprime une vitesse latérale,
                // freinée par la viscosité. L'offset s'ACCUMULE (pas de recentrage) et les
                // particules s'enroulent horizontalement → déplacement latéral persistant.
                let bus = ParticleFlowBus.shared
                let dtRaw = bus.lastTick.map { now.timeIntervalSince($0) } ?? (1.0 / 30.0)
                let dt = CGFloat(min(max(dtRaw, 0), 0.1))
                bus.lastTick = now

                let delta = max(-70, min(70, bus.scrollX - bus.prevScrollX))
                bus.prevScrollX = bus.scrollX
                bus.velocity = (bus.velocity - delta * 0.5) * 0.5       // impulsion douce + frein visqueux
                bus.velocity = max(-300, min(300, bus.velocity))
                bus.offset += bus.velocity                              // intégration (persistant)
                bus.offset = max(-1_000_000, min(1_000_000, bus.offset)) // borne de sécurité (pas de croissance illimitée)

                // Dérive verticale INTÉGRÉE : un changement de sens (étale) n'affecte que
                // la suite, sans saut rétroactif. Vitesse instantanée = direction × p.speed.
                bus.verticalFlow += CGFloat(direction) * dt
                let vFlow = bus.verticalFlow
                let w = size.width

                // Mode vent : couleur de la force du vent au centre de la courbe (lue en
                // direct sur le bus, sans re-render → suit le scroll sans lag).
                let drawTint = bus.windTint ?? tint

                // — Mode SURF : BANDE de houle. Une bande verticale INVISIBLE balaie le champ de
                // DROITE à GAUCHE et fait GROSSIR (+ éclaircit, + teinte orange) les particules
                // sur son passage. Mouvement purement horizontal et continu → AUCUN saut. Le sens
                // vertical (marée) reste 100 % intact (on ne touche jamais à y).
                let s = bus.swell
                let amp: CGFloat = reduceMotion ? 0 : CGFloat(s?.punch ?? 0)
                let trendMul: CGFloat = (s?.trend == .building) ? 1.12 : ((s?.trend == .dropping) ? 0.88 : 1)
                bus.punchSmoothed += (amp * trendMul - bus.punchSmoothed) * 0.05   // ease (pas de saut au set/spot)
                let swellPeriod = CGFloat(max(s?.period ?? 11, 5))
                // Position de la bande ∈ [0,1[, DÉCROISSANTE (droite → gauche), 1 passage / période.
                bus.crestPhase = (bus.crestPhase - dt / swellPeriod).truncatingRemainder(dividingBy: 1)
                if bus.crestPhase < 0 { bus.crestPhase += 1 }
                let bandX = bus.crestPhase
                let bandPunch = bus.punchSmoothed
                let halfBand: CGFloat = 0.16                 // demi-largeur de la bande (fraction de largeur)
                let surfActive = bandPunch > 0.001
                // Composantes RGB pré-calculées (1×/frame) pour teinter sans alloc par particule.
                // En mode SURF (bus.swell présent), la teinte de BASE de TOUTES les particules = couleur
                // « période » de la courbe (orange clapot → vert houle propre), source unique
                // PremiumCurveCanvas.surfColor → les particules prennent vraiment la couleur, pas
                // seulement la bande. La bande ajoute par-dessus un éclat (même teinte éclaircie).
                let surfMode = (s != nil)
                let particleTint = surfMode ? PremiumCurveCanvas.surfColor(period: Double(swellPeriod)) : drawTint
                let baseRGB = rgbComponents(particleTint)
                let crestRGB: (r: Double, g: Double, b: Double) = surfMode
                    ? (r: baseRGB.r + (1 - baseRGB.r) * 0.40,
                       g: baseRGB.g + (1 - baseRGB.g) * 0.40,
                       b: baseRGB.b + (1 - baseRGB.b) * 0.40)
                    : rgbComponents(.orange)

                for p in particles {
                    var y = (p.baseY - vFlow * p.speed).truncatingRemainder(dividingBy: 1.0)
                    if y < 0 { y += 1 }

                    let sway = p.swayAmp * sin(CGFloat(t) * p.swayFreq + p.phase)
                    let gx = tilt.width * gyroParallax[p.plane]
                    let gy = tilt.height * gyroParallax[p.plane] * 0.5
                    let flow = bus.offset * flowParallax[p.plane]

                    // Position X enroulée (wrap) → mouvement latéral infini, jamais recentré
                    var px = ((p.x + sway) * w + flow).truncatingRemainder(dividingBy: w)
                    if px < 0 { px += w }
                    let hFade = edgeFade(px / w)
                    px += gx                                            // gyro post-wrap (léger)
                    let py = y * size.height + gy

                    // Scintillement (comète dans un rayon de soleil) : l'opacité oscille
                    let twinkle = (1 - p.twinkleAmp) + p.twinkleAmp * (0.5 + 0.5 * sin(CGFloat(t) * p.twinkleFreq + p.twinklePhase))
                    let alpha = baseAlpha[p.plane] * Double(edgeFade(y)) * Double(hFade) * Double(twinkle)
                    guard alpha > 0.012 else { continue }

                    // BANDE de houle : croissance locale au passage de la bande (taille + éclat +
                    // teinte orange), bump COSINUS doux sur la distance horizontale → aucun saut.
                    // Aucune modification de la position : la marée (axe vertical) reste intacte.
                    var r = p.size
                    var a = alpha
                    var tintP = particleTint
                    let pxDraw = px
                    if surfActive {
                        var d = abs(px / w - bandX)
                        if d > 0.5 { d = 1 - d }                       // distance circulaire (wrap horizontal)
                        if d < halfBand {
                            let bump = 0.5 + 0.5 * cos(d / halfBand * .pi)   // 1 au centre → 0 au bord, doux
                            r = p.size * (1 + bandPunch * 0.9 * bump)
                            a = min(1.0, alpha * (1 + Double(bandPunch * 0.7 * bump)))
                            let mix = Double(min(1, bandPunch * bump))
                            tintP = Color(red: baseRGB.r + (crestRGB.r - baseRGB.r) * mix,
                                          green: baseRGB.g + (crestRGB.g - baseRGB.g) * mix,
                                          blue: baseRGB.b + (crestRGB.b - baseRGB.b) * mix)
                        }
                    }
                    let rect = CGRect(x: pxDraw - r, y: py - r, width: r * 2, height: r * 2)
                    if p.plane != 3 {
                        // Plans loin/moyens : remplissage UNI. Le halo radial y est imperceptible
                        // à cette taille/opacité → gros gain GPU (≈ -60 % de dégradés radiaux par
                        // frame) sans changement visible. Réduit le léger lag des particules.
                        ctx.fill(Path(ellipseIn: rect), with: .color(tintP.opacity(a)))
                    } else {
                        // Premier plan fin : halo radial doux + cœur brillant (scintillement net).
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [tintP.opacity(a), tintP.opacity(0)]),
                                center: CGPoint(x: pxDraw, y: py),
                                startRadius: 0,
                                endRadius: r
                            )
                        )
                        let cr = max(0.9, r * 0.38)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: pxDraw - cr, y: py - cr, width: cr * 2, height: cr * 2)),
                            with: .color(tintP.opacity(min(1.0, a * 1.8)))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { if gyro && !reduceMotion { TiltMotionManager.shared.start() } }
        .onDisappear { if gyro && !reduceMotion { TiltMotionManager.shared.stop() } }
        .accessibilityHidden(true)
    }

    /// Atténue les particules près des bords pour une apparition/disparition douce.
    private func edgeFade(_ y: CGFloat) -> CGFloat {
        let m: CGFloat = 0.14
        let top = min(1, y / m)
        let bottom = min(1, (1 - y) / m)
        return max(0, min(top, bottom))
    }

    private static func makePool() -> [Particle] {
        var rng = SeededRNG(seed: 0x71DE_5EED)
        var out: [Particle] = []
        // loin, milieu, proche, premier plan fin
        let counts = [44, 34, 21, 31]
        // Tailles réduites pour loin / milieu / proche ; le 1er PLAN (plane 3) reste inchangé.
        let sizes:  [CGFloat] = [2.1, 3.8, 5.6, 1.6]
        let speeds: [CGFloat] = [0.022, 0.038, 0.060, 0.090]

        for plane in 0..<4 {
            for _ in 0..<counts[plane] {
                // Le premier plan fin oscille et scintille davantage (comète/rayon de soleil)
                let swayRange: ClosedRange<CGFloat> = plane == 3 ? 0.006...0.020 : 0.004...0.013
                let twinkleRange: ClosedRange<CGFloat> = plane == 3 ? 0.60...0.95 : 0.40...0.72
                out.append(Particle(
                    x: CGFloat.random(in: 0...1, using: &rng),
                    baseY: CGFloat.random(in: 0...1, using: &rng),
                    size: sizes[plane] * CGFloat.random(in: 0.7...1.3, using: &rng),
                    plane: plane,
                    speed: speeds[plane] * CGFloat.random(in: 0.8...1.25, using: &rng),
                    swayAmp: CGFloat.random(in: swayRange, using: &rng),
                    swayFreq: CGFloat.random(in: 0.2...0.7, using: &rng),
                    phase: CGFloat.random(in: 0...(.pi * 2), using: &rng),
                    twinkleAmp: CGFloat.random(in: twinkleRange, using: &rng),
                    twinkleFreq: CGFloat.random(in: 2.2...5.5, using: &rng),
                    twinklePhase: CGFloat.random(in: 0...(.pi * 2), using: &rng)
                ))
            }
        }
        return out
    }
}

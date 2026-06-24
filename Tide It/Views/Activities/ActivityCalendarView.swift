//
//  ActivityCalendarView.swift
//  Tide It
//
//  Calendrier 7 jours des fenêtres GO, par SPORT ACTIVÉ, pour le spot sélectionné.
//  C'est la Vue Activité : tu vois d'un coup d'œil QUAND c'est jouable cette semaine, par
//  sport (lanes empilées, couleur = sport). Les fenêtres viennent des CONDITIONS que tu as
//  réglées dans « Mes sports » (vent, direction, hauteur d'eau, fenêtre marée) — mêmes
//  conditions que les alertes. Vivant : recalculé dès que la prévision / le port / la marée
//  ou tes réglages changent.
//

import SwiftUI

struct ActivityCalendarView: View {
    @ObservedObject var tideService: TideService
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var sportStore = SportSetupStore.shared
    @ObservedObject private var premium = PremiumManager.shared
    @EnvironmentObject private var alertService: AlertService
    @Environment(\.dismiss) private var dismiss

    // Données chargées par port
    @State private var forecasts: [HourlyForecast] = []
    @State private var sunTimes: [(sunrise: Date, sunset: Date)] = []
    @State private var loading = true
    @State private var lastComputed: Date?
    /// Plan 7 jours mémoïsé (recalculé seulement quand une entrée change).
    @State private var plan: [DaySportPlan] = []
    /// Étoiles de qualité de session (1–5) par fenêtre (clé = début), UNIQUEMENT surf en AUTO.
    @State private var windowStars: [Date: Int] = [:]

    // Sélection / actions
    @State private var picked: PickedWindow?
    @State private var showEditor = false
    @State private var showSports = false
    @State private var showPaywall = false

    /// Horizon : 2 jours en gratuit, 7 en premium (calendrier GO = feature payante).
    // En gratuit on affiche AUSSI la semaine complète, mais FLOUTÉE (teaser) → « toutes les journées ».
    private var dayCount: Int { premium.isPremium ? premium.goCalendarDays : 7 }
    private let dayColW: CGFloat = 42
    private let iconColW: CGFloat = 20
    private let colSpacing: CGFloat = 8
    private let laneSpacing: CGFloat = 6
    private let laneHeight: CGFloat = 18

    private struct PickedWindow: Identifiable {
        let id = UUID()
        let sport: WindSport
        let window: GoWindow
    }

    private var port: Port? { tideService.selectedPort }
    /// Sports suivis ET exploitables (au moins une condition) → sinon ils ne produiraient
    /// aucune fenêtre et pollueraient la légende.
    private var enabledSetups: [SportSetup] {
        guard let portID = port?.id else { return [] }
        // Surf (conditions vides → SurfConditions) et AUTO (l'app calcule) ne doivent pas être filtrés.
        return sportStore.enabledSetups(for: portID).filter { $0.sport.isSurf || $0.auto || !$0.conditions.isEmpty }
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = port?.portTimeZone ?? TimeZone(identifier: "Europe/Paris") ?? .current
        return c
    }

    private func recomputePlan() {
        // Fenêtres GO calculées POUR TOUS : en gratuit elles s'affichent FLOUTÉES (teaser premium)
        // au lieu d'être masquées — « il se passe quelque chose, débloque-le ». Le flou + le voile
        // sont appliqués dans le corps de la vue ; le CALCUL est identique premium/gratuit.
        guard !forecasts.isEmpty, !enabledSetups.isEmpty else { plan = []; return }
        let tide = tideService.allTideData
        let spot = port.flatMap { SpotConfigStore.shared.config(for: $0.id) }
        plan = ActivityGoPlanner.plan(
            setups: enabledSetups,
            forecasts: forecasts, sunTimes: sunTimes,
            tideData: tide,
            from: Date(), days: dayCount, calendar: calendar,
            // Mode AUTO : « l'app calcule » → note du sport ≥ seuil (réutilise tout le scoring).
            scorer: { sport, f, lvl in
                ActivityScoreService.shared.scoreHour(sport: sport, at: f, tideData: tide, spot: spot, riderLevel: lvl)
            }
        )
        // Étoiles de qualité de session — précalculées (pas par frame), TOUT sport en AUTO
        // (moteur par sport via sessionStars : surf = houle, vent/kite/wing/voile = vent).
        var stars: [Date: Int] = [:]
        for day in plan {
            for lane in day.lanes where (enabledSetups.first { $0.sport == lane.sport }?.auto ?? false) {
                for w in lane.windows {
                    if let s = ActivityScoreService.shared.sessionStars(
                        sport: lane.sport, window: (w.start, w.end), forecasts: forecasts, tideData: tide, spot: spot) {
                        stars[w.start] = s
                    }
                }
            }
        }
        windowStars = stars
        stamp()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            header
            if enabledSetups.isEmpty {
                noSportState
            } else {
                legend
                if loading && forecasts.isEmpty {
                    loadingState
                } else {
                    let locked = !premium.isPremium
                    ZStack {
                        VStack(alignment: .leading, spacing: DS.spacingSM) {
                            ruler
                            VStack(spacing: DS.spacingSM) {
                                ForEach(plan) { day in dayRow(day) }
                            }
                        }
                        // Gratuit : on LAISSE voir les fenêtres GO floutées par journée (c'est ça le
                        // teaser). On ajoute seulement une couche de tap transparente → paywall.
                        // AUCUNE carte opaque par-dessus (sinon on ne verrait plus les fenêtres).
                        .blur(radius: locked ? 5 : 0)
                        .allowsHitTesting(!locked)
                        .accessibilityHidden(locked)
                        if locked {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { HapticManager.shared.impact(.light); showPaywall = true }
                        }
                    }
                    if locked { premiumTeaseBanner }   // CTA FINE sous le calendrier — n'occulte aucune journée
                    footer
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
        .task(id: port?.id) { await load() }
        // Vivant : marée mise à jour, réglages sport changés → on recalcule (sans re-fetch réseau).
        .onChange(of: tideService.allTideData.count) { recomputePlan() }
        .onChange(of: sportStore.byPort) { recomputePlan() }
        // L'horizon dépend du premium : recharger (sun preload) + recalculer si l'abonnement change.
        .onChange(of: premium.isPremium) { Task { await load() } }
        .confirmationDialog(dialogTitle, isPresented: pickedBinding, titleVisibility: .visible) {
            Button("Créer une alerte ici") {
                if premium.canUseAlerts { showEditor = true } else { showPaywall = true }
            }
            if PremiumManager.shared.canUseWindMode {
                Button("Voir en mode vent") {
                    themeManager.windMode = true
                    picked = nil
                    dismiss()
                }
            }
            Button("Annuler", role: .cancel) { picked = nil }
        }
        .sheet(isPresented: $showEditor) {
            AlertEditorView(alertService: alertService, tideService: tideService, existingAlert: nil)
                .environmentObject(themeManager)
                .presentationDetents([.large])
                .sheetBackground()
        }
        .sheet(isPresented: $showSports) {
            NavigationStack { SportSetupView(portID: port?.id ?? "") }
                .environmentObject(themeManager)
                .presentationDetents([.large])
                .sheetBackground()
        }
        .sheet(isPresented: $showPaywall) {
            PremiumPaywallView()
                .presentationDetents([.large])
                .sheetBackground()
        }
    }

    /// Bandeau d'upsell FIN, placé SOUS le calendrier flouté → n'occulte aucune journée (on garde le
    /// teaser : les fenêtres GO restent visibles, floutées). Tap → paywall (comme le calendrier lui-même).
    private var premiumTeaseBanner: some View {
        Button {
            HapticManager.shared.impact(.light)
            showPaywall = true
        } label: {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.cyan)
                Text("Aperçu flouté — passe en Premium pour lire tes fenêtres GO")
                    .font(.scaled(size: DS.fontFootnote, weight: .medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.spacingMD).padding(.vertical, DS.spacingSM)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cyan.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.cyan.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - En-tête

    private var header: some View {
        // « Mes sports » a migré sur la ligne des onglets (« + » de AlertsListView).
        // Ici : titre + le TOGGLE NOTIFICATIONS « fenêtre GO ici » À DROITE de « Fenêtres GO ».
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.spacingSM) {
                Text("Fenêtres GO")
                    .font(.scaled(size: DS.fontTitle3, weight: .bold))
                    .foregroundStyle(.primary)
                notifyToggle
                Spacer(minLength: 0)
            }
            Text("\(port?.name ?? "—") · \(dayCount) jours")
                .font(.scaled(size: DS.fontFootnote))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Toggle « me prévenir quand une fenêtre GO s'ouvre ICI ». Premium : ON/OFF par spot.
    /// Gratuit : verrouillé → paywall (le but : donner envie).
    private var notifyToggle: some View {
        let portID = port?.id ?? ""
        let on = premium.isPremium && sportStore.notify(for: portID)
        return Button {
            HapticManager.shared.impact(.light)
            guard premium.isPremium else { showPaywall = true; return }
            guard !portID.isEmpty else { return }
            sportStore.setNotify(!sportStore.notify(for: portID), for: portID)
        } label: {
            Image(systemName: on ? "bell.fill" : (premium.isPremium ? "bell.slash" : "bell.badge.slash.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.cyan : .gray)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.glassHighlight.opacity(on ? 0.12 : 0.06)))
        }
        .accessibilityLabel(on ? "Notifications des fenêtres GO activées ici" : "Activer les notifications des fenêtres GO ici")
    }

    // MARK: - Légende (sports suivis)

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(enabledSetups) { s in
                    HStack(spacing: 5) {
                        Image(systemName: s.sport.icon)
                            .font(.scaled(size: DS.fontCaption, weight: .semibold))
                        Text(s.sport.localizedName)
                            .font(.scaled(size: DS.fontCaption, weight: .medium))
                    }
                    .foregroundStyle(s.sport.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(s.sport.color.opacity(0.16)))
                    .overlay(Capsule().stroke(s.sport.color.opacity(0.4), lineWidth: 1))
                }
            }
        }
    }

    // MARK: - Règle horaire

    private var ruler: some View {
        let b = hourBounds
        return HStack(spacing: colSpacing) {
            Color.clear.frame(width: dayColW)
            HStack(spacing: laneSpacing) {
                Color.clear.frame(width: iconColW)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        ForEach(tickHours(b), id: \.self) { h in
                            let x = CGFloat((h - b.lo) / (b.hi - b.lo)) * geo.size.width
                            Text(hourLabel(h))
                                .font(.scaled(size: DS.fontCaption2))
                                .foregroundStyle(.gray.opacity(0.7))
                                .offset(x: min(max(x - 9, 0), geo.size.width - 18))
                        }
                    }
                }
                .frame(height: 12)
            }
        }
    }

    // MARK: - Ligne d'un jour

    private func dayRow(_ day: DaySportPlan) -> some View {
        HStack(alignment: .top, spacing: colSpacing) {
            dayLabel(day.day)
                .frame(width: dayColW, alignment: .leading)

            if day.lanes.isEmpty {
                HStack(spacing: laneSpacing) {
                    Color.clear.frame(width: iconColW)
                    Text("pas de fenêtre")
                        .font(.scaled(size: DS.fontCaption))
                        .foregroundStyle(.gray.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: laneHeight)
            } else {
                VStack(spacing: laneSpacing) {
                    ForEach(day.lanes) { lane in
                        laneView(sport: lane.sport, windows: lane.windows)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.glassHighlight.opacity(0.06)).frame(height: 0.5)
        }
    }

    private func dayLabel(_ date: Date) -> some View {
        let isToday = calendar.isDateInToday(date)
        return VStack(alignment: .leading, spacing: 1) {
            Text(weekdayLabel(date))
                .font(.scaled(size: DS.fontFootnote, weight: .bold))
                .foregroundStyle(isToday ? Color.cyan : .primary)
            Text(dayNumberLabel(date))
                .font(.scaled(size: DS.fontCaption2))
                .foregroundStyle(.gray)
        }
    }

    private func laneView(sport: WindSport, windows: [GoWindow]) -> some View {
        let b = hourBounds
        return HStack(spacing: laneSpacing) {
            Image(systemName: sport.icon)
                .font(.scaled(size: DS.fontCaption, weight: .semibold))
                .foregroundStyle(sport.color)
                .frame(width: iconColW)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.glassHighlight.opacity(0.05))
                    ForEach(windows, id: \.start) { w in
                        let x0 = frac(w.start, b) * geo.size.width
                        let x1 = frac(w.end, b) * geo.size.width
                        let width = max(x1 - x0, 6)
                        // Bandes GO en LECTURE SEULE : plus de menu contextuel au tap (retiré).
                        RoundedRectangle(cornerRadius: 5)
                            .fill(sport.color.opacity(0.85))
                            .overlay(
                                HStack(spacing: 3) {
                                    Text(rangeLabel(w))
                                        .font(.scaled(size: DS.fontCaption2, weight: .semibold))
                                        .foregroundStyle(.black.opacity(0.7))
                                    // Étoiles de qualité (surf en AUTO uniquement) — « la surprise du chef ».
                                    if let s = windowStars[w.start], width > 78 {
                                        Text(String(repeating: "★", count: s))
                                            .font(.scaled(size: DS.fontCaption2, weight: .bold))
                                            .foregroundStyle(.black.opacity(0.5))
                                    }
                                }
                                .padding(.horizontal, 3)
                                .opacity(width > 40 ? 1 : 0)
                            )
                            .frame(width: width)
                            .accessibilityLabel("\(sport.localizedName) — \(rangeLabel(w))")
                            .offset(x: min(x0, max(0, geo.size.width - width)))
                    }
                }
            }
            .frame(height: laneHeight)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            HapticManager.shared.impact(.light)
            showSports = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.scaled(size: DS.fontCaption2))
                    .foregroundStyle(.cyan.opacity(0.8))
                Text("Les fenêtres suivent la météo et tes réglages — touche pour ajuster tes sports.")
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.right")
                    .font(.scaled(size: DS.fontCaption2, weight: .semibold))
                    .foregroundStyle(.gray.opacity(0.6))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: - États

    private var loadingState: some View {
        HStack {
            ProgressView().tint(.cyan)
            Text("Calcul des fenêtres…")
                .font(.scaled(size: DS.fontFootnote))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private var noSportState: some View {
        VStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 34))
                .foregroundStyle(.cyan.opacity(0.8))
            Text("Choisis tes sports")
                .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Active et règle tes sports de vent (vent, direction, hauteur d'eau, marée). Le calendrier ne suivra que ceux-là.")
                .font(.scaled(size: DS.fontFootnote))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            Button {
                HapticManager.shared.impact(.light)
                showSports = true
            } label: {
                Text("Configurer mes sports")
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.spacingXL)
                    .padding(.vertical, DS.spacingMD)
                    .background(Capsule().fill(Color.accentGradient))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Données

    private func load() async {
        guard let port else { loading = false; return }
        loading = true
        let fc = await MarineWeatherService.shared.fetchHourlyForecast(for: port)
        let cal = calendar
        let start = cal.startOfDay(for: Date())
        var sun: [(sunrise: Date, sunset: Date)] = []
        for d in 0...(dayCount + 1) {
            if let day = cal.date(byAdding: .day, value: d, to: start),
               let s = SolarCalculator.sunriseSunset(latitude: port.latitude, longitude: port.longitude, date: day) {
                sun.append(s)
            }
        }
        forecasts = fc
        sunTimes = sun
        loading = false
        recomputePlan()
    }

    private func stamp() { lastComputed = Date() }

    // MARK: - Géométrie temps

    private var hourBounds: (lo: Double, hi: Double) {
        guard !sunTimes.isEmpty else { return (6, 22) }
        var lo = 24.0, hi = 0.0
        for s in sunTimes.prefix(dayCount + 1) {
            lo = min(lo, hourOfDay(s.sunrise))
            hi = max(hi, hourOfDay(s.sunset))
        }
        lo = max(4, lo.rounded(.down) - 1)
        hi = min(23, hi.rounded(.up) + 1)
        if hi - lo < 6 { return (6, 22) }
        return (lo, hi)
    }

    private func tickHours(_ b: (lo: Double, hi: Double)) -> [Double] {
        [b.lo, ((b.lo + b.hi) / 2).rounded(), b.hi]
    }

    private func frac(_ date: Date, _ b: (lo: Double, hi: Double)) -> CGFloat {
        let f = (hourOfDay(date) - b.lo) / (b.hi - b.lo)
        return CGFloat(min(max(f, 0), 1))
    }

    private func hourOfDay(_ date: Date) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Labels

    private var dialogTitle: String {
        guard let p = picked else { return "" }
        return "\(p.sport.localizedName) · \(rangeLabel(p.window))"
    }

    private var pickedBinding: Binding<Bool> {
        Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })
    }

    private func rangeLabel(_ w: GoWindow) -> String { "\(hhmm(w.start))–\(hhmm(w.end))" }

    private func hhmm(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        return m == 0 ? "\(h)h" : String(format: "%dh%02d", h, m)
    }

    private func hourLabel(_ h: Double) -> String { "\(Int(h))h" }

    // Formatters réutilisés (créés une fois) — éviter d'en allouer un par jour à chaque recalcul.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    private static let dayNumberFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private func weekdayLabel(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "auj." }
        let f = Self.weekdayFormatter
        f.timeZone = calendar.timeZone
        return f.string(from: date).lowercased().replacingOccurrences(of: ".", with: "")
    }

    private func dayNumberLabel(_ date: Date) -> String {
        let f = Self.dayNumberFormatter
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }
}

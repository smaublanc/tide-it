//
//  PecheAPiedView.swift
//  Tide It
//
//  Mode « Pêche à pied » (Premium) : meilleures sorties à venir, fenêtre
//  d'estran découvert, sécurité marée montante et espèces de saison.
//

import SwiftUI
import CoreLocation

struct PecheAPiedView: View {
    @ObservedObject var tideService: TideService
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var premium = PremiumManager.shared

    @State private var sessions: [ForagingSession] = []
    @State private var isComputing = false
    @State private var showPaywall = false
    @State private var selectedSpecies: ShellfishSpecies?
    @State private var dayFmt = SharedFormatters.frenchFullDate
    @State private var dayShortFmt = SharedFormatters.frenchShortDate
    @State private var timeFmt = SharedFormatters.time

    private var portTZ: TimeZone { tideService.selectedPort?.portTimeZone ?? .current }
    private var calendar: Calendar { Calendar.inTimeZone(portTZ) }
    private var currentMonth: Int { calendar.component(.month, from: Date()) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                if premium.canUsePecheAPied {
                    unlockedContent
                } else {
                    lockedTeaser
                }
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .navigationTitle("Pêche à pied")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                refreshFormatters()
                await loadIfNeeded()
            }
            .onChange(of: tideService.selectedPort?.id) { _, _ in
                // Changement de port (donc potentiellement de fuseau) : on réaligne les
                // formateurs et on recalcule les sorties.
                refreshFormatters()
                Task { await loadIfNeeded(force: true) }
            }
            .sheet(isPresented: $showPaywall) {
                PremiumPaywallView()
                    .presentationDetents([.large])
                    .sheetBackground()
            }
            .sheet(item: $selectedSpecies) { species in
                SpeciesDetailSheet(species: species)
                    .presentationDetents([.medium])
                    .sheetBackground()
            }
        }
    }

    // MARK: - Contenu débloqué

    @ViewBuilder
    private var unlockedContent: some View {
        VStack(spacing: DS.spacingXXL) {
            if isComputing && sessions.isEmpty {
                loadingState
            } else if let best = PecheAPiedService.shared.bestSession(in: sessions) {
                heroSection(best)
                upcomingSection
                speciesSection
                safetySection
                disclaimerFooter
            } else {
                emptyState
            }
        }
        .padding(DS.spacingXL)
        .padding(.bottom, 40)
    }

    private var loadingState: some View {
        VStack(spacing: DS.spacingLG) {
            ProgressView().tint(.cyan)
            Text("Analyse des marées à venir…")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var emptyState: some View {
        VStack(spacing: DS.spacingMD) {
            Image(systemName: "figure.fishing")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Aucune grande basse mer dans les 3 prochaines semaines")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Hero (meilleure sortie)

    private func heroSection(_ s: ForagingSession) -> some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            HStack {
                Label("Meilleure sortie", systemImage: "sparkles")
                    .font(.scaled(size: DS.fontFootnote, weight: .semibold))
                    .foregroundStyle(.mint)
                Spacer()
                if calendar.isDateInToday(s.lowTideDate) {
                    Text("Aujourd'hui")
                        .font(.scaled(size: DS.fontCaption2, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.mint))
                }
            }

            // Coefficient + qualité
            HStack(alignment: .firstTextBaseline, spacing: DS.spacingMD) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(s.coefficient)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(s.quality.color)
                        .monospacedDigit()
                    Text("coefficient")
                        .font(.scaled(size: DS.fontCaption, weight: .medium))
                        .foregroundStyle(.gray)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(s.quality.label)
                        .font(.scaled(size: DS.fontHeadline, weight: .bold))
                        .foregroundStyle(s.quality.color)
                    Label(s.daylight.label, systemImage: s.daylight.icon)
                        .font(.scaled(size: DS.fontCaption, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(dayFmt.string(from: s.lowTideDate).capitalized)
                .font(.scaled(size: DS.fontTitle3, weight: .semibold))
                .foregroundStyle(.primary)

            Divider().overlay(Color.glassHighlight.opacity(0.1))

            // Basse mer + fenêtre découverte
            HStack(spacing: DS.spacingXL) {
                heroMetric(
                    icon: "arrow.down.to.line",
                    title: "Basse mer",
                    value: timeFmt.string(from: s.lowTideDate),
                    subtitle: String(format: "%.2f m", locale: Locale.current, s.lowTideHeight),
                    color: .tideLow
                )
                if let start = s.windowStart, let end = s.windowEnd {
                    heroMetric(
                        icon: "figure.fishing",
                        title: "Estran découvert",
                        value: "\(timeFmt.string(from: start))–\(timeFmt.string(from: end))",
                        subtitle: s.windowDuration.map { durationLabel($0) } ?? "",
                        color: .mint
                    )
                }
            }

            // Sécurité retour de l'eau
            if let end = s.windowEnd {
                HStack(spacing: DS.spacingSM) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.scaled(size: DS.fontCallout))
                        .foregroundStyle(.orange)
                    Text("L'eau remonte vite : soyez remonté avant **\(timeFmt.string(from: end))**.")
                        .font(.scaled(size: DS.fontFootnote, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .padding(DS.spacingMD)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.radiusMD).fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.vertical, DS.spacingSM)
        // Dé-cadré : la qualité de la session = barre d'accent latérale (pattern Favoris).
        .overlay(alignment: .leading) {
            Capsule().fill(s.quality.color).frame(width: 3, height: 44)
                .offset(x: -DS.spacingMD)
        }
    }

    private func heroMetric(icon: String, title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.scaled(size: DS.fontCaption, weight: .medium))
                .foregroundStyle(.gray)
            Text(value)
                .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.scaled(size: DS.fontCaption2))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Prochaines sorties

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("Prochaines grandes marées")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(Array(sessions.prefix(14).enumerated()), id: \.element.id) { idx, s in
                    sessionRow(s)
                    if idx < min(sessions.count, 14) - 1 {
                        Divider().overlay(Color.glassHighlight.opacity(0.06))
                            .padding(.leading, 52)
                    }
                }
            }
        }
    }

    private func sessionRow(_ s: ForagingSession) -> some View {
        HStack(spacing: DS.spacingMD) {
            // Coefficient + pastille qualité
            ZStack {
                Circle().fill(s.quality.color.opacity(0.15)).frame(width: 40, height: 40)
                Text("\(s.coefficient)")
                    .font(.scaled(size: DS.fontCallout, weight: .bold, design: .rounded))
                    .foregroundStyle(s.quality.color)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(dayShortFmt.string(from: s.lowTideDate).capitalized)
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 9))
                    Text("BM \(timeFmt.string(from: s.lowTideDate)) · \(String(format: "%.2f m", locale: Locale.current, s.lowTideHeight))")
                }
                .font(.scaled(size: DS.fontCaption, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let start = s.windowStart, let end = s.windowEnd {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(timeFmt.string(from: start))–\(timeFmt.string(from: end))")
                        .font(.scaled(size: DS.fontFootnote, weight: .semibold, design: .rounded))
                        .foregroundStyle(.mint)
                    Image(systemName: s.daylight.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, DS.spacingLG)
        .padding(.vertical, DS.spacingMD)
    }

    // MARK: - Espèces de saison

    private var speciesSection: some View {
        // Espèces filtrées par la côte locale (ex. Bassin d'Arcachon = pas de tourteau).
        let local: (species: [ShellfishSpecies], coast: CoastType)
        if let port = tideService.selectedPort {
            local = ShellfishSpecies.localInSeason(month: currentMonth, latitude: port.latitude, longitude: port.longitude)
        } else {
            local = (ShellfishSpecies.inSeason(month: currentMonth), .rockyAtlantic)
        }
        let species = local.species
        return VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack(spacing: 6) {
                Text("Espèces de saison · \(SharedFormatters.frenchMonth.string(from: Date()))")
                    .font(.scaled(size: DS.fontBody, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(local.coast.localLabel)
                    .font(.scaled(size: DS.fontCaption, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan.opacity(0.15)))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.spacingMD) {
                    ForEach(species) { sp in
                        Button { selectedSpecies = sp } label: { speciesCard(sp) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func speciesCard(_ sp: ShellfishSpecies) -> some View {
        VStack(spacing: 6) {
            SpeciesImage(species: sp, size: 46)
            Text(sp.localizedName)
                .font(.scaled(size: DS.fontCaption, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sp.minSizeLabel)
                .font(.scaled(size: DS.fontCaption2, weight: .medium))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.cyan.opacity(0.12)))
        }
        .frame(width: 96)
        .padding(.vertical, DS.spacingMD)
        .background(RoundedRectangle(cornerRadius: DS.radiusMD).fill(Color.glassHighlight.opacity(0.05)))
    }

    // MARK: - Sécurité

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Label("Sécurité", systemImage: "shield.lefthalf.filled")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: DS.spacingSM) {
                safetyRow("clock.fill", "Descendez ~1 h avant la basse mer, remontez dès l'étale.")
                safetyRow("water.waves", "La marée remonte le plus vite à mi-marée (règle des douzièmes).")
                safetyRow("iphone.radiowaves.left.and.right", "Prévenez un proche et gardez un œil sur l'horaire de retour de l'eau.")
                safetyRow("wind", "Vérifiez vent et brouillard : un banc de sable peut s'isoler vite.")
            }
            .padding(.vertical, DS.spacingSM)
        }
    }

    private func safetyRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.spacingMD) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontCallout))
                .foregroundStyle(.cyan)
                .frame(width: 22)
            Text(text)
                .font(.scaled(size: DS.fontFootnote))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var disclaimerFooter: some View {
        Text("Tailles et saisons indicatives. La réglementation (tailles minimales, quotas, zones et périodes autorisées, salubrité) varie selon le département et la préfecture maritime — vérifiez toujours les arrêtés locaux avant de ramasser.")
            .font(.scaled(size: DS.fontCaption2))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Teaser verrouillé (non-Premium)

    private var lockedTeaser: some View {
        VStack(spacing: DS.spacingXL) {
            Image(systemName: "figure.fishing")
                .font(.system(size: 52))
                .foregroundStyle(LinearGradient(colors: [.mint, .cyan], startPoint: .top, endPoint: .bottom))
                .padding(.top, 40)

            Text("Mode Pêche à pied")
                .font(.scaled(size: DS.fontTitle2, weight: .bold))
                .foregroundStyle(.primary)

            Text("Repérez les meilleures basses mers, votre fenêtre d'estran découvert et l'heure de retour de l'eau.")
                .font(.scaled(size: DS.fontBody))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.spacingLG)

            VStack(alignment: .leading, spacing: DS.spacingMD) {
                teaserBullet("calendar.badge.clock", "Meilleures sorties classées sur 3 semaines")
                teaserBullet("figure.fishing", "Fenêtre exacte d'estran découvert")
                teaserBullet("exclamationmark.triangle.fill", "Alerte sécurité : retour de l'eau")
                teaserBullet("fish.fill", "Espèces de saison, tailles & conseils")
            }
            .padding(.vertical, DS.spacingSM)

            Button {
                HapticManager.shared.impact(.medium)
                showPaywall = true
            } label: {
                Text("Débloquer avec Premium")
                    .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.spacingLG)
                    .background(Capsule().fill(LinearGradient(colors: [.mint, .cyan], startPoint: .leading, endPoint: .trailing)))
            }
            .buttonStyle(.plain)
        }
        .padding(DS.spacingXL)
    }

    private func teaserBullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontCallout))
                .foregroundStyle(.mint)
                .frame(width: 26)
            Text(text)
                .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Chargement

    private func refreshFormatters() {
        dayFmt = SharedFormatters.frenchFullDate.copy(timeZone: portTZ)
        dayShortFmt = SharedFormatters.frenchShortDate.copy(timeZone: portTZ)
        timeFmt = SharedFormatters.time.copy(timeZone: portTZ)
    }

    private func loadIfNeeded(force: Bool = false) async {
        guard premium.canUsePecheAPied else { return }
        guard force || sessions.isEmpty else { return }
        isComputing = true
        defer { isComputing = false }

        // 1) Garantir la couverture sur 3 semaines
        await tideService.fetchExtendedPredictions(days: 21)

        // 2) Lever/coucher du soleil (pour le scoring jour/nuit)
        var sun: [(sunrise: Date, sunset: Date)] = []
        if let port = tideService.selectedPort {
            let loc = CLLocation(latitude: port.latitude, longitude: port.longitude)
            let raw = await WeatherService.shared.getSunriseSunsetRange(for: loc, from: Date(), days: 21)
            sun = raw.compactMap { item in
                guard let sr = item.sunrise, let ss = item.sunset else { return nil }
                return (sunrise: sr, sunset: ss)
            }
        }

        // 3) Calcul des sessions
        let tides = tideService.allTideData.isEmpty ? tideService.tideData : tideService.allTideData
        sessions = PecheAPiedService.shared.sessions(from: tides, sunTimes: sun)
    }

    private func durationLabel(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m >= 60 { return "\(m / 60)h\(String(format: "%02d", m % 60))" }
        return "\(m) min"
    }
}

// MARK: - Détail espèce

private struct SpeciesDetailSheet: View {
    let species: ShellfishSpecies
    @Environment(\.dismiss) private var dismiss

    private var monthsLabel: String {
        let symbols = ["jan", "fév", "mar", "avr", "mai", "juin", "juil", "août", "sep", "oct", "nov", "déc"]
        return species.bestMonths.sorted().compactMap { $0 >= 1 && $0 <= 12 ? symbols[$0 - 1] : nil }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.spacingMD) {
                SpeciesImage(species: species, size: 120).padding(.top, DS.spacingLG)
                VStack(spacing: 2) {
                    Text(species.localizedName)
                        .font(.scaled(size: DS.fontTitle2, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Text(species.latinName)
                        .font(.scaled(size: DS.fontFootnote))
                        .italic()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: DS.spacingMD) {
                    detailChip(icon: species.habitat.icon, label: species.habitat.rawValue)
                    detailChip(icon: "ruler", label: species.minSizeLabel)
                }

                VStack(alignment: .leading, spacing: DS.spacingMD) {
                    detailLine(icon: "calendar", title: "Saison", value: monthsLabel)
                    detailLine(icon: "lightbulb.fill", title: "Conseil", value: species.tip)
                }
                .padding(.vertical, DS.spacingSM)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Taille minimale indicative — vérifiez l'arrêté de votre département.")
                    .font(.scaled(size: DS.fontCaption2))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(DS.spacingXL)
        }
        .scrollContentBackground(.hidden)
        .appBackground()
    }

    private func detailChip(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.scaled(size: DS.fontFootnote, weight: .semibold))
            .foregroundStyle(.cyan)
            .padding(.horizontal, DS.spacingMD).padding(.vertical, 6)
            .background(Capsule().fill(Color.cyan.opacity(0.12)))
    }

    private func detailLine(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DS.spacingMD) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontCallout))
                .foregroundStyle(.cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.scaled(size: DS.fontCaption, weight: .medium))
                    .foregroundStyle(.gray)
                Text(value)
                    .font(.scaled(size: DS.fontSubheadline))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Image d'espèce (banque d'images, repli emoji)

/// Affiche l'illustration de l'espèce depuis le catalogue ; repli sur l'emoji si
/// l'asset est absent (sécurité — les 58 espèces de la banque ont une image).
struct SpeciesImage: View {
    let species: ShellfishSpecies
    var size: CGFloat

    var body: some View {
        if let name = species.imageName, UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(species.localizedName)
        } else {
            Text(species.emoji)
                .font(.system(size: size * 0.72))
                .accessibilityLabel(species.localizedName)
        }
    }
}

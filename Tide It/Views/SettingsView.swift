//
//  SettingsView.swift
//  Tide It
//

import SwiftUI
import StoreKit

struct SettingsView: View {
    @ObservedObject var tideService: TideService
    @ObservedObject private var premiumManager = PremiumManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showCacheCleared = false
    @State private var isRefreshing = false
    @State private var showPaywall = false
    @State private var showSpringTideHistory = false
    #if DEBUG
    @State private var debugPremium = UserDefaults.standard.bool(forKey: PremiumManager.debugForcePremiumKey)
    #endif
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DS.spacingXL) {
                headerSection
                if !premiumManager.isPremium { premiumSection }
                appearanceModeSection
                unitsSection          // unités + vent minimum (fusionnés)
                portsSection          // spots + données (fusionnés)
                aboutSection
                #if DEBUG
                debugSection
                #endif
                Spacer(minLength: 120)
            }
            .padding(.top, DS.spacingLG)
            .padding(.bottom, DS.spacingXXL)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if showCacheCleared { cacheToast }
        }
        .sheet(isPresented: $showPaywall) {
            PremiumPaywallView()
        }
        .sheet(isPresented: $showSpringTideHistory) {
            SpringTideHistoryView()
                .environmentObject(tideService)
                .sheetBackground()
        }
    }

    // MARK: - Header
    #if DEBUG
    // MARK: - Débogage (jamais en build App Store)
    private var debugSection: some View {
        SettingsSectionView(title: "Débogage", icon: "ladybug.fill", accentColor: .pink) {
            Toggle(isOn: Binding(
                get: { debugPremium },
                set: { newValue in
                    debugPremium = newValue
                    premiumManager.setDebugPremium(newValue)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Premium forcé (test)")
                        .font(.scaled(size: DS.fontBody, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Débloque toutes les features sans achat. DEBUG uniquement.")
                        .font(.scaled(size: DS.fontCaption))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.pink)
        }
    }
    #endif

    // (Titre affiché dans la barre centrée de la sheet.)
    private var headerSection: some View {
        EmptyView()
    }

    // MARK: - Appearance Mode Section
    private var appearanceModeSection: some View {
        SettingsSectionView(title: "Apparence", icon: "circle.lefthalf.filled", accentColor: .indigo) {
            VStack(spacing: DS.spacingMD) {
                Picker("Apparence", selection: $themeManager.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Divider().overlay(Color.glassHighlight.opacity(0.08))

                Toggle(isOn: $themeManager.tideParticles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Effet de profondeur")
                            .font(.scaled(size: DS.fontCallout, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("Particules ambiantes suivant le sens de la marée")
                            .font(.scaled(size: DS.fontCaption))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.cyan)
            }
            .padding(.horizontal, DS.spacingLG + 2)
            .padding(.vertical, DS.spacingMD + 2)
        }
    }

    // MARK: - Units Section
    private var unitsSection: some View {
        SettingsSectionView(title: "Unités", icon: "ruler.fill", accentColor: .teal) {
            VStack(spacing: DS.spacingMD) {
                // Système métrique / impérial
                VStack(alignment: .leading, spacing: DS.spacingSM) {
                    Text("Système de mesure")
                        .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $themeManager.measureSystem) {
                        ForEach(MeasureSystem.allCases, id: \.self) { sys in
                            Text(sys.label).tag(sys)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider()
                    .background(Color.glassHighlight.opacity(0.06))

                // Vitesse du vent
                VStack(alignment: .leading, spacing: DS.spacingSM) {
                    Text("Vitesse du vent")
                        .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $themeManager.windUnit) {
                        ForEach(WindSpeedUnit.allCases, id: \.self) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider()
                    .background(Color.glassHighlight.opacity(0.06))

                // Résumé des unités actives
                HStack(spacing: DS.spacingMD) {
                    unitBadge(themeManager.measureSystem.heightUnit, label: "Hauteur")
                    unitBadge(themeManager.windUnit.label, label: "Vent")
                    unitBadge(themeManager.measureSystem.tempUnit, label: "Temp.")
                }
                .animation(DS.defaultSpring, value: themeManager.measureSystem)
                .animation(DS.defaultSpring, value: themeManager.windUnit)
                // Limite de vent générale retirée : le vent mini/maxi se règle PAR SPORT
                // dans « Mes sports ».
            }
            .padding(.horizontal, DS.spacingLG + 2)
            .padding(.vertical, DS.spacingMD + 2)
        }
    }

    private func unitBadge(_ unit: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(unit)
                .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                .foregroundStyle(.teal)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Premium Section
    private var premiumSection: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: DS.spacingMD) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Passer à Premium")
                        .font(.scaled(size: DS.fontCallout, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Notifications, calendrier GO 7 jours, vent temps réel, J+30")
                        .font(.scaled(size: DS.fontCaption))
                        .foregroundStyle(.gray)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
            .padding(DS.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusLG)
                    .fill(
                        LinearGradient(
                            colors: [Color.yellow.opacity(0.08), Color.orange.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusLG)
                            .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - Ports Section
    private var portsSection: some View {
        SettingsSectionView(title: "Spots & données", icon: "mappin.and.ellipse", accentColor: .cyan) {
            Button { refreshData() } label: {
                SettingsRowView(icon: "arrow.clockwise", title: "Actualiser les marées", iconColor: .green) {
                    if isRefreshing {
                        ProgressView().scaleEffect(0.8).tint(.cyan)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.gray)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            settingsDivider

            Button { showSpringTideHistory = true } label: {
                SettingsRowView(icon: "water.waves", title: "Historique grandes marées", iconColor: .tideHigh) {
                    let count = SpringTideTracker.shared.records.count
                    if count > 0 {
                        Text("\(count)").font(.system(size: 13)).foregroundStyle(.gray)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)

            settingsDivider

            Button { clearCache() } label: {
                SettingsRowView(icon: "trash", title: "Effacer le cache", iconColor: .orange) {
                    Text(cacheSize).font(.system(size: 13)).foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Séparateur fin réutilisé entre les lignes d'une carte de réglages.
    private var settingsDivider: some View {
        Divider()
            .background(Color.glassHighlight.opacity(0.06))
            .padding(.horizontal, 18)
    }

    // MARK: - About Section
    /// URL `mailto` de contact — objet encodé proprement (UNE fois) via URLComponents.
    private var contactMailURL: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = "tideitapp@icloud.com"
        c.queryItems = [URLQueryItem(name: "subject", value: "Tide It — Support")]
        return c.url ?? URL(string: "mailto:tideitapp@icloud.com")!
    }

    private var aboutSection: some View {
        SettingsSectionView(title: "À propos", icon: "info.circle.fill", accentColor: .cyan) {
            SettingsRowView(icon: "app.badge", title: "Version", iconColor: .cyan) {
                Text(appVersion)
                    .font(.system(size: 14))
                    .foregroundStyle(.gray)
            }

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            SettingsRowView(icon: "globe", title: "Source des données", iconColor: .blue) {
                Text("Analyse harmonique")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.cyan)
            }

            // Disclaimer : prédictions calculées, pas une référence de navigation.
            Text("Prédictions calculées par analyse harmonique (données TICON, CC-BY 4.0). À titre indicatif — ne pas utiliser pour la navigation.")
                .font(.scaled(size: DS.fontCaption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 6)

            // Crédits balises vent (attribution requise — Pioupiou est en CC-BY — déplacé ici
            // depuis la card vent où le libellé de source a été retiré).
            Text("Vent temps réel — Balises : Pioupiou (CC-BY) · winds.mobi (Holfuy, FFVL, Romma…) · METAR & bouées NDBC (NOAA) · Weameter.  Prévisions de vent : Open-Meteo.")
                .font(.scaled(size: DS.fontCaption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 6)

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            // Apple Weather attribution (guideline 5.2.5)
            Link(destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!) {
                SettingsRowView(icon: "cloud.sun.fill", title: " Weather", iconColor: .cyan) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            // Politique de confidentialité
            Link(destination: URL(string: "https://smaublanc.github.io/tide-it/privacy.html")!) {
                SettingsRowView(icon: "hand.raised.fill", title: "Confidentialité", iconColor: .blue) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            // Conditions d'utilisation (guideline 3.1.2c)
            Link(destination: URL(string: "https://smaublanc.github.io/tide-it/terms.html")!) {
                SettingsRowView(icon: "doc.text", title: "Conditions d'utilisation", iconColor: .orange) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            // Contact / support — ouvre le client mail avec un sujet pré-rempli.
            // URLComponents encode l'objet UNE seule fois (le tiret cadratin non-ASCII cassait
            // l'ancien URL(string:) littéral → « %20 » affichés tels quels).
            Link(destination: contactMailURL) {
                SettingsRowView(icon: "envelope.fill", title: "Nous contacter", iconColor: .teal) {
                    Text("tideitapp@icloud.com")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            Button {
                requestReview()
            } label: {
                SettingsRowView(icon: "star.fill", title: "Noter l'application", iconColor: .yellow) {
                    HStack(spacing: 2) {
                        ForEach(0..<5) { _ in
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow.opacity(0.6))
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color.glassHighlight.opacity(0.06))
                .padding(.horizontal, 18)

            // swiftlint:disable:next force_unwrapping — Literal URL, cannot fail
            ShareLink(item: URL(string: "https://apps.apple.com/fr/app/tide-it-mar%C3%A9es-vent-r%C3%A9el/id6743555259")!) {
                SettingsRowView(icon: "square.and.arrow.up", title: "Partager l'application", iconColor: .indigo) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Toast
    private var cacheToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                Text("Cache effacé")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.glassHighlight.opacity(0.2), lineWidth: 0.5))
            )
            .padding(.bottom, 120)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showCacheCleared)
    }

    // MARK: - Computed
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var cacheSize: String {
        let tideCount = tideService.tideData.count
        if tideCount > 0 { return "~\(tideCount * 50 / 1024) Ko" }
        return "Vide"
    }

    // MARK: - Actions
    private func refreshData() {
        isRefreshing = true
        HapticManager.shared.impact(.medium)
        Task {
            await tideService.fetchTideData(forceRefresh: true)
            await MainActor.run {
                isRefreshing = false
                HapticManager.shared.notification(.success)
            }
        }
    }

    private func clearCache() {
        HapticManager.shared.impact(.light)
        TideCache.shared.clearAll()
        withAnimation { showCacheCleared = true }
        HapticManager.shared.notification(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showCacheCleared = false }
        }
    }

    private func requestReview() {
        HapticManager.shared.impact(.light)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            AppStore.requestReview(in: scene)
        }
    }
}

// MARK: - Settings Section (ultraThinMaterial, code couleur)
private struct SettingsSectionView<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: icon)
                    .font(.system(size: DS.sectionHeaderSize, weight: .bold))
                    .foregroundStyle(accentColor)
                    .frame(width: 24, height: 24)
                Text(title)
                    .sectionHeaderStyle()
            }
            .padding(.horizontal, 6)

            // Dé-cadré : groupe ouvert, les en-têtes de section structurent la page.
            VStack(spacing: 0) {
                content
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }
}

// MARK: - Settings Row
private struct SettingsRowView<Content: View>: View {
    let icon: String
    let title: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: DS.spacingLG) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusMD - 2)
                        .fill(iconColor.opacity(0.2))
                )

            Text(title)
                .font(.scaled(size: DS.fontHeadline, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()
            content
        }
        .padding(.horizontal, DS.spacingLG + 2)
        .padding(.vertical, DS.spacingMD + 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SettingsView(tideService: TideService())
        .environmentObject(ThemeManager.shared)
        .preferredColorScheme(.dark)
}

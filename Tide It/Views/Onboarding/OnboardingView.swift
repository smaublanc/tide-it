//
//  OnboardingView.swift
//  Tide It
//
//  Onboarding mode vent : fond néon sombre, sports de vent, permissions.
//

import SwiftUI
import CoreLocation
import UserNotifications

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @ObservedObject var locationManager: LocationManager
    @State private var currentPage = 0
    @State private var locationGranted = false
    @State private var notificationsGranted = false
    @State private var appeared = false
    @ObservedObject private var sportStore = SportSetupStore.shared

    private let pages = 4

    var body: some View {
        ZStack {
            // Animated background
            onboardingBackground

            VStack(spacing: 0) {
                // Content
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    activitiesPage.tag(1)
                    locationPage.tag(2)
                    notificationPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: currentPage)

                // Bottom section
                VStack(spacing: DS.spacingXL) {
                    // Step progress bar
                    stepProgressBar

                    // Button
                    Button {
                        HapticManager.shared.impact(.medium)
                        if currentPage < pages - 1 {
                            // Guideline 5.1.1(iv): trigger system permission before advancing
                            if currentPage == 2 && !locationGranted {
                                requestLocation()
                            }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                currentPage += 1
                            }
                        } else {
                            completeOnboarding()
                        }
                    } label: {
                        HStack(spacing: DS.spacingSM) {
                            Text(currentPage < pages - 1 ? "Continuer" : "Commencer")
                                .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                                .contentTransition(.numericText())

                            Image(systemName: currentPage < pages - 1 ? "arrow.right" : "checkmark")
                                .font(.scaled(size: DS.fontBody, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.spacingLG)
                        .background(
                            Capsule()
                                .fill(Color.accentGradient)
                                .shadow(color: .tideHigh.opacity(0.3), radius: 15, y: 5)
                        )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)

                    if currentPage == 0 {
                        Button {
                            completeOnboarding()
                        } label: {
                            Text("Passer")
                                .font(.scaled(size: DS.fontCallout, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, DS.spacingXXL)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                appeared = true
            }
        }
        // Fond toujours sombre → force le schéma sombre pour que `.primary`/`.secondary`
        // soient clairs (corrige le texte noir illisible en mode clair).
        .preferredColorScheme(.dark)
    }

    // MARK: - Background (DA mode vent : sombre profond + halos néon, sans vagues)
    private var onboardingBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.12),
                    Color(red: 0.05, green: 0.08, blue: 0.18),
                    Color(red: 0.02, green: 0.04, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Halos néon doux (cyan en haut, violet en bas) → profondeur du mode vent.
            RadialGradient(colors: [Color.tideHigh.opacity(0.18), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 360)
            RadialGradient(colors: [Color.tideLow.opacity(0.16), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: 380)
        }
        .ignoresSafeArea()
    }

    // MARK: - Step Progress Bar
    // Chaque segment se REMPLIT entièrement une fois l'étape atteinte (plus de fill à 60 %
    // bloqué sur l'étape courante) ; la dernière page → 4 segments pleins. Lueur sur l'étape active.
    private var stepProgressBar: some View {
        HStack(spacing: DS.spacingMD) {
            ForEach(0..<pages, id: \.self) { index in
                let done = index <= currentPage
                let isCurrent = index == currentPage
                Capsule()
                    .fill(done
                          ? AnyShapeStyle(LinearGradient(colors: pageColors(for: index),
                                                         startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color.glassHighlight.opacity(0.12)))
                    .frame(height: 4)
                    .shadow(color: isCurrent ? (pageColors(for: index).first ?? .tideHigh).opacity(0.6) : .clear,
                            radius: 4)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: currentPage)
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(currentPage + 1) sur \(pages)")
    }

    private func pageColors(for index: Int) -> [Color] {
        switch index {
        case 0: return [.tideHigh, .cyan]
        case 1: return [.blue, .tideMid]
        case 2: return [.orange, .yellow]
        default: return [.tideHigh, .cyan]
        }
    }

    // MARK: - Page 1: Welcome
    private var welcomePage: some View {
        OnboardingPageContent(pageIndex: 0, currentPage: currentPage) {
            VStack(spacing: DS.spacingXXL) {
                Spacer()

                // Animated wave icon
                ZStack {
                    // Glow rings
                    ForEach(0..<3, id: \.self) { ring in
                        Circle()
                            .stroke(Color.tideHigh.opacity(0.08 - Double(ring) * 0.02), lineWidth: 1)
                            .frame(width: CGFloat(120 + ring * 40), height: CGFloat(120 + ring * 40))
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.tideHigh.opacity(0.2), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)

                    Image(systemName: "water.waves")
                        .font(.system(size: 60))
                        .foregroundStyle(Color.tideGradient)
                        .shadow(color: .tideHigh.opacity(0.5), radius: 20)
                }

                VStack(spacing: DS.spacingMD) {
                    Text("Bienvenue sur")
                        .font(.scaled(size: DS.fontHeadline, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    Text("Tide It")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .tideHigh],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("Votre compagnon marées pour 3 500+ ports dans le monde.\nHoraires, coefficients, météo et activités nautiques.")
                        .font(.scaled(size: DS.fontBody))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                // Staggered feature pills
                VStack(spacing: DS.spacingSM) {
                    AnimatedFeaturePill(icon: "water.waves", text: "Marées en temps réel", color: .tideHigh, index: 0, appeared: currentPage == 0)
                    AnimatedFeaturePill(icon: "sparkles", text: "Sorties Parfaites pour tes activités", color: .yellow, index: 1, appeared: currentPage == 0)
                    AnimatedFeaturePill(icon: "dot.radiowaves.left.and.right", text: "Vent observé en direct (balises)", color: .teal, index: 2, appeared: currentPage == 0)
                    AnimatedFeaturePill(icon: "bell.badge.fill", text: "Alertes vent & marée sur mesure", color: .orange, index: 3, appeared: currentPage == 0)
                }

                Spacer()
                Spacer()
            }
        }
    }

    // MARK: - Page 3: Location
    private var locationPage: some View {
        OnboardingPageContent(pageIndex: 2, currentPage: currentPage) {
            VStack(spacing: DS.spacingXXL) {
                Spacer()

                ZStack {
                    // Radar rings animation
                    ForEach(0..<3, id: \.self) { ring in
                        Circle()
                            .stroke(Color.tideMid.opacity(0.1 - Double(ring) * 0.03), lineWidth: 1)
                            .frame(width: CGFloat(120 + ring * 40), height: CGFloat(120 + ring * 40))
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.tideMid.opacity(0.2), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)

                    Image(systemName: "location.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentGradient)
                        .shadow(color: .tideMid.opacity(0.5), radius: 20)
                }

                VStack(spacing: DS.spacingMD) {
                    Text("Port le plus proche")
                        .font(.scaled(size: DS.fontTitle, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Autorisez la localisation pour trouver automatiquement les ports près de vous et obtenir la météo locale.")
                        .font(.scaled(size: DS.fontBody))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                if locationGranted {
                    HStack(spacing: DS.spacingSM) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Localisation activée")
                            .foregroundStyle(.green)
                    }
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Localisation autorisée")
                } else {
                    Button {
                        requestLocation()
                    } label: {
                        HStack(spacing: DS.spacingSM) {
                            Image(systemName: "location.circle.fill")
                            Text("Autoriser la localisation")
                        }
                        .font(.scaled(size: DS.fontBody, weight: .semibold))
                        .foregroundStyle(Color.tideMid)
                        .padding(.horizontal, DS.spacingXXL)
                        .padding(.vertical, DS.spacingMD)
                        .background(
                            Capsule()
                                .fill(Color.tideMid.opacity(0.15))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.tideMid.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                }

                Spacer()
                Spacer()
            }
        }
    }

    // MARK: - Page 4: Notifications
    private var notificationPage: some View {
        OnboardingPageContent(pageIndex: 3, currentPage: currentPage) {
            VStack(spacing: DS.spacingXXL) {
                Spacer()

                ZStack {
                    ForEach(0..<3, id: \.self) { ring in
                        Circle()
                            .stroke(Color.orange.opacity(0.1 - Double(ring) * 0.03), lineWidth: 1)
                            .frame(width: CGFloat(120 + ring * 40), height: CGFloat(120 + ring * 40))
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.orange.opacity(0.2), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)

                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .yellow],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .orange.opacity(0.5), radius: 20)
                }

                VStack(spacing: DS.spacingMD) {
                    Text("Ne ratez rien")
                        .font(.scaled(size: DS.fontTitle, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Sorties Parfaites quand le vent et la marée s'alignent, et tes alertes perso pour ne rien rater.")
                        .font(.scaled(size: DS.fontBody))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                if notificationsGranted {
                    HStack(spacing: DS.spacingSM) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Notifications activées")
                            .foregroundStyle(.green)
                    }
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Notifications autorisées")
                } else {
                    Button {
                        requestNotifications()
                    } label: {
                        HStack(spacing: DS.spacingSM) {
                            Image(systemName: "bell.circle.fill")
                            Text("Activer les notifications")
                        }
                        .font(.scaled(size: DS.fontBody, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, DS.spacingXXL)
                        .padding(.vertical, DS.spacingMD)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                }

                Spacer()
                Spacer()
            }
        }
    }

    // MARK: - Activities Page

    private var activitiesPage: some View {
        OnboardingPageContent(pageIndex: 1, currentPage: currentPage) {
            VStack(spacing: DS.spacingXL) {
                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(colors: [.tideHigh, .tideLow], startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: .tideHigh.opacity(0.5), radius: 18)

                VStack(spacing: DS.spacingMD) {
                    Text("Tes sports de vent")
                        .font(.scaled(size: DS.fontTitle, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Choisis tes sports : on te dira quand c'est jouable (vent, marée, météo). Réglés sur 10–20 nœuds par défaut — tu affines après.")
                        .font(.scaled(size: DS.fontBody))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.spacingMD),
                                    GridItem(.flexible(), spacing: DS.spacingMD)],
                          spacing: DS.spacingMD) {
                    ForEach(WindSport.allCases) { sport in
                        sportChip(sport)
                    }
                }
                .padding(.horizontal, DS.pagePadding)

                Spacer()
                Spacer()
            }
        }
    }

    private func sportChip(_ sport: WindSport) -> some View {
        // À l'onboarding il n'y a pas encore de spot : on règle le TEMPLATE = défaut des nouveaux spots.
        let isOn = sportStore.templateSetup(sport).enabled
        let tint = sport.color
        let iconColor: Color = isOn ? tint : Color.white.opacity(0.5)
        let titleColor: Color = isOn ? Color.primary : Color.white.opacity(0.6)
        let checkColor: Color = isOn ? tint : Color.white.opacity(0.25)
        // Puce « verre » fine (DA mode vent) : fond translucide + liseré hairline, pas de cadre épais.
        let fillColor: Color = isOn ? tint.opacity(0.16) : Color.white.opacity(0.04)
        let strokeColor: Color = isOn ? tint.opacity(0.4) : Color.white.opacity(0.08)

        let background = RoundedRectangle(cornerRadius: DS.radiusMD)
            .fill(fillColor)
            .overlay(RoundedRectangle(cornerRadius: DS.radiusMD).stroke(strokeColor, lineWidth: 0.5))

        return Button {
            HapticManager.shared.impact(.light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                sportStore.setTemplateEnabled(sport, !isOn)   // défaut des nouveaux spots (10–20 kn)
            }
        } label: {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: sport.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(sport.localizedName)
                    .font(.scaled(size: DS.fontCallout, weight: .medium))
                    .foregroundStyle(titleColor)
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(checkColor)
            }
            .padding(DS.spacingMD)
            .background(background)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport.localizedName)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - Helpers
    private func requestLocation() {
        HapticManager.shared.impact(.light)
        locationManager.requestAuthorization()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            locationGranted = true
        }
    }

    private func requestNotifications() {
        HapticManager.shared.impact(.light)
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    notificationsGranted = granted ?? false
                }
            }
        }
    }

    private func completeOnboarding() {
        HapticManager.shared.success()
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isPresented = false
        }
    }
}

// MARK: - Onboarding Page Content Wrapper

private struct OnboardingPageContent<Content: View>: View {
    let pageIndex: Int
    let currentPage: Int
    @ViewBuilder let content: Content
    @State private var pageAppeared = false

    var body: some View {
        content
            .opacity(pageAppeared ? 1 : 0)
            .offset(y: pageAppeared ? 0 : 20)
            .onChange(of: currentPage) { _, newPage in
                if newPage == pageIndex {
                    pageAppeared = false
                    withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                        pageAppeared = true
                    }
                }
            }
            .onAppear {
                if currentPage == pageIndex {
                    withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                        pageAppeared = true
                    }
                }
            }
    }
}

// MARK: - Animated Feature Pill

private struct AnimatedFeaturePill: View {
    let icon: String
    let text: String
    let color: Color
    let index: Int
    let appeared: Bool

    @State private var visible = false

    var body: some View {
        HStack(spacing: DS.spacingSM + 2) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontCallout))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(color.opacity(0.12))
                )

            Text(text)
                .font(.scaled(size: DS.fontCallout, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, DS.spacingLG)
        .padding(.vertical, DS.spacingSM + 2)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSM + 2)
                .fill(Color.glassHighlight.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM + 2)
                        .stroke(Color.glassHighlight.opacity(0.06), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 40)
        .opacity(visible ? 1 : 0)
        .offset(x: visible ? 0 : -20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4 + Double(index) * 0.12)) {
                visible = true
            }
        }
        .onChange(of: appeared) { _, isNow in
            if isNow {
                visible = false
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1 + Double(index) * 0.12)) {
                    visible = true
                }
            }
        }
    }
}

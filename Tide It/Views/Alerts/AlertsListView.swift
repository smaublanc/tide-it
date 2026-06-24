//
//  AlertsListView.swift
//  Tide It
//
//  Liste des alertes — UI unifiée avec Design System
//

import SwiftUI

/// Segments du hub d'alertes : alertes proactives (Sorties Parfaites, Pêche à pied) vs
/// alertes manuelles à conditions (marée/vent).
enum AlertSegment: String, CaseIterable {
    case smart = "Calendrier"
    case manual = "Mes alertes"
}

struct AlertsListView: View {
    @EnvironmentObject var alertService: AlertService
    @ObservedObject var tideService: TideService
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var premium = PremiumManager.shared
    @State private var segment: AlertSegment = .smart
    @State private var showNewEditor = false
    @State private var showPresets = false
    @State private var showSports = false
    @State private var editingAlert: TideAlert?
    @State private var showPremiumPaywall = false

    /// Créer/activer une alerte = PREMIUM. Le gratuit peut PARCOURIR les modèles prédéfinis
    /// (cf. `showPresets`) pour donner envie, mais l'ajout est verrouillé (paywall).
    private var canCreateAlert: Bool { premium.canUseAlerts }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DS.spacingXL) {
                segmentPicker
                pendingConfirmationBanner
                if segment == .smart {
                    ActivityCalendarView(tideService: tideService)
                } else {
                    alertStatsHeader
                    quickAddSection
                    if alertService.alerts.isEmpty {
                        emptyState
                    } else {
                        alertsList
                    }
                }
            }
            .padding(.top, DS.spacingSM)
            .padding(.bottom, 120)
        }
        .scrollContentBackground(.hidden)
        // Création d'une nouvelle alerte
        .sheet(isPresented: $showNewEditor) {
            AlertEditorView(
                alertService: alertService,
                tideService: tideService,
                existingAlert: nil
            )
            .presentationDetents([.large])
            .sheetBackground()
        }
        // Modification d'une alerte existante
        .sheet(item: $editingAlert) { alert in
            AlertEditorView(
                alertService: alertService,
                tideService: tideService,
                existingAlert: alert
            )
            .presentationDetents([.large])
            .sheetBackground()
        }
        .sheet(isPresented: $showPresets) {
            AlertPresetsView(alertService: alertService, tideService: tideService)
                .presentationDetents([.medium, .large])
                .sheetBackground()
        }
        .sheet(isPresented: $showSports) {
            NavigationStack { SportSetupView(portID: tideService.selectedPort?.id ?? "") }
                .environmentObject(themeManager)
                .presentationDetents([.large])
                .sheetBackground()
        }
        .sheet(isPresented: $showPremiumPaywall) {
            PremiumPaywallView()
                .presentationDetents([.large])
                .sheetBackground()
        }
    }

    /// Action du « + » selon l'onglet : nouveau sport (Calendrier) ou nouvelle alerte (Mes alertes).
    private func headerAddAction() {
        HapticManager.shared.impact(.light)
        switch segment {
        case .smart:
            showSports = true
        case .manual:
            if canCreateAlert { showNewEditor = true } else { showPremiumPaywall = true }
        }
    }

    // MARK: - « Le vent s'établit » : confirmation en cours (live)
    @ViewBuilder
    private var pendingConfirmationBanner: some View {
        if let pending = WindEstablishingService.shared.activePending() {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let elapsed = max(0, Int(ctx.date.timeIntervalSince(pending.since) / 60))
                HStack(spacing: 12) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.76, blue: 0.30))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Le vent s'établit ?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(pending.name) · seuil franchi il y a \(elapsed) min — on vérifie que ça tient")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 0.95, green: 0.76, blue: 0.30).opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(red: 0.95, green: 0.76, blue: 0.30).opacity(0.30), lineWidth: 0.5))
                )
                .padding(.horizontal, DS.pagePadding)
            }
        }
    }

    // MARK: - Sélecteur de segment (souligné, composant partagé)
    private var segmentPicker: some View {
        UnderlineSegments(
            titles: AlertSegment.allCases.map(\.rawValue),
            selectedIndex: AlertSegment.allCases.firstIndex(of: segment) ?? 0
        ) { index in
            guard AlertSegment.allCases.indices.contains(index) else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                segment = AlertSegment.allCases[index]
            }
        }
        // « + » ALIGNÉ avec les onglets (Calendrier / Mes alertes). En OVERLAY → il n'occupe aucune
        // ligne propre, donc la mise en page est IDENTIQUE entre les deux écrans (plus de saut).
        .overlay(alignment: .trailing) {
            Button {
                headerAddAction()
            } label: {
                // Calendrier (.smart) → le « + » ouvre le RÉGLAGE des sports : icône « réglages »
                // plutôt qu'un « + » (on ne crée pas une entrée, on configure ses sports).
                // « Mes alertes » (.manual) → vrai ajout → on garde le « + ».
                Image(systemName: segment == .smart ? "slider.horizontal.3" : "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.cyan)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(segment == .smart ? "Régler mes sports" : "Nouvelle alerte")
        }
        .padding(.horizontal, DS.pagePadding)
    }

    /// Fin séparateur entre lignes (composant partagé), aligné après l'icône.
    private var rowDivider: some View {
        OpenRowDivider()
    }

    // MARK: - Statistiques
    private var alertStatsHeader: some View {
        VStack(spacing: DS.spacingSM) {
            HStack(spacing: 0) {
                StatBadge(icon: "bell.fill", value: "\(alertService.alerts.count)", label: "Total", color: .cyan)

                Divider()
                    .overlay(Color.glassHighlight.opacity(0.08))
                    .frame(height: 36)

                StatBadge(icon: "checkmark.circle.fill", value: "\(alertService.alerts.filter(\.isEnabled).count)", label: "Actives", color: .green)

                Divider()
                    .overlay(Color.glassHighlight.opacity(0.08))
                    .frame(height: 36)

                StatBadge(icon: "pause.circle.fill", value: "\(alertService.alerts.filter { !$0.isEnabled }.count)", label: "En pause", color: .orange)
            }
            .padding(.vertical, DS.spacingMD)

            if !premium.isPremium {
                // Les ALERTES sont premium. Le gratuit peut parcourir les modèles ci-dessous
                // (pour donner envie) mais l'ajout/activation est verrouillé → on l'explique.
                Button {
                    HapticManager.shared.impact(.light)
                    showPremiumPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.scaled(size: DS.fontCaption2))
                        Text("Les alertes et notifications nécessitent Premium — parcours les modèles pour voir")
                            .font(.scaled(size: DS.fontCaption, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - Ajout rapide
    private var quickAddSection: some View {
        Button {
            HapticManager.shared.impact(.light)
            // Libre : on peut PARCOURIR les modèles (l'AJOUT est premium, géré dans la sheet).
            showPresets = true
        } label: {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: "sparkles")
                    .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alertes prédéfinies")
                        .font(.scaled(size: DS.fontCallout, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Grande marée, basse mer, vent fort...")
                        .font(.scaled(size: DS.fontCaption))
                        .foregroundStyle(.gray)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, DS.spacingMD)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - État vide
    private var emptyState: some View {
        VStack(spacing: DS.spacingLG) {
            Image(systemName: "bell.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("Aucune alerte configurée")
                .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            Text("Créez des alertes pour être notifié des conditions de marée importantes.")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                HapticManager.shared.impact(.light)
                showPresets = true   // parcours libre des modèles (ajout premium dans la sheet)
            } label: {
                HStack(spacing: DS.spacingSM) {
                    Image(systemName: "sparkles")
                        .font(.scaled(size: DS.fontCallout))
                    Text("Découvrir les modèles")
                        .font(.scaled(size: DS.fontCallout, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DS.spacingXXL)
                .padding(.vertical, DS.spacingMD)
                .background(Capsule().fill(Color.accentGradient))
            }
            .buttonStyle(.plain)
            .padding(.top, DS.spacingSM)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - Liste des alertes
    private var alertsList: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: "bell.fill")
                    .font(.system(size: DS.sectionHeaderSize, weight: .bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 24, height: 24)
                Text("Mes alertes")
                    .sectionHeaderStyle()
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                ForEach(Array(alertService.alerts.enumerated()), id: \.element.id) { index, alert in
                    AlertRowView(
                        alert: alert,
                        onToggle: {
                            HapticManager.shared.impact(.light)
                            alertService.toggleAlert(id: alert.id)
                        },
                        onEdit: {
                            HapticManager.shared.impact(.light)
                            editingAlert = alert
                        },
                        onDelete: {
                            HapticManager.shared.notification(.warning)
                            withAnimation(DS.defaultSpring) {
                                alertService.removeAlert(id: alert.id)
                            }
                        }
                    )

                    if index < alertService.alerts.count - 1 {
                        Divider()
                            .overlay(Color.glassHighlight.opacity(0.06))
                            .padding(.leading, 56)
                    }
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }
}

// MARK: - Badge statistique
private struct StatBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontBody))
                .foregroundStyle(color)
            Text(value)
                .font(.scaled(size: DS.fontTitle2, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.scaled(size: DS.fontCaption2, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) : \(value)")
    }
}

// MARK: - Ligne d'alerte
struct AlertRowView: View {
    let alert: TideAlert
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            // Icône
            Image(systemName: alert.isEnabled ? "bell.fill" : "bell.slash")
                .font(.scaled(size: DS.fontBody, weight: .semibold))
                .foregroundStyle(alert.isEnabled ? .cyan : .gray)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .fill((alert.isEnabled ? Color.cyan : Color.gray).opacity(0.15))
                )

            // Infos
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.name)
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 9))
                    Text(alert.portName ?? "Tous les ports")
                        .font(.scaled(size: DS.fontCaption, weight: .medium))
                    Text("·")
                    Text("\(alert.conditions.count) condition\(alert.conditions.count > 1 ? "s" : "")")
                        .font(.scaled(size: DS.fontCaption, weight: .medium))
                }
                .foregroundStyle(.secondary)

                HStack(spacing: DS.spacingXS) {
                    ForEach(alert.conditions) { condition in
                        Image(systemName: condition.type.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan.opacity(0.7))
                            .padding(4)
                            .background(Circle().fill(Color.cyan.opacity(0.1)))
                    }
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { alert.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .tint(.cyan)
        }
        .padding(.horizontal, DS.spacingLG)
        .padding(.vertical, DS.spacingMD)
        .contextMenu {
            Button { onEdit() } label: { Label("Modifier", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("Supprimer", systemImage: "trash") }
        }
        .onTapGesture { onEdit() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Alerte \(alert.name), \(alert.portName ?? "tous les ports"), \(alert.conditions.count) condition\(alert.conditions.count > 1 ? "s" : ""), \(alert.isEnabled ? "active" : "en pause")")
    }
}

#Preview {
    AlertsListView(tideService: TideService())
        .environmentObject(AlertService())
        .environmentObject(ThemeManager.shared)
}

//
//  EmptyStateView.swift
//  Tide It
//
//  Vue d'état vide réutilisable avec SF Symbol, titre et CTA
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil
    var iconColor: Color = .gray

    var body: some View {
        VStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [iconColor.opacity(0.15), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 50
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [iconColor.opacity(0.6), iconColor.opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // Title
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            // Subtitle
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Action button
            if let actionTitle = actionTitle, let action = action {
                Button {
                    HapticManager.shared.impact(.light)
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let actionIcon = actionIcon {
                            Image(systemName: actionIcon)
                                .font(.system(size: 14))
                        }

                        Text(actionTitle)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.cyan, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Preset Empty States
extension EmptyStateView {
    /// État vide pour quand il n'y a pas de données de marées
    static func noTideData(onRetry: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "water.waves.slash",
            title: "Aucune donnée de marée",
            subtitle: "Les données ne sont pas encore disponibles. Vérifiez votre connexion internet.",
            actionTitle: "Réessayer",
            actionIcon: "arrow.clockwise",
            action: onRetry,
            iconColor: .cyan
        )
    }

    /// État vide pour la sélection de port
    static func noPortSelected(onSelect: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "mappin.slash",
            title: "Aucun port sélectionné",
            subtitle: "Choisissez un port pour voir les horaires de marées.",
            actionTitle: "Choisir un port",
            actionIcon: "location.fill",
            action: onSelect,
            iconColor: .blue
        )
    }

    /// État vide pour les favoris
    static var noFavorites: EmptyStateView {
        EmptyStateView(
            icon: "star.slash",
            title: "Aucun favori",
            subtitle: "Ajoutez des ports en favoris pour y accéder rapidement.",
            iconColor: .yellow
        )
    }

    /// État vide pour les alertes
    static func noAlerts(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "bell.slash",
            title: "Aucune alerte",
            subtitle: "Créez des alertes pour ne rien manquer.",
            actionTitle: "Créer une alerte",
            actionIcon: "plus.circle.fill",
            action: onAdd,
            iconColor: .orange
        )
    }

    /// État d'erreur réseau
    static func networkError(onRetry: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "wifi.slash",
            title: "Connexion perdue",
            subtitle: "Impossible de récupérer les données. Vérifiez votre connexion internet.",
            actionTitle: "Réessayer",
            actionIcon: "arrow.clockwise",
            action: onRetry,
            iconColor: .red
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        EmptyStateView.noTideData { }
        EmptyStateView.noFavorites
    }
    .background(Color.backgroundPrimary)
    .preferredColorScheme(.dark)
}

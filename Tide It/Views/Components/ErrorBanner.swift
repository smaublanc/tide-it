//
//  ErrorBanner.swift
//  Tide It
//
//  Bannière d'erreur non-intrusive affichée en haut de TodayView (et autres vues)
//  quand une opération échoue. Permet un retry et un dismiss explicite.
//

import SwiftUI

struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    init(message: String, onRetry: (() -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)

            // `.primary` et non `.white` : le fond est un `ultraThinMaterial`, qui s'éclaircit en
            // thème CLAIR → le texte blanc y devenait illisible (invisible sur fond blanc). La
            // Preview forçant `.preferredColorScheme(.dark)`, le défaut n'apparaissait jamais.
            Text(message)
                .font(.scaled(size: DS.fontCallout, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onRetry {
                Button {
                    HapticManager.shared.impact(.light)
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.primary.opacity(0.10)))
                }
                .accessibilityLabel("Réessayer")
            }

            Button {
                HapticManager.shared.impact(.light)
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Fermer")
        }
        .padding(.horizontal, DS.spacingLG)
        .padding(.vertical, DS.spacingMD)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusMD)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Erreur : \(message)"))
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack {
            ErrorBanner(
                message: "Impossible de charger les marées. Vérifiez votre connexion.",
                onRetry: {},
                onDismiss: {}
            )
            .padding()
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
}

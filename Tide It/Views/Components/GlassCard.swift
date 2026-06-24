//
//  GlassCard.swift
//  Tide It
//
//  ViewModifier glassmorphism réutilisable pour cartes et sections
//

import SwiftUI

// MARK: - Glass Card Modifier
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = DS.radiusLG
    var accentColor: Color = .cyan
    var padding: CGFloat = DS.spacingLG

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Group {
                    if colorScheme == .dark {
                        ZStack {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(.ultraThinMaterial)

                            // Glossy Liquid Glass iOS 26 (top highlight)
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.glassHighlight.opacity(0.16), Color.glassHighlight.opacity(0.06), Color.clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )

                            // Accent glow
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [accentColor.opacity(0.06), Color.tideLow.opacity(0.03), Color.clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            // Border gloss
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.glassHighlight.opacity(0.25), Color.glassHighlight.opacity(0.1), Color.glassHighlight.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(Color.glassHighlight)
                                .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)

                            // Subtle accent tint
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [accentColor.opacity(0.04), Color.clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            // Border
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(Color.cardBorder, lineWidth: 0.5)
                        }
                    }
                }
            )
    }
}

// MARK: - View Extension
extension View {
    func glassCard(
        cornerRadius: CGFloat = DS.radiusLG,
        accentColor: Color = .cyan,
        padding: CGFloat = DS.spacingLG
    ) -> some View {
        self.modifier(
            GlassCardModifier(
                cornerRadius: cornerRadius,
                accentColor: accentColor,
                padding: padding
            )
        )
    }
}

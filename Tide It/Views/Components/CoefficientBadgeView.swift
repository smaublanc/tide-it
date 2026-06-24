//
//  CoefficientBadgeView.swift
//  Tide It
//
//  Badge réutilisable pour afficher le coefficient de marée
//

import SwiftUI

struct CoefficientBadgeView: View {
    let coefficient: Int
    var style: BadgeStyle = .standard

    enum BadgeStyle {
        case compact    // Petit badge inline
        case standard   // Badge moyen avec label
        case expanded   // Grand badge avec description
    }

    private var coeffColor: Color {
        Color.coefficientColor(coefficient)
    }

    private var label: String {
        switch coefficient {
        case 0..<45: return "Mortes-eaux"
        case 45..<70: return "Moyennes"
        case 70..<95: return "Vives-eaux"
        default: return "Grandes marées"
        }
    }

    private var shortLabel: String {
        switch coefficient {
        case 0..<45: return "ME"
        case 45..<70: return "Moy"
        case 70..<95: return "VE"
        default: return "GM"
        }
    }

    var body: some View {
        switch style {
        case .compact:
            compactBadge
        case .standard:
            standardBadge
        case .expanded:
            expandedBadge
        }
    }

    // MARK: - Compact Badge
    private var compactBadge: some View {
        Text("\(coefficient)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(coeffColor.opacity(0.7))
            )
            .accessibilityLabel("Coefficient \(coefficient), \(label)")
    }

    // MARK: - Standard Badge
    private var standardBadge: some View {
        HStack(spacing: 6) {
            // Value
            Text("\(coefficient)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            // Separator
            Rectangle()
                .fill(Color.glassHighlight.opacity(0.2))
                .frame(width: 1, height: 16)

            // Label
            VStack(alignment: .leading, spacing: 1) {
                Text("Coef")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(shortLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [coeffColor.opacity(0.6), coeffColor.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.glassHighlight.opacity(0.2), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        LinearGradient(
                            colors: [Color.glassHighlight.opacity(0.3), coeffColor.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coefficient \(coefficient), \(label)")
    }

    // MARK: - Expanded Badge
    private var expandedBadge: some View {
        VStack(spacing: 8) {
            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.glassHighlight.opacity(0.1), lineWidth: 4)
                    .frame(width: 56, height: 56)

                Circle()
                    .trim(from: 0, to: CGFloat(coefficient) / 120.0)
                    .stroke(
                        LinearGradient(
                            colors: [coeffColor, coeffColor.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))

                Text("\(coefficient)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            // Label
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(coeffColor)

            // Bar indicator
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.glassHighlight.opacity(0.1))
                        .frame(height: 6)

                    // Fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: w * CGFloat(coefficient) / 120.0, height: 6)

                    // Marker
                    Circle()
                        .fill(Color.glassHighlight)
                        .frame(width: 10, height: 10)
                        .shadow(color: coeffColor, radius: 4)
                        .offset(x: w * CGFloat(coefficient) / 120.0 - 5)
                }
            }
            .frame(height: 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.glassHighlight.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [coeffColor.opacity(0.3), Color.glassHighlight.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coefficient \(coefficient), \(label)")
        .accessibilityValue("\(coefficient) sur 120")
    }
}

// MARK: - Coefficient Gradient Extension
extension Color {
    /// Gradient pour le coefficient de marée
    static func coefficientGradient(_ coefficient: Int) -> LinearGradient {
        let color = Color.coefficientColor(coefficient)
        return LinearGradient(
            colors: [color.opacity(0.6), color.opacity(0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 10) {
            CoefficientBadgeView(coefficient: 35, style: .compact)
            CoefficientBadgeView(coefficient: 55, style: .compact)
            CoefficientBadgeView(coefficient: 82, style: .compact)
            CoefficientBadgeView(coefficient: 105, style: .compact)
        }

        HStack(spacing: 10) {
            CoefficientBadgeView(coefficient: 35, style: .standard)
            CoefficientBadgeView(coefficient: 82, style: .standard)
            CoefficientBadgeView(coefficient: 105, style: .standard)
        }

        HStack(spacing: 10) {
            CoefficientBadgeView(coefficient: 35, style: .expanded)
            CoefficientBadgeView(coefficient: 105, style: .expanded)
        }
    }
    .padding()
    .background(Color.backgroundPrimary)
    .preferredColorScheme(.dark)
}

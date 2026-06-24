//
//  SkeletonView.swift
//  Tide It
//
//  Effet shimmer animé pour les états de chargement
//

import SwiftUI

struct SkeletonView: View {
    var cornerRadius: CGFloat = 8
    var height: CGFloat = 16

    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.glassHighlight.opacity(0.06))
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(shimmerGradient)
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius)
                    )
            )
            .onAppear {
                // Réduire les animations : pas de shimmer en boucle (placeholder statique).
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
    }

    private var shimmerGradient: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.glassHighlight.opacity(0.0),
                Color.glassHighlight.opacity(0.08),
                Color.glassHighlight.opacity(0.0)
            ],
            startPoint: isAnimating ? .trailing : .leading,
            endPoint: isAnimating ? UnitPoint(x: 2, y: 0.5) : .trailing
        )
    }
}

// MARK: - Skeleton Modifiers
extension View {
    func skeleton(isLoading: Bool, cornerRadius: CGFloat = 8) -> some View {
        self
            .opacity(isLoading ? 0 : 1)
            .overlay(
                Group {
                    if isLoading {
                        SkeletonView(cornerRadius: cornerRadius)
                    }
                }
            )
    }
}

// MARK: - Tide Skeleton Loading
struct TideSkeletonView: View {
    var body: some View {
        VStack(spacing: 16) {
            // Header skeleton
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonView(cornerRadius: 6, height: 22)
                        .frame(width: 200)
                    SkeletonView(cornerRadius: 4, height: 14)
                        .frame(width: 120)
                }
                Spacer()
                SkeletonView(cornerRadius: 10, height: 40)
                    .frame(width: 80)
            }
            .padding(.horizontal, 20)

            // Graph skeleton
            SkeletonView(cornerRadius: 16, height: 200)
                .padding(.horizontal, 16)

            // Tide points skeleton
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(spacing: 6) {
                        SkeletonView(cornerRadius: 12, height: 24)
                            .frame(width: 50)
                        SkeletonView(cornerRadius: 4, height: 12)
                            .frame(width: 40)
                    }
                }
            }
            .padding(.horizontal, 20)

            // Widget skeletons
            ForEach(0..<3, id: \.self) { _ in
                SkeletonView(cornerRadius: 16, height: 80)
                    .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Weather Skeleton
struct WeatherSkeletonView: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                SkeletonView(cornerRadius: 6, height: 18)
                    .frame(width: 100)
                Spacer()
            }

            HStack(spacing: 12) {
                SkeletonView(cornerRadius: 24, height: 130)
                VStack(spacing: 8) {
                    SkeletonView(cornerRadius: 14, height: 50)
                    SkeletonView(cornerRadius: 14, height: 50)
                }
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.glassHighlight.opacity(0.08), lineWidth: 0.5)
            }
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        TideSkeletonView()
        WeatherSkeletonView()
    }
    .padding()
    .background(Color.backgroundPrimary)
    .preferredColorScheme(.dark)
}

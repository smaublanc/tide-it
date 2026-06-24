//
//  WindmillIcon.swift
//  Tide It
//
//  Petit moulin à vent animé — 4 pales en teardrop qui tournent.
//  Utilisé sur les pins carte pour indiquer qu'un anémomètre temps réel
//  (Pioupiou, Holfuy, etc.) est disponible à proximité du port.
//

import SwiftUI

struct WindmillIcon: View {
    /// Taille globale en points
    var size: CGFloat = 14

    /// Couleur des pales
    var tint: Color = .white

    /// Durée d'un tour complet (secondes)
    var rotationSpeed: Double = 3.0

    /// Sens de rotation
    var clockwise: Bool = true

    /// Animation de rotation. À désactiver sur la carte (beaucoup de pins) pour
    /// éviter des dizaines d'animations `repeatForever` simultanées.
    var animated: Bool = true

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // 4 pales disposées à 90°
            ForEach(0..<4, id: \.self) { i in
                WindmillBlade()
                    .fill(tint)
                    .frame(width: size * 0.24, height: size * 0.46)
                    .offset(y: -size * 0.23)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // Hub central
            Circle()
                .fill(tint.opacity(0.9))
                .frame(width: size * 0.20, height: size * 0.20)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                )
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(animated ? rotation : (clockwise ? 22 : -22)))
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: rotationSpeed).repeatForever(autoreverses: false)) {
                rotation = clockwise ? 360 : -360
            }
        }
        .accessibilityHidden(true)
    }
}

/// Forme d'une pale (teardrop vers le haut)
private struct WindmillBlade: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let topX = rect.midX
        let topY = rect.minY
        let bottomX = rect.midX
        let bottomY = rect.maxY
        let leftCtrlX = rect.minX
        let rightCtrlX = rect.maxX
        let ctrlY = rect.midY * 0.65

        // Pointe haute → base à gauche
        p.move(to: CGPoint(x: topX, y: topY))
        p.addQuadCurve(
            to: CGPoint(x: bottomX, y: bottomY),
            control: CGPoint(x: leftCtrlX, y: ctrlY)
        )
        // Base à droite → pointe haute
        p.addQuadCurve(
            to: CGPoint(x: topX, y: topY),
            control: CGPoint(x: rightCtrlX, y: ctrlY)
        )
        return p
    }
}

#Preview {
    ZStack {
        Color.blue.opacity(0.4).ignoresSafeArea()
        HStack(spacing: 30) {
            WindmillIcon(size: 12, tint: .white)
            WindmillIcon(size: 20, tint: .white, rotationSpeed: 2.0)
            WindmillIcon(size: 30, tint: .cyan, rotationSpeed: 4.0)
            WindmillIcon(size: 48, tint: .yellow, rotationSpeed: 1.5)
        }
    }
}

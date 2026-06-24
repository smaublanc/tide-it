//
//  WindDirectionPicker.swift
//  Tide It
//
//  Gros cadran boussole — toucher/glisser pour choisir d'où vient le vent
//

import SwiftUI

/// Cadran boussole : grosse bague tournante + arc coloré pour la zone de tolérance.
/// Toucher n'importe où sur le cadran = définir la direction d'origine du vent.
struct WindDirectionPicker: View {
    @Binding var centerDirection: Double   // Direction d'origine du vent (0-360°)
    @Binding var spreadAngle: Double       // Tolérance ± en degrés (5-90°)

    @State private var isDragging = false

    private let cardinals: [(Double, String)] = [
        (0, "N"), (45, "NE"), (90, "E"), (135, "SE"),
        (180, "S"), (225, "SO"), (270, "O"), (315, "NO")
    ]
    private let minSpread: Double = 5
    private let maxSpread: Double = 90

    init(centerDirection: Binding<Double>, spreadAngle: Binding<Double>) {
        self._centerDirection = centerDirection
        self._spreadAngle = spreadAngle
    }

    var body: some View {
        VStack(spacing: DS.spacingXL) {
            // ── Compass dial ──
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let ctr = CGPoint(x: geo.size.width / 2, y: size / 2)
                let outerR = size / 2 - 6
                let ringWidth: CGFloat = 32
                let midR = outerR - ringWidth / 2

                ZStack {
                    // Ring background
                    Circle()
                        .stroke(Color.glassHighlight.opacity(0.06), lineWidth: ringWidth)
                        .frame(width: midR * 2, height: midR * 2)
                        .position(ctr)

                    // Inner subtle circle
                    Circle()
                        .stroke(Color.glassHighlight.opacity(0.04), lineWidth: 0.5)
                        .frame(width: (midR - ringWidth / 2) * 2, height: (midR - ringWidth / 2) * 2)
                        .position(ctr)

                    // Colored arc — acceptance zone on the ring
                    WindArc(direction: centerDirection, spread: spreadAngle)
                        .stroke(
                            AngularGradient(
                                colors: [Color.cyan.opacity(0.3), Color.cyan.opacity(0.8),
                                         Color.cyan, Color.cyan.opacity(0.8), Color.cyan.opacity(0.3)],
                                center: .center,
                                startAngle: .degrees(centerDirection - spreadAngle - 90),
                                endAngle: .degrees(centerDirection + spreadAngle - 90)
                            ),
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                        )
                        .frame(width: midR * 2, height: midR * 2)
                        .position(ctr)

                    // Inner glow fill (subtle wedge)
                    WindCone(direction: centerDirection, spread: spreadAngle)
                        .fill(
                            RadialGradient(
                                colors: [Color.cyan.opacity(0.12), Color.cyan.opacity(0.02), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: midR - ringWidth / 2
                            )
                        )
                        .frame(width: (midR - ringWidth / 2) * 2, height: (midR - ringWidth / 2) * 2)
                        .position(ctr)

                    // Tick marks (every 10°)
                    ForEach(0..<36, id: \.self) { i in
                        let angle = Double(i) * 10
                        let isMajor = i % 9 == 0
                        let tickInner = midR + ringWidth / 2 + 2
                        let tickOuter = tickInner + (isMajor ? 6 : 3)
                        let p1 = ptOnCircle(ctr, tickInner, angle)
                        let p2 = ptOnCircle(ctr, tickOuter, angle)

                        Path { p in p.move(to: p1); p.addLine(to: p2) }
                            .stroke(Color.glassHighlight.opacity(isMajor ? 0.35 : 0.12),
                                    lineWidth: isMajor ? 1.5 : 0.5)
                    }

                    // Cardinal labels
                    ForEach(cardinals, id: \.0) { angle, label in
                        let isMain = Int(angle) % 90 == 0
                        Text(label)
                            .font(.system(size: isMain ? 13 : 10, weight: isMain ? .bold : .medium))
                            .foregroundStyle(isMain ? .secondary : .tertiary)
                            .position(ptOnCircle(ctr, outerR + 16, angle))
                    }

                    // ── Handle knob ── on the ring at centerDirection
                    let handlePos = ptOnCircle(ctr, midR, centerDirection)
                    ZStack {
                        // Glow halo
                        Circle()
                            .fill(Color.cyan.opacity(isDragging ? 0.4 : 0.2))
                            .frame(width: 50, height: 50)

                        // Main handle
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 34, height: 34)
                            .overlay(
                                Image(systemName: "wind")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .overlay(
                                Circle().stroke(Color.glassHighlight.opacity(0.6), lineWidth: 2)
                            )
                            .shadow(color: Color.cyan.opacity(0.6), radius: isDragging ? 12 : 6)
                    }
                    .position(handlePos)
                    .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: centerDirection)

                    // ── Center info ──
                    VStack(spacing: 2) {
                        Text("D'où vient")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("\(Int(centerDirection))°")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)

                        Text(cardinalName(for: centerDirection))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.cyan)

                        Text("±\(Int(spreadAngle))°")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.cyan.opacity(0.7))
                            .padding(.top, 1)
                    }
                    .position(ctr)
                }
                .frame(width: geo.size.width, height: size)
                .contentShape(
                    // Only capture touches on the ring band (not center)
                    RingShape(innerRadius: midR - ringWidth, outerRadius: outerR + 20)
                )
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            isDragging = true
                            let angle = angleFrom(location: value.location, center: ctr)
                            centerDirection = (angle).rounded()
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 280)

            // ── Spread angle slider ──
            VStack(spacing: DS.spacingSM) {
                HStack {
                    Label("Tolérance", systemImage: "angle")
                        .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                        .foregroundStyle(.gray)
                    Spacer()
                    Text("±\(Int(spreadAngle))°")
                        .font(.scaled(size: DS.fontBody, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                        .monospacedDigit()
                }

                Slider(value: $spreadAngle, in: minSpread...maxSpread, step: 5)
                    .tint(.cyan)

                // Plage résultante
                HStack(spacing: DS.spacingXS) {
                    Spacer()
                    let lo = normalizeAngle(centerDirection - spreadAngle)
                    let hi = normalizeAngle(centerDirection + spreadAngle)
                    Text("\(Int(lo))°")
                        .foregroundStyle(.cyan.opacity(0.7))
                    Text("→")
                        .foregroundStyle(.tertiary)
                    Text("\(Int(centerDirection))°")
                        .foregroundStyle(.primary)
                        .fontWeight(.bold)
                    Text("→")
                        .foregroundStyle(.tertiary)
                    Text("\(Int(hi))°")
                        .foregroundStyle(.cyan.opacity(0.7))
                    Spacer()
                }
                .font(.scaled(size: DS.fontCaption, design: .rounded))
            }
        }
    }

    // MARK: - Helpers

    private func ptOnCircle(_ center: CGPoint, _ radius: CGFloat, _ compassAngle: Double) -> CGPoint {
        let rad = (compassAngle - 90) * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(rad)),
            y: center.y + radius * CGFloat(sin(rad))
        )
    }

    private func angleFrom(location: CGPoint, center: CGPoint) -> Double {
        let dx = location.x - center.x
        let dy = location.y - center.y
        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        if angle >= 360 { angle -= 360 }
        return angle
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    private func cardinalName(for angle: Double) -> String {
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]
        let idx = Int(round(normalizeAngle(angle) / 22.5)) % 16
        return dirs[idx]
    }
}

// MARK: - Ring Content Shape (for hit-testing only the ring band)

private struct RingShape: Shape {
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius,
                    startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        path.addArc(center: center, radius: max(innerRadius, 0),
                    startAngle: .zero, endAngle: .degrees(360), clockwise: true)
        return path
    }
}

// MARK: - Arc Shape (ring stroke)

private struct WindArc: Shape {
    let direction: Double
    let spread: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let startAngle = Angle.degrees(direction - spread - 90)
        let endAngle = Angle.degrees(direction + spread - 90)

        path.addArc(center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

// MARK: - Cone Shape (inner glow fill)

private struct WindCone: Shape {
    let direction: Double
    let spread: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        path.move(to: center)

        let startAngle = Angle.degrees(direction - spread - 90)
        let endAngle = Angle.degrees(direction + spread - 90)

        path.addArc(center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

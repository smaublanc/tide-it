//
//  TideComparisonView.swift
//  Tide It
//
//  Comparateur de marées multi-ports — courbes superposées avec légendes
//

import SwiftUI

struct TideComparisonView: View {
    @ObservedObject var tideService: TideService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPorts: [Port] = []
    @State private var comparisonData: [String: [TideData]] = [:]
    @State private var isLoading = false
    @State private var showPortSelector = false

    // Colors for each compared port
    private static let portColors: [Color] = [.cyan, .orange, .green, .pink]

    private var favoritePorts: [Port] {
        tideService.ports.filter(\.isFavorite)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: DS.spacingLG) {
                    // Port selection chips
                    portChipsSection

                    // Comparison graph
                    if !comparisonData.isEmpty {
                        comparisonGraphSection
                    } else if isLoading {
                        ProgressView()
                            .frame(height: 250)
                    } else {
                        emptyState
                    }

                    // Tide time offsets between ports
                    if comparisonData.count >= 2 {
                        tideOffsetsSection
                    }
                }
                .padding(.horizontal, DS.pagePadding)
                .padding(.vertical, DS.spacingLG)
            }
            .appBackground()
            .navigationTitle("Comparer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Pre-select current port + first favorite
            if selectedPorts.isEmpty {
                if let current = tideService.selectedPort {
                    selectedPorts.append(current)
                }
                if let firstFav = favoritePorts.first(where: { $0.id != tideService.selectedPort?.id }) {
                    selectedPorts.append(firstFav)
                }
                loadComparisonData()
            }
        }
        .sheet(isPresented: $showPortSelector) {
            portSelectorSheet
        }
    }

    // MARK: - Port Chips
    private var portChipsSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("PORTS À COMPARER")
                .sectionHeaderStyle()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.spacingSM) {
                    ForEach(Array(selectedPorts.enumerated()), id: \.element.id) { index, port in
                        let color = Self.portColors[index % Self.portColors.count]
                        portChip(port: port, color: color, index: index)
                    }

                    if selectedPorts.count < 3 {
                        Button {
                            HapticManager.shared.impact(.light)
                            showPortSelector = true
                        } label: {
                            HStack(spacing: DS.spacingXS) {
                                Image(systemName: "plus.circle.fill")
                                Text("Ajouter")
                            }
                            .font(.scaled(size: DS.fontCallout, weight: .medium))
                            .foregroundStyle(Color.tideHigh)
                            .padding(.horizontal, DS.spacingMD)
                            .padding(.vertical, DS.spacingSM)
                            .background(
                                Capsule()
                                    .stroke(Color.tideHigh.opacity(0.3), lineWidth: 1)
                                    .background(Capsule().fill(Color.tideHigh.opacity(0.05)))
                            )
                        }
                    }
                }
            }
        }
    }

    private func portChip(port: Port, color: Color, index: Int) -> some View {
        HStack(spacing: DS.spacingXS) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(port.name)
                .font(.scaled(size: DS.fontCallout, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Button {
                HapticManager.shared.impact(.light)
                selectedPorts.removeAll { $0.id == port.id }
                comparisonData.removeValue(forKey: port.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.scaled(size: DS.fontFootnote))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.spacingMD)
        .padding(.vertical, DS.spacingSM)
        .glassBackground(cornerRadius: DS.radiusMD)
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Comparison Graph
    private var comparisonGraphSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("COURBES SUPERPOSÉES")
                .sectionHeaderStyle()

            // Dé-cadré : les courbes respirent directement sur le fond.
            ComparisonCurveCanvas(
                comparisonData: comparisonData,
                portOrder: selectedPorts.map(\.id),
                portColors: Self.portColors,
                currentTime: Date()
            )
            .frame(height: 250)
        }
    }

    // MARK: - Tide Offsets
    private var tideOffsetsSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text("DÉCALAGE HORAIRE")
                .sectionHeaderStyle()

            let portIds = selectedPorts.map(\.id)
            let refPortId = portIds.first ?? ""
            let refData = comparisonData[refPortId] ?? []

            ForEach(Array(selectedPorts.dropFirst().enumerated()), id: \.element.id) { index, port in
                let otherData = comparisonData[port.id] ?? []
                let offset = computeTideOffset(ref: refData, other: otherData)
                let color = Self.portColors[(index + 1) % Self.portColors.count]

                HStack(spacing: DS.spacingMD) {
                    Circle().fill(color).frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(port.name)
                            .font(.scaled(size: DS.fontCallout, weight: .semibold))
                            .foregroundStyle(.primary)

                        if let offset {
                            let sign = offset >= 0 ? "+" : ""
                            let hours = abs(offset) / 60
                            let mins = abs(offset) % 60
                            Text("\(sign)\(hours > 0 ? "\(hours)h " : "")\(mins)min vs \(selectedPorts.first?.name ?? "")")
                                .font(.scaled(size: DS.fontCaption, weight: .medium))
                                .foregroundStyle(.gray)
                        } else {
                            Text("Données insuffisantes")
                                .font(.scaled(size: DS.fontCaption))
                                .foregroundStyle(.gray)
                        }
                    }

                    Spacer()
                }
                .padding(DS.spacingMD)
                .glassBackground(cornerRadius: DS.radiusMD)
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: DS.spacingLG) {
            Image(systemName: "chart.line.text.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(Color.tideHigh.opacity(0.4))

            Text("Sélectionnez au moins 2 ports pour comparer leurs marées")
                .font(.scaled(size: DS.fontBody))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(height: 200)
    }

    // MARK: - Port Selector Sheet
    private var portSelectorSheet: some View {
        NavigationStack {
            List {
                Section("Favoris") {
                    ForEach(favoritePorts) { port in
                        if !selectedPorts.contains(where: { $0.id == port.id }) {
                            Button {
                                selectedPorts.append(port)
                                showPortSelector = false
                                loadComparisonData()
                            } label: {
                                Text(port.name)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ajouter un port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Annuler") { showPortSelector = false }
                }
            }
        }
        .sheetBackground()
    }

    // MARK: - Data Loading
    private func loadComparisonData() {
        guard !selectedPorts.isEmpty else { return }
        isLoading = true

        Task {
            for port in selectedPorts where comparisonData[port.id] == nil {
                if port.id == tideService.selectedPort?.id, !tideService.tideData.isEmpty {
                    comparisonData[port.id] = tideService.tideData
                } else {
                    // Pipeline standard (harmoniques maison / NOAA / TICON + cache).
                    let data = await tideService.fetchTideDataForPort(port.id)
                    if !data.isEmpty {
                        comparisonData[port.id] = data
                    }
                }
            }
            isLoading = false
        }
    }

    // MARK: - Compute Tide Offset
    private func computeTideOffset(ref: [TideData], other: [TideData]) -> Int? {
        let refHighs = ref.filter(\.isHighTide).sorted { $0.date < $1.date }
        let otherHighs = other.filter(\.isHighTide).sorted { $0.date < $1.date }

        guard let refFirst = refHighs.first else { return nil }

        // Find closest high tide in other data
        let closest = otherHighs.min(by: { abs($0.date.timeIntervalSince(refFirst.date)) < abs($1.date.timeIntervalSince(refFirst.date)) })
        guard let match = closest else { return nil }

        return Int(match.date.timeIntervalSince(refFirst.date) / 60)
    }
}

// MARK: - Comparison Curve Canvas
struct ComparisonCurveCanvas: View {
    let comparisonData: [String: [TideData]]
    let portOrder: [String]
    let portColors: [Color]
    let currentTime: Date

    var body: some View {
        Canvas { context, size in
            // Compute global bounds across all ports
            var globalMin = Double.infinity
            var globalMax = -Double.infinity
            var globalStart = Date.distantFuture
            var globalEnd = Date.distantPast

            for (_, tides) in comparisonData {
                for tide in tides {
                    if tide.height < globalMin { globalMin = tide.height }
                    if tide.height > globalMax { globalMax = tide.height }
                    if tide.date < globalStart { globalStart = tide.date }
                    if tide.date > globalEnd { globalEnd = tide.date }
                }
            }

            let padding = (globalMax - globalMin) * 0.1
            let hMin = globalMin - padding
            let hSpan = max((globalMax + padding) - hMin, 0.1)
            let duration = max(globalEnd.timeIntervalSince(globalStart), 3600)
            let margin: CGFloat = 16

            // Draw each port's curve
            for (i, portId) in portOrder.enumerated() {
                guard let tides = comparisonData[portId], tides.count >= 2 else { continue }
                let color = portColors[i % portColors.count]
                let sorted = tides.sorted { $0.date < $1.date }

                var path = Path()
                var cursor = 0
                let step: CGFloat = 3
                var first = true

                for x in stride(from: 0, through: size.width, by: step) {
                    let progress = Double(x / size.width)
                    let date = globalStart.addingTimeInterval(progress * duration)

                    while cursor < sorted.count - 1 && sorted[cursor + 1].date <= date {
                        cursor += 1
                    }

                    let height: Double
                    if cursor < sorted.count - 1 {
                        let prev = sorted[cursor]
                        let next = sorted[cursor + 1]
                        let segDur = next.date.timeIntervalSince(prev.date)
                        if segDur > 0 {
                            let t = date.timeIntervalSince(prev.date) / segDur
                            let cosT = (1 - cos(t * .pi)) / 2
                            height = prev.height + (next.height - prev.height) * cosT
                        } else {
                            height = prev.height
                        }
                    } else if cursor < sorted.count {
                        height = sorted[cursor].height
                    } else {
                        continue
                    }

                    let normalizedH = (height - hMin) / hSpan
                    let y = margin + (size.height - margin * 2) * (1 - CGFloat(normalizedH))

                    if first {
                        path.move(to: CGPoint(x: Double(x), y: y))
                        first = false
                    } else {
                        path.addLine(to: CGPoint(x: Double(x), y: y))
                    }
                }

                // Glow
                var glowCtx = context
                glowCtx.addFilter(.blur(radius: 6))
                glowCtx.opacity = 0.3
                glowCtx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // Stroke
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
            }

            // Draw "now" line
            let nowProgress = currentTime.timeIntervalSince(globalStart) / duration
            if nowProgress >= 0, nowProgress <= 1 {
                let nowX = CGFloat(nowProgress) * size.width
                var nowPath = Path()
                nowPath.move(to: CGPoint(x: nowX, y: 0))
                nowPath.addLine(to: CGPoint(x: nowX, y: size.height))
                context.stroke(
                    nowPath,
                    with: .color(Color.glassHighlight.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }
        }
        .drawingGroup()
    }
}

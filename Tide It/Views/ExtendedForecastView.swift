//
//  ExtendedForecastView.swift
//  Tide It
//
//  Vue des prédictions de marées étendues (J8 à J30+)
//  basées sur l'analyse harmonique astronomique
//

import SwiftUI

struct ExtendedForecastView: View {
    @ObservedObject var tideService: TideService
    @EnvironmentObject private var themeManager: ThemeManager
    var onDismiss: (() -> Void)? = nil
    @StateObject private var engine = HarmonicTideEngine.shared
    @State private var selectedDay: Date?
    @State private var predictionDays: Int = 30
    @State private var hasLoadedPredictions = false

    private var portTimeZone: TimeZone {
        tideService.selectedPort?.portTimeZone ?? TimeZone(identifier: "Europe/Paris") ?? .current
    }
    private var calendar: Calendar { Calendar.inTimeZone(portTimeZone) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: DS.spacingLG) {
                // Header
                headerSection

                // Indicateur de précision
                accuracyBadge

                // Sélecteur de période
                periodSelector

                // Données SHOM (J1-7) résumé
                if !tideService.tideData.isEmpty {
                    shomDataSection
                }

                // Prédictions étendues
                if tideService.isLoadingExtended {
                    loadingSection
                } else if tideService.extendedTideData.isEmpty && hasLoadedPredictions {
                    noDataSection
                } else {
                    extendedTidesSection
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 120)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if !hasLoadedPredictions {
                loadPredictions()
            }
        }
        .onChange(of: tideService.selectedPort?.id) { _, _ in
            loadPredictions()
        }
    }

    private func loadPredictions() {
        hasLoadedPredictions = true
        Task {
            await tideService.fetchExtendedPredictions(days: predictionDays)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            if let onDismiss = onDismiss {
                Button {
                    HapticManager.shared.impact(.light)
                    withAnimation(DS.defaultSpring) {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.scaled(size: DS.fontCallout, weight: .semibold))
                        .foregroundStyle(Color.tideHigh)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .stroke(Color.tideHigh.opacity(0.2), lineWidth: 0.5)
                                )
                        )
                }
            }

            VStack(alignment: .leading, spacing: DS.spacingXS) {
                Text("Prédictions")
                    .pageHeaderStyle()

                if let port = tideService.selectedPort {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.scaled(size: DS.fontFootnote))
                        Text(port.name)
                            .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                    }
                    .foregroundStyle(.gray)
                }
            }

            Spacer()

            VStack(spacing: 2) {
                Image(systemName: "function")
                    .font(.scaled(size: DS.fontTitle2, weight: .semibold))
                    .foregroundStyle(Color.tideGradient)
                Text("Harmonique")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.tideLow.opacity(0.8))
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - Accuracy Badge

    private var accuracyBadge: some View {
        HStack(spacing: DS.spacingSM + 2) {
            Image(systemName: engine.predictionAccuracy.icon)
                .font(.scaled(size: DS.fontHeadline))
                .foregroundStyle(accuracyColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.predictionAccuracy.localizedName)
                    .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(accuracyDescription)
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.gray)
            }

            Spacer()

            if let portId = tideService.selectedPort?.id {
                let count = engine.constituentCount(for: portId)
                if count > 0 {
                    VStack(spacing: 1) {
                        Text("\(count)")
                            .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tideHigh)
                        Text("composantes")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        // Dé-cadré : bandeau ouvert sur le fond (DA sans cadre).
        .padding(.vertical, DS.spacingMD)
        .padding(.horizontal, DS.pagePadding)
    }

    private var accuracyColor: Color {
        switch engine.predictionAccuracy {
        case .uncalibrated: return .gray
        case .calibrating: return .orange
        case .low: return .yellow
        case .medium: return .green
        case .high: return .cyan
        case .veryHigh: return .purple
        }
    }

    private var accuracyDescription: String {
        switch engine.predictionAccuracy {
        case .uncalibrated:
            return String(localized: "Aucune donnée de calibrage disponible")
        case .calibrating:
            return String(localized: "Calibrage en cours avec les données officielles...")
        case .low:
            return String(localized: "Prédiction indicative, erreur possible > 30cm")
        case .medium:
            return String(localized: "Prédiction fiable, erreur < 35cm / 25min")
        case .high:
            return String(localized: "Prédiction précise, erreur < 20cm / 15min")
        case .veryHigh:
            return String(localized: "Prédiction très précise, erreur < 10cm / 10min")
        }
    }

    // MARK: - Period Selector

    private var periodSelector: some View {
        HStack(spacing: DS.spacingSM) {
            PeriodChip(label: "14 jours", isSelected: predictionDays == 14) {
                predictionDays = 14
                loadPredictions()
            }
            PeriodChip(label: "30 jours", isSelected: predictionDays == 30) {
                predictionDays = 30
                loadPredictions()
            }
            PeriodChip(label: "60 jours", isSelected: predictionDays == 60) {
                predictionDays = 60
                loadPredictions()
            }
            PeriodChip(label: "90 jours", isSelected: predictionDays == 90) {
                predictionDays = 90
                loadPredictions()
            }
        }
        .padding(.horizontal, DS.spacingLG)
    }

    // MARK: - SHOM Data Summary

    private var shomDataSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack(spacing: 6) {
                Image(systemName: "water.waves")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan)
                Text("CETTE SEMAINE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.cyan.opacity(0.8))
                    .tracking(0.5)

                Spacer()

                let days = shomDaysCount
                Text("\(days) jour\(days > 1 ? "s" : "")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.6))
            }
            .padding(.horizontal, 20)

            // Résumé compact des données SHOM
            let grouped = Dictionary(grouping: tideService.tideData) {
                calendar.startOfDay(for: $0.date)
            }
            let sortedDays = grouped.keys.sorted()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sortedDays, id: \.self) { day in
                        let tides = grouped[day] ?? []
                        SHOMDayChip(day: day, tides: tides, portTimeZone: portTimeZone)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var shomDaysCount: Int {
        let days = Set(tideService.tideData.map { calendar.startOfDay(for: $0.date) })
        return days.count
    }

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.cyan)
                .scaleEffect(1.2)

            Text("Calcul des prédictions harmoniques...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.gray)

            Text("Analyse de \(engine.constituentCount(for: tideService.selectedPort?.id ?? "")) composantes astronomiques")
                .font(.system(size: 11))
                .foregroundStyle(.gray.opacity(0.6))
        }
        .padding(.vertical, 40)
    }

    // MARK: - No Data

    private var noDataSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(.gray.opacity(0.4))

            Text("Prédictions non disponibles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Le moteur harmonique n'a pas assez de données pour ce port. Consultez d'abord les marées du jour pour calibrer les prédictions.")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 40)
    }

    // MARK: - Extended Tides

    private var extendedTidesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                Text("PRÉDICTIONS HARMONIQUES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.purple.opacity(0.8))
                    .tracking(0.5)

                Spacer()

                Text("\(tideService.extendedTideData.count) marées")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.6))
            }
            .padding(.horizontal, 20)

            // Grouper par jour
            let grouped = Dictionary(grouping: tideService.extendedTideData) {
                calendar.startOfDay(for: $0.date)
            }
            let sortedDays = grouped.keys.sorted()

            VStack(spacing: 0) {
                ForEach(Array(sortedDays.enumerated()), id: \.element) { i, day in
                    let tides = (grouped[day] ?? []).sorted { $0.date < $1.date }
                    PredictionDayCard(
                        day: day,
                        tides: tides,
                        isSelected: selectedDay == day,
                        portTimeZone: portTimeZone
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedDay = selectedDay == day ? nil : day
                        }
                    }
                    if i < sortedDays.count - 1 { OpenRowDivider(leadingInset: 14) }
                }
            }
            .padding(.horizontal, DS.pagePadding)
        }
    }
}

// MARK: - Period Chip

private struct PeriodChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    ZStack {
                        Capsule()
                            .fill(isSelected ?
                                AnyShapeStyle(LinearGradient(colors: [.purple, .cyan], startPoint: .leading, endPoint: .trailing)) :
                                AnyShapeStyle(Color.glassHighlight.opacity(0.06))
                            )
                        if !isSelected {
                            Capsule()
                                .stroke(Color.glassHighlight.opacity(0.1), lineWidth: 0.5)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SHOM Day Chip

private struct SHOMDayChip: View {
    let day: Date
    let tides: [TideData]
    var portTimeZone: TimeZone = .current

    var body: some View {
        VStack(spacing: 4) {
            Text(CachedDateFormatter.make("E dd", timeZone: portTimeZone).string(from: day).capitalized)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)

            ForEach(tides.sorted(by: { $0.date < $1.date })) { tide in
                HStack(spacing: 3) {
                    Image(systemName: tide.isHighTide ? "arrow.up" : "arrow.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(tide.isHighTide ? .cyan : .blue)

                    Text(String(format: "%.1f", UnitFormatter.heightValue(tide.height, system: MeasureSystem(rawValue: UserDefaults.standard.string(forKey: "measureSystem") ?? "") ?? .metric)))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.08))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
            }
        )
    }
}

// MARK: - Prediction Day Card

private struct PredictionDayCard: View {
    let day: Date
    let tides: [TideData]
    let isSelected: Bool
    var portTimeZone: TimeZone = .current
    let onTap: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    private var dayFormatter: DateFormatter { CachedDateFormatter.make("EEEE d MMMM", timeZone: portTimeZone) }
    private var timeFormatter: DateFormatter { CachedDateFormatter.make("HH:mm", timeZone: portTimeZone) }

    var body: some View {
        VStack(spacing: 0) {
            // Header du jour
            Button(action: onTap) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayFormatter.string(from: day).capitalized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)

                        // Résumé rapide
                        HStack(spacing: 8) {
                            if let maxCoef = tides.compactMap(\.coefficient).max() {
                                HStack(spacing: 3) {
                                    Text("C\(maxCoef)")
                                        .font(.scaled(size: DS.fontCaption, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.coefficientColor(maxCoef))
                                }
                            }

                            if let maxH = tides.filter({ $0.isHighTide }).map(\.height).max() {
                                Text("PM \(UnitFormatter.height(maxH, system: themeManager.measureSystem))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.cyan.opacity(0.8))
                            }

                            if let minH = tides.filter({ !$0.isHighTide }).map(\.height).min() {
                                Text("BM \(UnitFormatter.height(minH, system: themeManager.measureSystem))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.blue.opacity(0.8))
                            }
                        }
                    }

                    Spacer()

                    // Nombre de marées
                    Text("\(tides.count)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.purple)

                    Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
            .padding(14)

            // Détail si sélectionné
            if isSelected {
                Divider()
                    .background(Color.glassHighlight.opacity(0.08))

                VStack(spacing: 6) {
                    ForEach(tides) { tide in
                        HStack(spacing: 10) {
                            // Icône
                            Image(systemName: tide.isHighTide ? "water.waves" : "water.waves.slash")
                                .font(.system(size: 14))
                                .foregroundStyle(tide.isHighTide ? .cyan : .blue)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(tide.isHighTide ? Color.cyan.opacity(0.12) : Color.blue.opacity(0.12))
                                )

                            // Type
                            Text(tide.isHighTide ? "PM" : "BM")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tide.isHighTide ? .cyan : .blue)
                                .frame(width: 28)

                            // Heure
                            Text(timeFormatter.string(from: tide.date))
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)

                            Spacer()

                            // Hauteur
                            Text(UnitFormatter.height(tide.height, system: themeManager.measureSystem, decimals: 2))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)

                            // Coefficient
                            if let coef = tide.coefficient {
                                Text("C\(coef)")
                                    .font(.scaled(size: DS.fontCaption, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.coefficientColor(coef))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(Color.coefficientColor(coef).opacity(0.15))
                                    )
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        // Dé-cadré : bloc ouvert, sélection = teinte + barre d'accent (pattern Favoris).
        .background(isSelected ? Color.tideLow.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Color.tideLow).frame(width: 3, height: 30)
            }
        }
        .contentShape(Rectangle())
    }

}

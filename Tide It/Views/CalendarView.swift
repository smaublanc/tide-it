//
//  CalendarView.swift
//  Tide It
//
//  Vue calendrier pour consulter les marées sur plusieurs jours
//

import SwiftUI

struct CalendarView: View {
    @ObservedObject var tideService: TideService
    @State private var selectedDate = Date()
    @State private var currentMonth = Date()

    private var portTimeZone: TimeZone {
        tideService.selectedPort?.portTimeZone ?? TimeZone(identifier: "Europe/Paris") ?? .current
    }

    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }
    @State private var showExtended = false
    @State private var showPremiumPaywall = false
    @State private var cachedShomDays: Set<Date> = []
    @State private var cachedAllTideDays: Set<Date> = []
    @State private var cachedTidesForSelectedDate: [TideData] = []
    @State private var cachedDayCoefficients: [Date: Int] = [:]

    /// Calendrier au fuseau du port → grille du mois, regroupement des marées par jour
    /// et « aujourd'hui » alignés sur l'heure locale du port.
    private var calendar: Calendar { Calendar.inTimeZone(portTimeZone) }

    /// Interdit de remonter vers un mois entièrement écoulé (les marées passées n'ont pas d'intérêt).
    private var canGoToPreviousMonth: Bool {
        guard let displayed = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth)),
              let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) else { return true }
        return displayed > thisMonth
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    var body: some View {
        if showExtended {
            ExtendedForecastView(tideService: tideService, onDismiss: {
                showExtended = false
            })
        } else {
            calendarContent
                .sheet(isPresented: $showPremiumPaywall) {
                    PremiumPaywallView()
                }
        }
    }

    private var calendarContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: DS.spacingLG) {
                // Grille calendrier
                calendarGrid

                // Marées du jour sélectionné
                if !cachedTidesForSelectedDate.isEmpty {
                    selectedDaySection
                } else {
                    emptyStateSection
                }
            }
            .padding(.top, DS.spacingSM)
            .padding(.bottom, 120)
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { exportToolbarButton }
            ToolbarItem(placement: .topBarTrailing) { extendedToolbarButton }
        }
        // (pull-to-refresh retiré : comportement uniforme de toutes les sheets — le
        // slide vers le bas sert uniquement à fermer la fenêtre)
        .onAppear {
            updateCachedDays()
            if tideService.extendedTideData.isEmpty && !tideService.tideData.isEmpty {
                Task {
                    await tideService.fetchExtendedPredictions(days: 30)
                }
            }
        }
        // ⚠️ On observe une CLÉ qui inclut les COEFFICIENTS (pas seulement le `.count`) :
        // après une recalibration/ancrage, le nombre d'extrema ne change pas mais les coef si
        // → sans ça, le calendrier gardait des coefficients périmés (« se rafraîchit mal »).
        .onChange(of: calendarRefreshKey) { _, _ in updateCachedDays() }
        .onChange(of: tideService.selectedPort?.id) { _, _ in
            // Nouveau port → on revient sur aujourd'hui ET on RECALCULE l'étendu pour CE port.
            // (Avant : l'étendu n'était re-fetché que s'il était vide → le calendrier gardait
            //  les marées de l'ancien port = « ne se rafraîchit pas au changement de port ».)
            selectedDate = Date()
            currentMonth = Date()
            updateCachedDays()
            Task { await tideService.fetchExtendedPredictions(days: 30) }
        }
        .onChange(of: selectedDate) { _, _ in updateCachedDays() }
    }

    /// Signature combinant comptes + coefficients → change dès qu'une donnée OU un coef bouge.
    private var calendarRefreshKey: Int {
        var hasher = Hasher()
        hasher.combine(tideService.tideData.count)
        hasher.combine(tideService.extendedTideData.count)
        for t in tideService.tideData where t.coefficient != nil { hasher.combine(t.coefficient!) }
        for t in tideService.extendedTideData where t.coefficient != nil { hasher.combine(t.coefficient!) }
        return hasher.finalize()
    }

    // MARK: - Boutons de barre (export à gauche, J+30 à droite — titre au centre)
    @ViewBuilder
    private var exportToolbarButton: some View {
        // Export / partage du planning.
            if let port = tideService.selectedPort, !tideService.tideData.isEmpty {
                ExportButton(
                    portName: port.name,
                    tideData: tideService.tideData,
                    tideState: TideCalculator.currentState(at: Date(), sortedTides: tideService.tideData),
                    marineConditions: MarineWeatherService.shared.currentConditions,
                    portTimeZone: portTimeZone
                )
            }
    }

    @ViewBuilder
    private var extendedToolbarButton: some View {
            // Bouton Prédictions étendues (Premium)
            Button {
                HapticManager.shared.impact(.medium)
                if PremiumManager.shared.canUseExtendedForecast {
                    withAnimation(DS.defaultSpring) {
                        showExtended = true
                    }
                } else {
                    showPremiumPaywall = true
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.scaled(size: DS.fontFootnote))
                    Text("J+30")
                        .font(.scaled(size: DS.fontFootnote, weight: .bold))
                }
                .foregroundStyle(Color.tideLow)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
    }

    // MARK: - Grille calendrier
    private var calendarGrid: some View {
        VStack(spacing: DS.spacingSM) {
            // Navigation mois
            HStack {
                Button {
                    HapticManager.shared.impact(.light)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
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
                .accessibilityLabel("Mois précédent")
                .disabled(!canGoToPreviousMonth)   // pas de navigation vers un mois entièrement passé

                Spacer()

                Text(dateFormatter.string(from: currentMonth).capitalized)
                    .font(.scaled(size: DS.fontBody, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    HapticManager.shared.impact(.light)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
                    }
                } label: {
                    Image(systemName: "chevron.right")
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
                .accessibilityLabel("Mois suivant")
            }

            // Jours de la semaine
            HStack(spacing: 0) {
                ForEach(["Dim", "Lun", "Mar", "Mer", "Jeu", "Ven", "Sam"], id: \.self) { day in
                    Text(day)
                        .font(.scaled(size: DS.fontCaption2 + 1, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)

            // Grille des jours
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                    if let date = date {
                        let dayStart = calendar.startOfDay(for: date)
                        let isPast = dayStart < calendar.startOfDay(for: Date())
                        DayCell(
                            date: date,
                            portTimeZone: portTimeZone,
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            isToday: calendar.isDateInToday(date),
                            isPast: isPast,
                            hasTides: cachedAllTideDays.contains(dayStart),
                            isPredicted: !cachedShomDays.contains(dayStart) && cachedAllTideDays.contains(dayStart),
                            coefficient: cachedDayCoefficients[dayStart]
                        )
                        .onTapGesture {
                            guard !isPast else { return }   // jours passés : non sélectionnables
                            HapticManager.shared.impact(.light)
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedDate = date
                            }
                        }
                    } else {
                        Color.clear
                            .frame(height: 36)
                    }
                }
            }

            // Légende coefficients
            if !cachedDayCoefficients.isEmpty {
                coefficientLegend
            }
        }
        // Sans cadre — même DA aérée que la vue Aujourd'hui
        .padding(.horizontal, DS.pagePadding)
    }

    // MARK: - Légende coefficients
    private var coefficientLegend: some View {
        HStack(spacing: DS.spacingLG) {
            ForEach([
                ("20", Color.green),
                ("55", Color.yellow),
                ("80", Color.orange),
                ("100", Color.red)
            ], id: \.0) { label, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(color.opacity(0.4), lineWidth: 0.5)
                        )
                        .frame(width: 10, height: 10)
                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                }
            }
        }
        .padding(.top, DS.spacingXS)
    }

    // MARK: - Section du jour sélectionné
    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: DS.spacingMD) {
            // En-tête du jour
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDateFormatted)
                    .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                if isPredicted(date: selectedDate) {
                    HStack(spacing: DS.spacingXS) {
                        Image(systemName: "sparkles")
                            .font(.scaled(size: DS.fontCaption2))
                        Text("Prédiction")
                            .font(.scaled(size: DS.fontCaption2 + 1, weight: .semibold))
                    }
                    .foregroundStyle(Color.tideLow)
                    .padding(.horizontal, DS.spacingSM)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.tideLow.opacity(0.12))
                    )
                }
            }

            // Courbe SIGNATURE du jour sélectionné (même DA que Today/Carte) :
            // heures sur les extrema, trail + point « maintenant » si le jour est en cours.
            MiniMapTideCurve(
                tideData: tideService.allTideData,
                portTimeZone: portTimeZone,
                day: selectedDate
            )
            .frame(height: 96)
            .padding(.horizontal, -DS.pagePadding)   // bord à bord, comme la Carte

            // Liste des marées — sans cadre, posée sur le fond
            VStack(spacing: 0) {
                ForEach(Array(cachedTidesForSelectedDate.enumerated()), id: \.element.id) { index, tide in
                    CalendarTideRow(tide: tide, portTimeZone: portTimeZone)

                    if index < cachedTidesForSelectedDate.count - 1 {
                        Divider()
                            .overlay(Color.glassHighlight.opacity(0.06))
                    }
                }
            }
        }
        .padding(.horizontal, DS.pagePadding)
        .padding(.bottom, 40)
    }

    // MARK: - État vide
    private var emptyStateSection: some View {
        VStack(spacing: DS.spacingSM) {
            Image(systemName: "water.waves.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("Aucune marée disponible")
                .font(.scaled(size: DS.fontSubheadline, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.bottom, 80)
    }

    // MARK: - Formatage date sélectionnée
    private var selectedDateFormatted: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: selectedDate).capitalized
    }

    // MARK: - Cache des jours
    private func updateCachedDays() {
        cachedShomDays = Set(tideService.tideData.map { calendar.startOfDay(for: $0.date) })
        cachedAllTideDays = Set(tideService.allTideData.map { calendar.startOfDay(for: $0.date) })
        cachedTidesForSelectedDate = tideService.allTideData
            .filter { calendar.isDate($0.date, inSameDayAs: selectedDate) }

        // Coefficient max par jour pour la colorisation
        var coeffsByDay: [Date: Int] = [:]
        for tide in tideService.allTideData {
            guard let coef = tide.coefficient else { continue }
            let day = calendar.startOfDay(for: tide.date)
            if let existing = coeffsByDay[day] {
                coeffsByDay[day] = max(existing, coef)
            } else {
                coeffsByDay[day] = coef
            }
        }
        cachedDayCoefficients = coeffsByDay
    }

    // MARK: - Jours du mois
    private var daysInMonth: [Date?] {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth)),
              let range = calendar.range(of: .day, in: .month, for: currentMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: startOfMonth)
        let leadingEmptyDays = firstWeekday - 1

        var days: [Date?] = Array(repeating: nil, count: leadingEmptyDays)

        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: startOfMonth) {
                days.append(date)
            }
        }

        // Compléter la dernière ligne
        while days.count % 7 != 0 {
            days.append(nil)
        }

        return days
    }

    private func hasTidesFor(date: Date) -> Bool {
        cachedAllTideDays.contains(calendar.startOfDay(for: date))
    }

    private func isPredicted(date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        return !cachedShomDays.contains(day) && cachedAllTideDays.contains(day)
    }
}

// MARK: - Cellule jour
struct DayCell: View, Equatable {
    let date: Date
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    let isSelected: Bool
    let isToday: Bool
    var isPast: Bool = false
    let hasTides: Bool
    var isPredicted: Bool = false
    var coefficient: Int? = nil

    private var calendar: Calendar { Calendar.inTimeZone(portTimeZone) }

    static func == (lhs: DayCell, rhs: DayCell) -> Bool {
        lhs.date == rhs.date && lhs.portTimeZone == rhs.portTimeZone &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isToday == rhs.isToday && lhs.isPast == rhs.isPast && lhs.hasTides == rhs.hasTides &&
        lhs.isPredicted == rhs.isPredicted && lhs.coefficient == rhs.coefficient
    }

    private var coeffColor: Color? {
        guard let c = coefficient else { return nil }
        return Color.coefficientColor(c)
    }

    var body: some View {
        ZStack {
            // Fond selon état
            if isSelected {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isPredicted ? [.purple, .blue] : [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: (isPredicted ? Color.purple : Color.cyan).opacity(0.4), radius: 6)
            } else if let color = coeffColor {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(color.opacity(0.3), lineWidth: 0.5)
                    )
            }

            // Contour aujourd'hui
            if isToday && !isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.cyan, lineWidth: 1.5)
            }

            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.scaled(size: DS.fontFootnote, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : (isToday ? .cyan : Color(.label)))

                if let c = coefficient, !isSelected {
                    Text("\(c)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(coeffColor ?? .gray)
                } else if hasTides {
                    Circle()
                        .fill(isSelected ? Color.glassHighlight.opacity(0.8) : (isPredicted ? Color.purple.opacity(0.7) : Color.cyan.opacity(0.7)))
                        .frame(width: 3, height: 3)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
        }
        .frame(height: 36)
        .opacity(isPast ? 0.3 : 1)   // jours passés grisés (marées passées non pertinentes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jour \(calendar.component(.day, from: date))\(isToday ? ", aujourd'hui" : "")")
        .accessibilityValue(coefficient.map { "Coefficient \($0)" } ?? (hasTides ? "Marées disponibles" : "Pas de données"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Ligne marée calendrier
struct CalendarTideRow: View {
    let tide: TideData
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    // Système d'unités de l'utilisateur (m/ft) — le calendrier l'ignorait (hauteurs en mètres
    // affichées même en impérial). On observe le singleton pour convertir + suffixe correct.
    @ObservedObject private var themeManager = ThemeManager.shared

    private func formatTime(_ date: Date) -> String {
        CachedDateFormatter.make("HH:mm", timeZone: portTimeZone).string(from: date)
    }

    private var tideColor: Color {
        tide.isHighTide ? .tideHigh : .tideLow
    }

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            // Icône type
            Image(systemName: tide.isHighTide ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(tideColor)

            // Heure + type
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(tide.date))
                    .font(.scaled(size: DS.fontBody, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                Text(tide.isHighTide ? "Pleine mer" : "Basse mer")
                    .font(.scaled(size: DS.fontCaption, weight: .medium))
                    .foregroundStyle(tideColor.opacity(0.8))
            }

            Spacer()

            // Coefficient — placé à GAUCHE de la hauteur
            if let coef = tide.coefficient {
                Text("\(coef)")
                    .font(.scaled(size: DS.fontCaption, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.coefficientColor(coef).opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.coefficientColor(coef).opacity(0.3), lineWidth: 0.5)
                            )
                    )
            }

            // Hauteur — colonne à largeur fixe, alignée à droite (toutes les rangées s'alignent)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: themeManager.measureSystem == .imperial ? "%.1f" : "%.2f",
                            UnitFormatter.heightValue(tide.height, system: themeManager.measureSystem)))
                    .font(.scaled(size: DS.fontBody, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(themeManager.measureSystem.heightUnit)
                    .font(.scaled(size: DS.fontCaption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, DS.spacingMD)
        .padding(.vertical, DS.spacingMD)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tide.isHighTide ? "Pleine mer" : "Basse mer") à \(formatTime(tide.date)), \(UnitFormatter.height(tide.height, system: themeManager.measureSystem, decimals: 1))\(tide.coefficient.map { ", coefficient \($0)" } ?? "")")
    }
}

#Preview {
    ZStack {
        AppBackground()
        CalendarView(tideService: TideService())
    }
    .environmentObject(ThemeManager.shared)
}

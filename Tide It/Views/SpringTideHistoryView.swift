import SwiftUI

struct SpringTideHistoryView: View {
    @StateObject private var tracker = SpringTideTracker.shared
    @EnvironmentObject private var tideService: TideService
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: SpringTideCategory?
    @State private var selectedPortFilter: String?

    private var filteredRecords: [SpringTideRecord] {
        var result = tracker.records
        if let cat = selectedCategory {
            result = result.filter { $0.category == cat }
        }
        if let port = selectedPortFilter {
            result = result.filter { $0.portId == port }
        }
        return result
    }

    private var uniquePorts: [(id: String, name: String)] {
        var seen = Set<String>()
        return tracker.records.compactMap { record in
            guard !seen.contains(record.portId) else { return nil }
            seen.insert(record.portId)
            return (id: record.portId, name: record.portName)
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.spacingLG) {
                    if tracker.records.isEmpty {
                        emptyState
                    } else {
                        statsSection
                        filtersSection
                        recordsList
                    }
                }
                .padding(.horizontal, DS.spacingLG)
                .padding(.bottom, DS.spacingXXL)
            }
            .appBackground()
            .navigationTitle(Text("Grandes marées"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DS.spacingLG) {
            Spacer().frame(height: 80)

            Image(systemName: "water.waves")
                .font(.system(size: 56))
                .foregroundStyle(Color.tideHigh.opacity(0.6))

            Text("Aucune grande marée enregistrée")
                .font(.scaled(size: DS.fontHeadline, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Les grandes marées (coefficient ≥ 90) seront automatiquement enregistrées lorsque vous consultez les marées d'un port.")
                .font(.scaled(size: DS.fontSubheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.spacingXL)

            Spacer()
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(spacing: DS.spacingSM) {
            Text("STATISTIQUES")
                .sectionHeaderStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

            let stats = tracker.stats

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: DS.spacingSM) {
                statCard(
                    value: "\(stats.totalCount)",
                    label: String(localized: "Total"),
                    icon: "water.waves",
                    color: .tideMid
                )
                statCard(
                    value: "\(stats.maxCoefficient)",
                    label: String(localized: "Coef max"),
                    icon: "arrow.up.circle.fill",
                    color: .red
                )
                statCard(
                    value: UnitFormatter.height(stats.maxTidalRange, system: themeManager.measureSystem),
                    label: String(localized: "Marnage max"),
                    icon: "ruler",
                    color: .tideHigh
                )
            }

            if let topPort = stats.mostFrequentPort {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(Color.tideLow)
                    Text("Port le plus suivi : \(topPort)")
                        .font(.scaled(size: DS.fontFootnote))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, DS.spacingXS)
            }
        }
    }

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: DS.spacingXS) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontTitle3))
                .foregroundStyle(color)
            Text(value)
                .font(.scaled(size: DS.fontHeadline, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.scaled(size: DS.fontCaption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.spacingSM)
    }

    // MARK: - Filters

    private var filtersSection: some View {
        VStack(spacing: DS.spacingSM) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.spacingSM) {
                    filterChip(
                        label: String(localized: "Tous"),
                        isSelected: selectedCategory == nil,
                        color: .tideMid
                    ) {
                        selectedCategory = nil
                    }

                    ForEach(SpringTideCategory.allCases.reversed(), id: \.self) { category in
                        filterChip(
                            label: category.label,
                            isSelected: selectedCategory == category,
                            color: categoryColor(category)
                        ) {
                            selectedCategory = selectedCategory == category ? nil : category
                        }
                    }
                }
            }

            if uniquePorts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.spacingSM) {
                        filterChip(
                            label: String(localized: "Tous les ports"),
                            isSelected: selectedPortFilter == nil,
                            color: .tideMid
                        ) {
                            selectedPortFilter = nil
                        }

                        ForEach(uniquePorts, id: \.id) { port in
                            filterChip(
                                label: port.name,
                                isSelected: selectedPortFilter == port.id,
                                color: .tideLow
                            ) {
                                selectedPortFilter = selectedPortFilter == port.id ? nil : port.id
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterChip(label: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.scaled(size: DS.fontCaption, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, DS.spacingMD)
                .padding(.vertical, DS.spacingSM - 2)
                .background(
                    Capsule()
                        .fill(isSelected ? color.opacity(0.25) : Color.glassHighlight.opacity(0.08))
                )
                .foregroundStyle(isSelected ? color : .secondary)
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? color.opacity(0.5) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Records List

    private var recordsList: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                Text("\(filteredRecords.count) grandes marées")
                    .sectionHeaderStyle()
                Spacer()
            }

            if filteredRecords.isEmpty {
                Text("Aucun résultat avec ces filtres")
                    .font(.scaled(size: DS.fontSubheadline))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.spacingXXL)
            } else {
                LazyVStack(spacing: DS.spacingSM) {
                    ForEach(filteredRecords) { record in
                        springTideRow(record)
                    }
                }
            }
        }
    }

    private func springTideRow(_ record: SpringTideRecord) -> some View {
        HStack(spacing: DS.spacingMD) {
            // Badge coefficient
            VStack(spacing: 2) {
                Text("\(record.coefficient)")
                    .font(.scaled(size: DS.fontTitle3, weight: .bold, design: .rounded))
                    .foregroundStyle(categoryColor(record.category))
                Text("coef")
                    .font(.scaled(size: DS.fontCaption2))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52)

            // Infos
            VStack(alignment: .leading, spacing: DS.spacingXS - 2) {
                Text(record.portName)
                    .font(.scaled(size: DS.fontBody, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: DS.spacingSM) {
                    Label(
                        record.date.formatted(.dateTime.day().month(.abbreviated).year()),
                        systemImage: "calendar"
                    )
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.secondary)

                    Label(
                        record.category.label,
                        systemImage: "water.waves"
                    )
                    .font(.scaled(size: DS.fontCaption, weight: .medium))
                    .foregroundStyle(categoryColor(record.category))
                }
            }

            Spacer()

            // Marnage
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.scaled(size: DS.fontCaption2))
                    Text(UnitFormatter.height(record.tidalRange, system: themeManager.measureSystem))
                        .font(.scaled(size: DS.fontSubheadline, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.tideHigh)

                Text(String(format: "%.1f → %.1f", locale: Locale.current, record.highTideHeight, record.lowTideHeight))
                    .font(.scaled(size: DS.fontCaption2))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.spacingSM)
    }

    // MARK: - Helpers

    private func categoryColor(_ category: SpringTideCategory) -> Color {
        switch category {
        case .notable: return .yellow
        case .strong: return .orange
        case .veryStrong: return .red
        case .exceptional: return .pink
        }
    }
}

#Preview {
    SpringTideHistoryView()
        .preferredColorScheme(.dark)
}

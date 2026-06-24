//
//  ColorExtensions.swift
//  Tide It
//
//  Design System unifié — Couleurs, typographie, espacements, modifiers
//

import SwiftUI
import os.log

// MARK: - Logger global (remplace tous les print())
let appLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "seb.Tide-It", category: "General")

// MARK: - Design Tokens
/// Centralisation de toutes les constantes design pour garantir l'homogénéité
enum DS {
    // MARK: Spacing
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 20
    static let spacingXXL: CGFloat = 24

    // MARK: Corner Radius
    static let radiusSM: CGFloat = 10
    static let radiusMD: CGFloat = 14
    static let radiusLG: CGFloat = 20
    static let radiusXL: CGFloat = 24

    // MARK: Font Sizes
    static let fontCaption2: CGFloat = 9
    static let fontCaption: CGFloat = 11
    static let fontFootnote: CGFloat = 12
    static let fontSubheadline: CGFloat = 13
    static let fontCallout: CGFloat = 14
    static let fontBody: CGFloat = 15
    static let fontHeadline: CGFloat = 16
    static let fontTitle3: CGFloat = 18
    static let fontTitle2: CGFloat = 20
    static let fontTitle: CGFloat = 24
    static let fontLargeTitle: CGFloat = 28

    // MARK: Section Header Style
    static let sectionHeaderSize: CGFloat = 13
    static let sectionHeaderWeight: Font.Weight = .bold
    static let sectionHeaderTracking: CGFloat = 0.3
    static let sectionHeaderOpacity: Double = 0.78 // était 0.6 — remonté pour WCAG AA sur dark bg

    // MARK: Page Header
    static let pageHeaderSize: CGFloat = 24

    // MARK: Horizontal Page Padding
    static let pagePadding: CGFloat = 20

    // MARK: Animation
    static let springResponse: Double = 0.35
    static let springDamping: Double = 0.75
    static var defaultSpring: Animation {
        .spring(response: springResponse, dampingFraction: springDamping)
    }
}

// MARK: - Color Extension
extension Color {

    // MARK: - Tide Colors (flashy, identiques dark/light — l'adaptation se fait via opacités)
    static let tideHigh = Color.cyan
    static let tideLow = Color.purple
    static let tideMid = Color.blue

    // Variantes profondes pour texte sur fond clair (light mode labels)
    static let tideHighDeep = Color(red: 0.0, green: 0.55, blue: 0.7)
    static let tideLowDeep = Color(red: 0.45, green: 0.2, blue: 0.75)
    static let tideMidDeep = Color(red: 0.15, green: 0.35, blue: 0.75)

    // MARK: - Background Colors (adaptatifs light/dark)
    static let backgroundPrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.02, green: 0.02, blue: 0.08, alpha: 1)
            : UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    })
    static let backgroundSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.05, green: 0.05, blue: 0.15, alpha: 1)
            : UIColor(red: 0.86, green: 0.90, blue: 0.96, alpha: 1)
    })
    static let backgroundTertiary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.05, green: 0.02, blue: 0.15, alpha: 1)
            : UIColor(red: 0.84, green: 0.87, blue: 0.94, alpha: 1)
    })

    // MARK: - Glass Highlight (white en dark, black en light)
    static let glassHighlight = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    })

    // MARK: - Card Background (solid pour light mode)
    static let cardBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.06)
            : UIColor(white: 1, alpha: 0.85)
    })

    // MARK: - Card Border
    static let cardBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.12)
            : UIColor(red: 0.75, green: 0.78, blue: 0.85, alpha: 0.5)
    })

    // MARK: - Graph Curve Colors (adaptatifs)
    static let curveMidBlue = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1)
            : UIColor(red: 0.15, green: 0.4, blue: 0.85, alpha: 1)
    })
    static let curveMidPurple = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 1)
            : UIColor(red: 0.45, green: 0.25, blue: 0.85, alpha: 1)
    })
    static let curveGlowBlue = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1)
            : UIColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1)
    })
    static let curveGlowPink = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.8, green: 0.2, blue: 0.8, alpha: 1)
            : UIColor(red: 0.65, green: 0.1, blue: 0.65, alpha: 1)
    })

    // MARK: - Coefficient Colors (unified)
    static func coefficientColor(_ coefficient: Int) -> Color {
        switch coefficient {
        case ..<45:   return .green
        case 45..<70: return .yellow
        case 70..<95: return .orange
        default:      return .red
        }
    }

    // MARK: - Gradients
    static let tideGradient = LinearGradient(
        colors: [.tideHigh, .tideMid, .tideLow],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let backgroundGradient = LinearGradient(
        colors: [.backgroundPrimary, .backgroundSecondary, .backgroundPrimary],
        startPoint: .top,
        endPoint: .bottom
    )

    static let accentGradient = LinearGradient(
        colors: [.cyan, .blue],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let secondaryGradient = LinearGradient(
        colors: [.purple, .blue],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Light Mode Background Colors
extension Color {
    /// Fond clair principal — blanc légèrement bleuté
    static let lightPrimary = Color(red: 0.95, green: 0.96, blue: 0.98)
    /// Fond clair secondaire
    static let lightSecondary = Color(red: 0.92, green: 0.94, blue: 0.97)
    /// Fond clair tertiaire
    static let lightTertiary = Color(red: 0.95, green: 0.96, blue: 0.98)
}

// MARK: - Shared Background View (DRY)
struct AppBackground: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: backgroundColors,
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var backgroundColors: [Color] {
        if colorScheme == .light {
            return [.lightPrimary, .lightSecondary, .lightTertiary]
        }
        return [.backgroundPrimary, .backgroundSecondary, .backgroundPrimary]
    }
}

// MARK: - Adaptive Card Modifiers

private struct SectionCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
            )
        } else {
            content.background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [Color.glassHighlight.opacity(0.15), Color.glassHighlight.opacity(0.05), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [Color.glassHighlight.opacity(0.25), Color.glassHighlight.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
        }
    }
}

private struct GlassBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.9))
                    .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
            )
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.glassHighlight.opacity(0.1), lineWidth: 0.5)
                    )
            )
        }
    }
}

private struct GlossyBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.08), radius: 14, y: 5)
            )
        } else {
            content.background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [Color.glassHighlight.opacity(0.2), Color.glassHighlight.opacity(0.05), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [Color.glassHighlight.opacity(0.3), Color.glassHighlight.opacity(0.1), Color.glassHighlight.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
        }
    }
}

// MARK: - View Modifiers

extension View {
    /// Fond de page standard (remplace le gradient dupliqué partout)
    func appBackground() -> some View {
        self.background { AppBackground() }
    }

    /// Carte de section — glass en dark, carte blanche avec ombre en light
    func sectionCard(cornerRadius: CGFloat = DS.radiusXL) -> some View {
        self.modifier(SectionCardModifier(cornerRadius: cornerRadius))
    }

    /// Fond glass simple avec bordure subtile
    func glassBackground(cornerRadius: CGFloat = DS.radiusLG) -> some View {
        self.modifier(GlassBackgroundModifier(cornerRadius: cornerRadius))
    }

    /// Fond glossy riche (pour les sections premium)
    func glossyBackground(cornerRadius: CGFloat = DS.radiusLG) -> some View {
        self.modifier(GlossyBackgroundModifier(cornerRadius: cornerRadius))
    }

    /// Section header label unifié (ex: "Mes alertes", "Ports", "Données")
    func sectionHeaderStyle() -> some View {
        self
            .font(.system(size: DS.sectionHeaderSize, weight: DS.sectionHeaderWeight))
            .foregroundStyle(.secondary)
            .tracking(DS.sectionHeaderTracking)
    }

    /// Titre de page unifié (ex: "Alertes", "Calendrier", "Réglages")
    func pageHeaderStyle() -> some View {
        self
            .font(.system(size: DS.pageHeaderSize, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
    }

    /// Presentation background pour les sheets (unifié). `preferredColorScheme` est appliqué
    /// ICI car les sheets n'héritent PAS du `preferredColorScheme` du présentateur → sans ça,
    /// changer le thème ne rafraîchissait pas la feuille ouverte (ex. Réglages). Réévalué à
    /// chaque rendu du présentateur (qui observe ThemeManager) → réactif au changement de thème.
    func sheetBackground() -> some View {
        self
            .preferredColorScheme(ThemeManager.shared.resolvedColorScheme)
            .presentationBackground {
                AppBackground()
                    .environmentObject(ThemeManager.shared)
            }
    }

    /// Staggered cascade entrance for dashboard cards
    func staggeredAppearance(index: Int, appeared: Bool) -> some View {
        modifier(StaggeredAppearance(index: index, appeared: appeared))
    }
}

// MARK: - Couleur de grade surf (source UNIQUE, partagée carte ↔ Today)

extension SurfGrade {
    /// Couleur d'affichage du grade — SOURCE UNIQUE pour la pastille carte ET TodayView, afin que
    /// les deux ne divergent jamais. ⚠️ Ne PAS dériver de `colorName` (data-only) : il mappe
    /// firing→« purple » / oversized→« red », ce qui contredirait ce mapping UI.
    var swiftUIColor: Color {
        switch self {
        case .unknown:   return .gray
        case .flat:      return Color.tideHigh
        case .clean:     return .green
        case .firing:    return Color.tideLow
        case .oversized: return .orange
        }
    }
}

/// Entrée en cascade des cards. Respecte « Réduire les animations » : simple fondu
/// instantané (ni glissement, ni mise à l'échelle, ni délai en escalier).
private struct StaggeredAppearance: ViewModifier {
    let index: Int
    let appeared: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: (appeared || reduceMotion) ? 0 : 25)
            .scaleEffect((appeared || reduceMotion) ? 1 : 0.97)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * 0.06),
                value: appeared
            )
    }
}

// MARK: - Liquid Glass (contrôles flottants)

extension View {
    /// Verre liquide : effet natif iOS 26 (`glassEffect`), repli « verre » ultraThinMaterial
    /// + liseré sur les OS antérieurs. Utilisé par la barre de contrôle flottante.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                // glassHighlight s'adapte (blanc en sombre, noir en clair) → liseré visible
                // dans les DEUX modes (le blanc fixe était invisible en mode clair).
                .overlay(shape.stroke(Color.glassHighlight.opacity(0.18), lineWidth: 1))
        }
    }
}

// MARK: - Composants de liste ouverte (DA « sans cadre »)

/// Sélecteur segmenté SOULIGNÉ (texte + trait d'accent) — signature des vues dé-cadrées.
/// Un seul style pour toute l'app (Favoris, Activités…).
struct UnderlineSegments: View {
    let titles: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    var accent: Color = .cyan

    var body: some View {
        HStack(spacing: 26) {
            ForEach(titles.indices, id: \.self) { i in
                let isSel = selectedIndex == i
                Button {
                    onSelect(i)
                } label: {
                    VStack(spacing: 6) {
                        Text(titles[i])
                            .font(.system(size: 15, weight: isSel ? .bold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(isSel ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        Capsule()
                            .fill(isSel ? accent : Color.clear)
                            .frame(height: 2.5)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Fin filet séparateur entre lignes ouvertes (remplace les cadres de carte).
struct OpenRowDivider: View {
    var leadingInset: CGFloat = 56

    var body: some View {
        Rectangle()
            // Filet adaptatif (blanc en sombre, noir en clair) — le blanc fixe à 0,07 était
            // totalement invisible sur fond clair.
            .fill(Color.glassHighlight.opacity(0.10))
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

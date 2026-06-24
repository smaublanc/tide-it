import SwiftUI
import StoreKit

struct ClipTideView: View {
    @EnvironmentObject private var service: ClipTideService
    @Environment(\.displayStoreKitOverlay) private var displayOverlay

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.15),
                    Color(red: 0.02, green: 0.02, blue: 0.08)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if service.isLoading {
                loadingView
            } else if let error = service.errorMessage {
                errorView(error)
            } else if service.tideData.isEmpty {
                welcomeView
            } else {
                tideContentView
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.cyan)
            Text("Chargement des marées…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .font(.headline)
                .foregroundStyle(.primary)
            getFullAppButton
        }
    }

    // MARK: - Welcome (no port scanned)

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "water.waves")
                .font(.system(size: 64))
                .foregroundStyle(.cyan.opacity(0.7))

            Text("Tide It")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text("Scannez un QR code ou un lien pour voir les marées d'un port en temps réel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            getFullAppButton
                .padding(.bottom, 40)
        }
    }

    // MARK: - Tide Content

    private var tideContentView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 4) {
                    Text(service.portName)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Marées du jour")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Current state indicator
                if let nextTide = nextUpcomingTide {
                    currentStateCard(nextTide: nextTide)
                }

                // Tide list
                VStack(spacing: 12) {
                    ForEach(service.tideData) { tide in
                        tideRow(tide)
                    }
                }
                .padding(.horizontal, 16)

                // Get full app CTA
                Spacer(minLength: 20)
                getFullAppButton
                    .padding(.bottom, 32)
            }
        }
    }

    private func currentStateCard(nextTide: ClipTideService.ClipTideData) -> some View {
        let isRising = nextTide.isHighTide
        let timeRemaining = nextTide.date.timeIntervalSinceNow

        return VStack(spacing: 8) {
            HStack {
                Image(systemName: isRising ? "arrow.up" : "arrow.down")
                    .font(.title2)
                    .foregroundStyle(isRising ? .cyan : .purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRising ? "Marée montante" : "Marée descendante")
                        .font(.headline)
                    Text("Prochaine \(nextTide.isHighTide ? "pleine mer" : "basse mer") dans \(formatInterval(timeRemaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(SharedUnitFormatter.height(nextTide.height))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(nextTide.isHighTide ? .cyan : .purple)
                    if let coef = nextTide.coefficient {
                        Text("coef \(coef)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private func tideRow(_ tide: ClipTideService.ClipTideData) -> some View {
        HStack {
            // Tide type badge
            Image(systemName: tide.isHighTide ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(tide.isHighTide ? .cyan : .purple)

            VStack(alignment: .leading, spacing: 2) {
                Text(tide.isHighTide ? "Pleine mer" : "Basse mer")
                    .font(.subheadline.weight(.medium))
                Text(tide.date.formatted(.dateTime.hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(SharedUnitFormatter.height(tide.height, decimals: 2))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                if let coef = tide.coefficient {
                    Text("coef \(coef)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))
        )
        .opacity(tide.date < Date() ? 0.5 : 1.0)
    }

    // MARK: - Get Full App

    private var getFullAppButton: some View {
        Button {
            displayOverlay()
        } label: {
            HStack {
                Image(systemName: "arrow.down.app.fill")
                Text("Télécharger Tide It")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(.cyan.gradient)
            )
            .foregroundStyle(.black)
            .font(.body)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Helpers

    private var nextUpcomingTide: ClipTideService.ClipTideData? {
        service.tideData.first(where: { $0.date > Date() })
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        }
        return "\(minutes) min"
    }

    private func displayOverlay() {
        // StoreKit overlay se déclenche automatiquement pour les App Clips
        // après 8 secondes ou quand l'utilisateur interagit
    }
}

#Preview {
    let service = ClipTideService()
    ClipTideView()
        .environmentObject(service)
        .preferredColorScheme(.dark)
}

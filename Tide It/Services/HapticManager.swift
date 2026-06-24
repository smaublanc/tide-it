import UIKit

/// Gestionnaire centralisé des retours haptiques
final class HapticManager {
    static let shared = HapticManager()

    private init() {
        if UserDefaults.standard.object(forKey: "hapticFeedback") == nil {
            UserDefaults.standard.set(true, forKey: "hapticFeedback")
        }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "hapticFeedback")
    }

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    func selection() {
        guard isEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    // MARK: - Rich Haptic Patterns

    /// Double tap like a heartbeat (for favorites)
    func heartbeat() {
        guard isEnabled else { return }
        impact(.medium)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            impact(.light)
        }
    }

    /// Success sequence (for completed actions)
    func success() {
        guard isEnabled else { return }
        notification(.success)
    }

    /// Progressive pull feedback (e.g. pull-to-refresh)
    func progressivePull(progress: Double) {
        guard isEnabled else { return }
        let clamped = min(max(progress, 0), 1)
        if clamped < 0.33 {
            impact(.light)
        } else if clamped < 0.66 {
            impact(.medium)
        } else {
            impact(.heavy)
        }
    }

    /// Tide point reached (scrubbing over tide points)
    func tidePoint() {
        guard isEnabled else { return }
        impact(.rigid)
    }
}

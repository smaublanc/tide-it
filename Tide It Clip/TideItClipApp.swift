import SwiftUI

@main
struct TideItClipApp: App {
    @StateObject private var clipService = ClipTideService()

    var body: some Scene {
        WindowGroup {
            ClipTideView()
                .environmentObject(clipService)
                .preferredColorScheme(.dark)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    clipService.handleIncomingURL(url)
                }
        }
    }
}

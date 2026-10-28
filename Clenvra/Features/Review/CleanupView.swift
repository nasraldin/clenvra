import ClenvraKit
import SwiftUI

/// System Junk: the rule review, plus a separate, deliberate entry for browser history and cookies.
struct CleanupView: View {
    let environment: AppEnvironment

    @State private var isShowingBrowserData = false

    var body: some View {
        RuleReviewView(
            section: .cleanup, session: environment.cleanupSession,
            introduction:
                "Find caches, logs, crash reports, old installers and other files that apps recreate. Nothing is removed until you review it.",
            exclude: { environment.exclude($0) }
        ) {
            Divider()
            Button {
                isShowingBrowserData = true
            } label: {
                Text("Browser History & Cookies…")
            }
            .accessibilityIdentifier("cleanup.browserData")
        }
        .sheet(isPresented: $isShowingBrowserData) {
            BrowserDataSheet(session: environment.browserDataSession) { [ownership = environment.ownership] in
                ownership.state(of: $0)
            }
        }
    }
}

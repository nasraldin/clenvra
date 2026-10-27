import ClenvraKit
import SwiftUI

/// The Cleanup section: the rule review, plus a separate, deliberate entry for browser history and cookies.
struct CleanupView: View {
    let environment: AppEnvironment

    @State private var isShowingBrowserData = false

    var body: some View {
        RuleReviewView(section: .cleanup, session: environment.cleanupSession)
            .toolbar {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button {
                        isShowingBrowserData = true
                    } label: {
                        Label {
                            Text("History & Cookies…")
                        } icon: {
                            Image(systemName: "hand.raised")
                        }
                    }
                    .help(
                        Text(
                            "Review browser history, cookies, open tabs and site data. Removing cookies signs you out of websites."
                        )
                    )
                    .accessibilityIdentifier("cleanup.browserData")
                }
            }
            .sheet(isPresented: $isShowingBrowserData) {
                BrowserDataSheet(session: environment.browserDataSession) { [ownership = environment.ownership] in
                    ownership.state(of: $0)
                }
            }
    }
}

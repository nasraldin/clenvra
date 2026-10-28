import ClenvraKit
import SwiftUI

extension BrowserDataType {
    var title: LocalizedStringResource {
        switch self {
        case .history: "History"
        case .cookies: "Cookies"
        case .sessions: "Open Tabs & Sessions"
        case .siteData: "Site Data"
        }
    }

    /// What the user loses, written in the app (not the engine's English text) so it can be translated.
    var consequence: LocalizedStringResource {
        switch self {
        case .history: "Removes the list of pages you visited."
        case .cookies: "Signs you out of websites."
        case .sessions: "Closes the tabs you had open and loses the restore list."
        case .siteData: "Websites forget your settings and offline data."
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .cookies: "person.crop.circle.badge.xmark"
        case .sessions: "rectangle.on.rectangle"
        case .siteData: "tray.full"
        }
    }

    /// Display order: the least disruptive first.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension BrowserDataGroup {
    var size: Int64 { items.reduce(0) { $0 + $1.candidate.reclaimableSize } }

    /// Firefox and Zen keep bookmarks in the same file as history.
    static let bookmarksWarning: LocalizedStringResource =
        "Also removes bookmarks, which Firefox stores in the same file."
}

extension Browser {
    /// Folder names that identify this browser's data in a skipped path, matched as whole path components.
    private var pathMarkers: [String] {
        switch self {
        case .safari: ["/Library/Safari/", "/Containers/com.apple.Safari/", "/Library/Cookies/"]
        case .chrome: ["/Application Support/Google/Chrome/"]
        case .edge: ["/Application Support/Microsoft Edge/"]
        case .brave: ["/Application Support/BraveSoftware/Brave-Browser/"]
        case .arc: ["/Application Support/Arc/"]
        case .vivaldi: ["/Application Support/Vivaldi/"]
        case .opera: ["/Application Support/com.operasoftware.Opera/"]
        case .firefox: ["/Application Support/Firefox/"]
        case .zen: ["/Application Support/zen/"]
        }
    }

    /// The browser whose data folder contains a path the scan could not read.
    init?(skippedPath path: String) {
        let path = path + "/"
        guard let browser = Self.allCases.first(where: { $0.pathMarkers.contains { path.contains($0) } }) else {
            return nil
        }
        self = browser
    }
}

/// Confirmation that names every browser and data type about to be removed, and repeats what is lost.
struct ConfirmBrowserDataSheet: View {
    /// The groups with at least one selected item.
    let groups: [BrowserDataGroup]
    let count: Int
    let bytes: Int64
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Remove browser data?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
            }
            Text("Moves \(count) items (about \(bytes.formatted(.byteCount(style: .file)))) to the Trash.")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(browsers, id: \.self) { browser in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: browser.displayName)
                            .font(.headline)
                        Text(verbatim: typeList(for: browser))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(dataTypes, id: \.self) { type in
                    warning(Text(type.consequence))
                }
                if groups.contains(where: { $0.dataType == .history && $0.removesBookmarks }) {
                    warning(Text(BrowserDataGroup.bookmarksWarning))
                }
            }
            .font(.callout.weight(.semibold))

            Text("Every item is checked again just before it is moved. You can put items back from Activity.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                // Deliberately no default (Return) shortcut: this signs people out of websites.
                Button(role: .destructive, action: confirm) {
                    Text("Move to Trash")
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .accessibilityIdentifier("browserData.confirm")
    }

    private var browsers: [Browser] {
        let found = Set(groups.map(\.browser))
        return Browser.allCases.filter(found.contains)
    }

    private var dataTypes: [BrowserDataType] {
        // Sign-outs first: that is the consequence people most need to see.
        let found = Set(groups.map(\.dataType))
        return [.cookies, .siteData, .sessions, .history].filter(found.contains)
    }

    private func typeList(for browser: Browser) -> String {
        let types = Set(groups.filter { $0.browser == browser }.map(\.dataType))
        return types.sorted { $0.order < $1.order }
            .map { String(localized: $0.title) }
            .formatted(.list(type: .and))
    }

    private func warning(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

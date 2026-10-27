import ClenvraKit
import SwiftUI

/// Bytes formatted like Finder (decimal units), in the user's locale.
struct SizeText: View {
    let bytes: Int64

    var body: some View {
        Text(bytes, format: .byteCount(style: .file))
            .monospacedDigit()
    }
}

/// A filesystem path: always left-to-right (also inside Arabic UI), truncated in the middle, selectable.
struct PathText: View {
    let path: String

    var body: some View {
        Text(verbatim: path)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .environment(\.layoutDirection, .leftToRight)
            .help(Text(verbatim: path))
    }
}

/// Risk or status, always as icon + text + colour (never colour alone).
struct StatusBadge: View {
    let candidate: CleanupCandidate

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .labelStyle(.titleAndIcon)
    }

    private var title: LocalizedStringResource {
        switch candidate.status {
        case .available: candidate.risk == .safe ? "Safe" : "Review"
        case .inUse: "In use"
        case .systemManaged: "Managed by macOS"
        case .protected: "Protected"
        }
    }

    private var symbol: String {
        switch candidate.status {
        case .available: candidate.risk == .safe ? "checkmark.shield" : "exclamationmark.triangle"
        case .inUse: "app.badge.clock"
        case .systemManaged, .protected: "lock"
        }
    }

    private var tint: Color {
        switch candidate.status {
        case .available: candidate.risk == .safe ? .green : .orange
        case .inUse, .systemManaged, .protected: .secondary
        }
    }
}

extension CleanupCategory {
    var title: LocalizedStringResource {
        switch self {
        case .appCaches: "App Caches"
        case .logs: "Logs"
        case .crashReports: "Crash Reports"
        case .installers: "Installers & Disk Images"
        case .deviceBackups: "iPhone & iPad Backups"
        case .trash: "Trash"
        case .browserCaches: "Browser Caches"
        case .xcode: "Xcode"
        case .simulators: "Simulators"
        case .packageCaches: "Package Caches"
        case .projectArtifacts: "Project Build Folders"
        case .ideCaches: "Editor Caches"
        case .containers: "Containers & Virtual Machines"
        }
    }

    /// What regenerates and what the user loses.
    var explanation: LocalizedStringResource {
        switch self {
        case .appCaches: "Temporary files apps create to load faster. Apps rebuild them when needed."
        case .logs: "Diagnostic logs older than a week. Apps keep writing new ones."
        case .crashReports: "Reports from past app crashes, older than a week."
        case .installers: "Disk images and installer packages in Downloads. Check you no longer need them."
        case .deviceBackups: "Local backups of iPhone and iPad. Removing one deletes that backup."
        case .trash: "Items already in the Trash. Emptying it cannot be undone."
        case .browserCaches: "Cached web content. History, passwords and sign-ins are kept."
        case .xcode: "Build data and device support files. Xcode recreates them; the next build is slower."
        case .simulators: "Simulator caches and devices that no longer have a runtime."
        case .packageCaches: "Downloaded packages kept by package managers. They are downloaded again when needed."
        case .projectArtifacts:
            "Dependencies and build output inside your projects. Reinstall or rebuild to get them back."
        case .ideCaches: "Editor caches. Settings, extensions and workspaces are kept."
        case .containers: "Space used by container tools and virtual machines."
        }
    }

    var symbol: String {
        switch self {
        case .appCaches: "square.stack.3d.up"
        case .logs: "doc.text"
        case .crashReports: "exclamationmark.bubble"
        case .installers: "shippingbox"
        case .deviceBackups: "iphone"
        case .trash: "trash"
        case .browserCaches: "globe"
        case .xcode: "hammer"
        case .simulators: "ipad.and.iphone"
        case .packageCaches: "archivebox"
        case .projectArtifacts: "folder.badge.gearshape"
        case .ideCaches: "chevron.left.forwardslash.chevron.right"
        case .containers: "cube"
        }
    }
}

/// Used, purgeable and free space as one horizontal bar that fills from the leading edge.
struct CapacityBar: View {
    let volume: Volume

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Canvas { context, size in
            let total = Double(max(volume.totalCapacity, 1))
            let used = Double(volume.usedExcludingPurgeable) / total
            let purgeable = Double(min(volume.purgeableEstimate, volume.usedCapacity)) / total
            let background = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(background, with: .color(.secondary.opacity(0.25)))
            context.clip(to: background)
            let segments: [(start: Double, length: Double, color: Color)] = [
                (0, used, .accentColor), (used, min(purgeable, 1 - used), .orange),
            ]
            for segment in segments where segment.length > 0 {
                var x = segment.start * size.width
                let width = segment.length * size.width
                if layoutDirection == .rightToLeft { x = size.width - x - width }
                context.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(segment.color))
            }
        }
        .accessibilityHidden(true)
    }
}

extension Volume {
    /// Purgeable space is counted as used by macOS; the bar shows it as its own segment.
    var usedExcludingPurgeable: Int64 { max(0, usedCapacity - purgeableEstimate) }

    var symbol: String {
        switch kind {
        case .internal: "internaldrive"
        case .external: "externaldrive"
        case .network: "server.rack"
        case .diskImage: "opticaldiscdrive"
        case .other: "externaldrive.badge.questionmark"
        }
    }
}

extension FullDiskAccess {
    /// Privacy & Security › Full Disk Access in System Settings.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    /// Probes off the main thread; the probe touches the filesystem.
    static func currentStatus(home: String) async -> Status {
        await Task.detached { probe(paths: probePaths(home: home)) }.value
    }
}

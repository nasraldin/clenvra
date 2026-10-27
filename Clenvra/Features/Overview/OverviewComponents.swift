import ClenvraKit
import SwiftUI

extension Volume {
    /// Share of the volume macOS can make available, counting purgeable space as free (as macOS does when it needs room).
    var freeRatio: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(availableForImportantUsage ?? availableCapacity) / Double(totalCapacity)
    }
}

/// One volume: name, "X free of Y" (large for the startup disk), and a used / purgeable / free bar.
struct OverviewVolumeRow: View {
    let volume: Volume

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: volume.name).font(.headline)
                } icon: {
                    Image(systemName: volume.symbol)
                }
                Spacer()
                if volume.isRoot {
                    Text(volume.availableCapacity, format: .byteCount(style: .file))
                        .font(.largeTitle)
                        .monospacedDigit()
                    Text("free of \(volume.totalCapacity.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(
                        "\(volume.availableCapacity.formatted(.byteCount(style: .file))) free of \(volume.totalCapacity.formatted(.byteCount(style: .file)))"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            CapacityBar(volume: volume)
                .frame(height: 8)
                .accessibilityElement()
                .accessibilityLabel(
                    Text(
                        "Used \(volume.usedExcludingPurgeable.formatted(.byteCount(style: .file))), purgeable \(volume.purgeableEstimate.formatted(.byteCount(style: .file))), free \(volume.availableCapacity.formatted(.byteCount(style: .file)))"
                    ))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview.volume")
    }
}

/// A recommendation card: symbol, title, one-line explanation, size if any, and a button into the section.
struct OverviewRecommendationTile: View {
    let recommendation: OverviewRecommendations.Recommendation
    let navigate: (AppSection) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        title.font(.headline)
                    } icon: {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.hierarchical)
                    }
                    Spacer()
                    if let bytes = recommendation.bytes {
                        SizeText(bytes: bytes).font(.headline)
                    }
                }
                explanation
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    navigate(recommendation.destination.section)
                } label: {
                    Text("Show in \(Text(recommendation.destination.section.title))")
                }
                .accessibilityIdentifier("overview.recommendation.\(recommendation.id)")
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .padding(4)
        }
    }

    private var symbol: String {
        switch recommendation.kind {
        case .lowDiskSpace: "externaldrive.badge.exclamationmark"
        case .cleanupItems: "sparkles"
        case .developerItems: "hammer"
        case .toolCommand: "terminal"
        case .reviewItem: "exclamationmark.triangle"
        case .startupLeftovers: "power"
        case .securityAttention: "lock.shield"
        }
    }

    private var title: Text {
        switch recommendation.kind {
        case .lowDiskSpace: Text("Startup disk is almost full")
        case .cleanupItems: Text("Caches, logs and other junk")
        case .developerItems: Text("Developer build data")
        case .toolCommand(_, let name, _): Text(name)
        case .reviewItem: Text("Large item to review")
        case .startupLeftovers: Text("Startup items left behind")
        case .securityAttention: Text("Security setting needs attention")
        }
    }

    private var explanation: Text {
        switch recommendation.kind {
        case .lowDiskSpace(let ratio):
            Text(
                "Only \(ratio.formatted(.percent.precision(.fractionLength(0)))) is free. See what uses the most space."
            )
        case .cleanupItems(let count):
            Text("\(count) safe items that apps recreate when needed.")
        case .developerItems(let count):
            Text("\(count) safe items that your tools rebuild when needed.")
        case .toolCommand(_, _, let command):
            Text("The tool’s own command can shrink it: \u{2066}\(command)\u{2069}")
        case .reviewItem(let name):
            Text("\u{2068}\(name)\u{2069} is not selected automatically. Check whether you still need it.")
        case .startupLeftovers(let count):
            Text("\(count) startup items belong to apps that were removed.")
        case .securityAttention(let count):
            Text("\(count) security settings are off or need review.")
        }
    }
}

/// Memory pressure, startup-disk free share and battery condition on one line, with a way into System.
struct OverviewHealthLine: View {
    let health: SystemHealth?
    let startupVolume: Volume?
    let navigate: (AppSection) -> Void

    var body: some View {
        HStack(spacing: 18) {
            if let health {
                Label {
                    Text("Memory pressure: \(Text(pressureTitle(health.memoryPressure)))")
                } icon: {
                    Image(systemName: "memorychip")
                }
            }
            if let startupVolume {
                Label {
                    Text("\(startupVolume.freeRatio.formatted(.percent.precision(.fractionLength(0)))) of disk free")
                } icon: {
                    Image(systemName: "internaldrive")
                }
            }
            if let condition = health?.battery?.condition, health?.battery?.isPresent == true {
                Label {
                    Text("Battery: \(condition)")
                } icon: {
                    Image(systemName: "battery.75percent")
                }
            }
            Spacer()
            Button {
                navigate(.system)
            } label: {
                Text("Show in \(Text(AppSection.system.title))")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("overview.health.system")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.health")
    }

    private func pressureTitle(_ level: MemoryPressureLevel) -> LocalizedStringResource {
        switch level {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

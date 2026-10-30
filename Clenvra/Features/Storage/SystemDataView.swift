import ClenvraKit
import SwiftUI

/// The Space Map's "What's in System Data" popover: the parts of System Data that can be measured, each with a short
/// explanation and, where Clenvra can help, a link to the page that does. Read-only.
struct SystemDataView: View {
    let rootVolume: Volume?
    let navigate: (AppSection) -> Void

    @State private var breakdown: SystemDataBreakdown?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's in System Data")
                .font(.headline)
            Text("macOS counts these as System Data. Some of it frees itself; the rest Clenvra can help with.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let breakdown {
                rows(breakdown)
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 24)
            }
        }
        .padding(16)
        .frame(width: 380)
        .accessibilityIdentifier("storage.systemData")
        .task {
            breakdown = await SystemDataReader.read(runner: ProcessCommandRunner(), rootVolume: rootVolume)
        }
    }

    @ViewBuilder private func rows(_ breakdown: SystemDataBreakdown) -> some View {
        SystemDataRow(
            title: "Swap", symbol: "memorychip", value: sizeText(breakdown.swapUsed),
            explanation: "Memory macOS moved to disk; it shrinks after a restart.")
        SystemDataRow(
            title: "Local snapshots", symbol: "clock.arrow.circlepath",
            value: breakdown.localSnapshots.isEmpty
                ? Text("None") : Text("\(breakdown.localSnapshots.count) snapshots"),
            explanation: "Time Machine and macOS updates keep these copies of your disk for a while.",
            link: ("Open Snapshots", { navigate(.snapshots) }))
        SystemDataRow(
            title: "Simulator runtimes", symbol: "iphone", value: sizeText(breakdown.simulatorRuntimes),
            explanation: "Xcode needs these only to run apps in a simulator.",
            link: ("Open Developer Tools", { navigate(.developerTools) }))
        SystemDataRow(
            title: "Purgeable", symbol: "arrow.3.trianglepath", value: sizeText(breakdown.purgeable),
            explanation: "Space macOS frees by itself when needed.")
    }

    private func sizeText(_ bytes: Int64?) -> Text {
        guard let bytes, bytes > 0 else { return Text("None") }
        return Text(bytes.formatted(.byteCount(style: .file)))
    }
}

private struct SystemDataRow: View {
    let title: LocalizedStringResource
    let symbol: String
    let value: Text
    let explanation: LocalizedStringResource
    var link: (title: LocalizedStringResource, action: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer()
                    value
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    Button(action: link.action) {
                        Text(link.title)
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

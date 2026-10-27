import ClenvraKit
import SwiftUI

/// One capacity bar per mounted volume, plus the scan-target picker.
struct VolumeBarsView: View {
    let session: StorageSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(session.volumes) { volume in
                VolumeRow(volume: volume)
            }
            HStack {
                Picker(selection: targetBinding) {
                    ForEach(session.targets) { target in
                        TargetLabel(target: target).tag(target)
                    }
                } label: {
                    Text("Scan")
                }
                .fixedSize()
                .disabled(isScanning)
                .accessibilityIdentifier("storage.target")
                Spacer()
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = session.phase { return true }
        return session.phase == .deleting
    }

    private var targetBinding: Binding<ScanTarget> {
        Binding(
            get: { session.target },
            set: { target in
                guard target != session.target else { return }
                session.select(target)
                Task { await session.scan() }
            })
    }
}

private struct TargetLabel: View {
    let target: ScanTarget

    var body: some View {
        switch target.kind {
        case .home:
            Text("Home folder")
        case .startupVolume:
            Text("\(target.name) (whole disk)")
        case .volume:
            Text(verbatim: target.name)
        }
    }
}

private struct VolumeRow: View {
    let volume: Volume

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: volume.name).font(.headline)
                } icon: {
                    Image(systemName: volume.symbol)
                }
                Spacer()
                Text(
                    "\(volume.availableCapacity.formatted(.byteCount(style: .file))) available of \(volume.totalCapacity.formatted(.byteCount(style: .file)))"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            // The legend below states the same numbers; the bar itself is decorative for assistive technologies.
            CapacityBar(volume: volume)
                .frame(height: 10)
                .accessibilityHidden(true)
            HStack(spacing: 14) {
                legend(color: .accentColor) {
                    Text("Used \(volume.usedExcludingPurgeable.formatted(.byteCount(style: .file)))")
                }
                if volume.purgeableEstimate > 0 {
                    legend(color: .orange) {
                        Text("Purgeable ≈ \(volume.purgeableEstimate.formatted(.byteCount(style: .file)))")
                    }
                }
                legend(color: .secondary.opacity(0.25)) {
                    Text("Free \(volume.availableCapacity.formatted(.byteCount(style: .file)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func legend(color: Color, @ViewBuilder text: () -> Text) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            text()
        }
    }
}

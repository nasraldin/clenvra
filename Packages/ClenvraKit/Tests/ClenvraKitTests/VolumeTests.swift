import Foundation
import Testing

@testable import ClenvraKit

@Suite("Volume")
struct VolumeTests {
    @Test("internal volume classification from RawValues")
    func internalClassification() {
        let raw = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/"),
            name: "Macintosh HD",
            isInternal: true,
            isLocal: true,
            totalCapacity: 500_000_000_000
        )
        let volume = VolumeInventory.makeVolume(raw)
        #expect(volume?.kind == .internal)
    }

    @Test("external volume classification from RawValues (local + not internal)")
    func externalClassification() {
        let raw = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/FlashDrive"),
            name: "FlashDrive",
            isInternal: false,
            isLocal: true,
            isRemovable: true,
            isEjectable: true,
            totalCapacity: 64_000_000_000
        )
        let volume = VolumeInventory.makeVolume(raw)
        #expect(volume?.kind == .external)

        // Also when isInternal is nil (common for removable drives and disk images on macOS)
        let rawNilInternal = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/BackupDMG"),
            name: "BackupDMG",
            isInternal: nil,
            isLocal: true,
            isRemovable: true,
            isEjectable: true,
            totalCapacity: 32_000_000_000
        )
        let volumeNilInternal = VolumeInventory.makeVolume(rawNilInternal)
        #expect(volumeNilInternal?.kind == .external)
    }

    @Test("network volume classification from RawValues (not local or network filesystem)")
    func networkClassification() {
        let rawNotLocal = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Shared"),
            name: "Shared",
            isInternal: false,
            isLocal: false,
            totalCapacity: 2_000_000_000_000
        )
        let volumeNotLocal = VolumeInventory.makeVolume(rawNotLocal)
        #expect(volumeNotLocal?.kind == .network)

        // When filesystem is smbfs or nfs even if isLocal was unspecified
        let rawSMB = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/NAS"),
            name: "NAS",
            isInternal: nil,
            isLocal: nil,
            fileSystemTypeName: "smbfs",
            totalCapacity: 4_000_000_000_000
        )
        let volumeSMB = VolumeInventory.makeVolume(rawSMB)
        #expect(volumeSMB?.kind == .network)
    }

    @Test("disk image and fallback classifications from RawValues")
    func diskImageAndOtherClassification() {
        let rawDiskImage = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/VirtualDisk"),
            name: "VirtualDisk",
            isDiskImage: true,
            totalCapacity: 10_000_000_000
        )
        let volumeDiskImage = VolumeInventory.makeVolume(rawDiskImage)
        #expect(volumeDiskImage?.kind == .diskImage)

        let rawOther = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Unknown"),
            name: "Unknown",
            isInternal: nil,
            isLocal: nil,
            totalCapacity: 10_000_000_000
        )
        let volumeOther = VolumeInventory.makeVolume(rawOther)
        #expect(volumeOther?.kind == .other)
    }

    @Test("usedCapacity and purgeableEstimate arithmetic with valid usage")
    func capacityArithmeticNormal() {
        let raw = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Data"),
            name: "Data",
            isInternal: true,
            isLocal: true,
            totalCapacity: 500_000_000_000,
            availableCapacity: 200_000_000_000,
            availableForImportantUsage: 250_000_000_000
        )
        let volume = VolumeInventory.makeVolume(raw)
        #expect(volume != nil)
        #expect(volume?.usedCapacity == 300_000_000_000)
        #expect(volume?.purgeableEstimate == 50_000_000_000)
    }

    @Test("usedCapacity clamps to zero when available exceeds total capacity")
    func usedCapacityClamping() {
        let raw = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Sparse"),
            name: "Sparse",
            isInternal: true,
            isLocal: true,
            totalCapacity: 100_000_000_000,
            availableCapacity: 120_000_000_000
        )
        let volume = VolumeInventory.makeVolume(raw)
        #expect(volume != nil)
        #expect(volume?.usedCapacity == 0)
    }

    @Test("purgeableEstimate arithmetic with nil important-usage and lower important-usage")
    func purgeableEstimateEdgeCases() {
        let rawNilImportant = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/External"),
            name: "External",
            isInternal: false,
            isLocal: true,
            totalCapacity: 100_000_000_000,
            availableCapacity: 40_000_000_000,
            availableForImportantUsage: nil
        )
        let volumeNil = VolumeInventory.makeVolume(rawNilImportant)
        #expect(volumeNil?.purgeableEstimate == 0)

        let rawLowerImportant = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/External2"),
            name: "External2",
            isInternal: false,
            isLocal: true,
            totalCapacity: 100_000_000_000,
            availableCapacity: 50_000_000_000,
            availableForImportantUsage: 40_000_000_000
        )
        let volumeLower = VolumeInventory.makeVolume(rawLowerImportant)
        #expect(volumeLower?.purgeableEstimate == 0)
    }

    @Test("makeVolume returns nil when total capacity is missing or non-positive")
    func missingTotalCapacityReturnsNil() {
        let rawMissing = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Unknown"),
            name: "Unknown",
            totalCapacity: nil
        )
        #expect(VolumeInventory.makeVolume(rawMissing) == nil)

        let rawZero = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Unknown"),
            name: "Unknown",
            totalCapacity: 0
        )
        #expect(VolumeInventory.makeVolume(rawZero) == nil)
    }

    @Test("makeVolume returns nil for hidden or companion system volumes")
    func hiddenSystemVolumesReturnNil() {
        let rawPreboot = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/System/Volumes/Preboot"),
            name: "Preboot",
            isInternal: true,
            totalCapacity: 500_000_000_000
        )
        #expect(VolumeInventory.makeVolume(rawPreboot) == nil)

        let rawVM = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/System/Volumes/VM"),
            name: "VM",
            isInternal: true,
            totalCapacity: 500_000_000_000
        )
        #expect(VolumeInventory.makeVolume(rawVM) == nil)

        let rawRecovery = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/Recovery"),
            name: "Recovery",
            isInternal: true,
            totalCapacity: 500_000_000_000
        )
        #expect(VolumeInventory.makeVolume(rawRecovery) == nil)

        let rawNotBrowsable = VolumeInventory.RawValues(
            url: URL(fileURLWithPath: "/Volumes/HiddenSpecial"),
            name: "HiddenSpecial",
            isBrowsable: false,
            totalCapacity: 500_000_000_000
        )
        #expect(VolumeInventory.makeVolume(rawNotBrowsable) == nil)
    }

    @Test("sorting puts root volume first, then sorts by localized name")
    func sortingOrder() {
        let root = Volume(
            id: URL(fileURLWithPath: "/"),
            name: "Macintosh HD",
            kind: .internal,
            fileSystem: "apfs",
            isRoot: true,
            isReadOnly: false,
            isEjectable: false,
            totalCapacity: 500_000_000_000,
            availableCapacity: 200_000_000_000,
            availableForImportantUsage: nil
        )
        let betaVolume = Volume(
            id: URL(fileURLWithPath: "/Volumes/Beta"),
            name: "Beta",
            kind: .external,
            fileSystem: "exfat",
            isRoot: false,
            isReadOnly: false,
            isEjectable: true,
            totalCapacity: 100_000_000_000,
            availableCapacity: 50_000_000_000,
            availableForImportantUsage: nil
        )
        let alphaVolume = Volume(
            id: URL(fileURLWithPath: "/Volumes/Alpha"),
            name: "Alpha",
            kind: .external,
            fileSystem: "apfs",
            isRoot: false,
            isReadOnly: false,
            isEjectable: true,
            totalCapacity: 100_000_000_000,
            availableCapacity: 50_000_000_000,
            availableForImportantUsage: nil
        )

        let sorted = VolumeInventory.sort([betaVolume, root, alphaVolume])
        #expect(sorted.map(\.id.path) == ["/", "/Volumes/Alpha", "/Volumes/Beta"])
        #expect(sorted.map(\.name) == ["Macintosh HD", "Alpha", "Beta"])
    }

    @Test("integration: mountedVolumes contains exactly one root volume at / with totalCapacity > 0 and internal kind")
    func mountedVolumesIntegration() {
        let volumes = VolumeInventory.mountedVolumes()
        let rootVolumes = volumes.filter { $0.id.path == "/" }

        #expect(rootVolumes.count == 1)
        guard let root = rootVolumes.first else {
            Issue.record("Expected exactly one root volume at /")
            return
        }

        #expect(root.isRoot == true)
        #expect(root.totalCapacity > 0)
        #expect(root.kind == .internal)
        #expect(!root.name.isEmpty)
        #expect(volumes.first?.id.path == "/")
    }
}

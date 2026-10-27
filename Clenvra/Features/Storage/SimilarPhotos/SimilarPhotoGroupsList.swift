import AppKit
import ClenvraKit
import SwiftUI

/// Every group of similar photos as thumbnails. Nothing is marked by the scan; one photo per group is always kept
/// (enforced by the session).
struct SimilarPhotoGroupsList: View {
    let session: SimilarPhotosSession
    @Binding var focusedPath: String?
    @Binding var previewURL: URL?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !session.lastScanWasComplete {
                    Label {
                        Text("The scan was stopped. Results may be incomplete.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                SimilarPhotosSkippedList(skipped: session.skipped)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                ForEach(session.groups) { group in
                    SimilarPhotoGroupSection(
                        group: group, session: session, focusedPath: $focusedPath, previewURL: $previewURL)
                    Divider()
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let focusedPath else { return .ignored }
            previewURL = previewURL == nil ? URL(filePath: focusedPath) : nil
            return .handled
        }
        .disabled(session.phase == .removing)
    }
}

/// Folders and images that were not compared, each with a plain reason; collapsed by default.
struct SimilarPhotosSkippedList: View {
    let skipped: [String: SimilarPhotoSkipReason]

    var body: some View {
        if !skipped.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(skipped.keys.sorted(), id: \.self) { path in
                        if let reason = skipped[path] {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reason.explanation)
                                PathText(path: path)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label {
                    Text("\(skipped.count) items were not compared")
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("similarPhotos.skipped")
        }
    }
}

private struct SimilarPhotoGroupSection: View {
    let group: SimilarPhotoGroup
    let session: SimilarPhotosSession
    @Binding var focusedPath: String?
    @Binding var previewURL: URL?

    private static let thumbnailSide: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.thumbnailSide, maximum: Self.thumbnailSide), spacing: 14)],
                alignment: .leading, spacing: 14
            ) {
                ForEach(group.photos, id: \.path) { photo in
                    SimilarPhotoCell(
                        photo: photo, isSuggestedKeeper: photo.path == group.suggestedKeeper, session: session,
                        side: Self.thumbnailSide, focusedPath: $focusedPath, previewURL: $previewURL)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.photos.count) similar photos")
                    .font(.headline)
                Text(
                    "Keeping only the best frees about \(group.reclaimableIfOthersRemoved.formatted(.byteCount(style: .file)))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Frees about \(session.markedBytes(in: group).formatted(.byteCount(style: .file)))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                for photo in group.photos { session.setMarked(false, path: photo.path) }
            } label: {
                Text("Keep All")
            }
            .disabled(!group.photos.contains { session.isMarked($0.path) })
            Button {
                session.keepOnly(group.suggestedKeeper)
            } label: {
                Text("Mark All but the Best")
            }
            .help(Text("Marks every photo in this group except the one suggested to keep."))
        }
        .controlSize(.small)
    }
}

private struct SimilarPhotoCell: View {
    let photo: SimilarPhoto
    let isSuggestedKeeper: Bool
    let session: SimilarPhotosSession
    let side: CGFloat
    @Binding var focusedPath: String?
    @Binding var previewURL: URL?

    private var name: String { (photo.path as NSString).lastPathComponent }
    private var dimensions: String { "\(photo.pixelWidth.formatted()) × \(photo.pixelHeight.formatted())" }

    var body: some View {
        let isMarked = session.isMarked(photo.path)
        VStack(alignment: .leading, spacing: 4) {
            thumbnail(isMarked: isMarked)
            Toggle(
                isOn: Binding(
                    get: { session.isMarked(photo.path) },
                    set: { session.setMarked($0, path: photo.path) })
            ) {
                Text("Move to Trash")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(!session.canMark(photo.path))
            .help(Text("One photo in every group is always kept."))
            .accessibilityLabel(Text("Move \(name) to the Trash"))
            .accessibilityIdentifier("similarPhotos.mark")
            Text(verbatim: name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Text(verbatim: photo.path))
                .accessibilityHidden(true)
            Text(verbatim: "\(dimensions) · \(photo.size.formatted(.byteCount(style: .file)))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .frame(width: side)
        .contextMenu { menu }
    }

    private func thumbnail(isMarked: Bool) -> some View {
        PhotoThumbnail(path: photo.path, side: side)
            .opacity(isMarked ? 0.5 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        focusedPath == photo.path ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: focusedPath == photo.path ? 3 : 0.5)
            }
            .overlay(alignment: .topLeading) {
                if isSuggestedKeeper {
                    badge {
                        Label {
                            Text("Keep")
                        } icon: {
                            Image(systemName: "star.fill")
                        }
                    }
                    .help(Text("Suggested to keep: the most pixels, then the newest."))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isMarked {
                    badge {
                        Label {
                            Text("Move to Trash")
                        } icon: {
                            Image(systemName: "trash")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                focusedPath = photo.path
                previewURL = URL(filePath: photo.path)
            }
            .onTapGesture {
                focusedPath = photo.path
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(accessibilityValue(isMarked: isMarked))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(focusedPath == photo.path ? .isSelected : [])
            .accessibilityAction(named: Text("Quick Look")) {
                previewURL = URL(filePath: photo.path)
            }
            .accessibilityIdentifier("similarPhotos.thumbnail")
    }

    private func accessibilityValue(isMarked: Bool) -> Text {
        let details = Text(verbatim: "\(dimensions), \(photo.size.formatted(.byteCount(style: .file)))")
        if isSuggestedKeeper { return Text("Suggested to keep, \(details)") }
        if isMarked { return Text("Marked for the Trash, \(details)") }
        return details
    }

    private func badge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .padding(5)
    }

    @ViewBuilder private var menu: some View {
        Button {
            previewURL = URL(filePath: photo.path)
        } label: {
            Text("Quick Look")
        }
        Button {
            session.keepOnly(photo.path)
        } label: {
            Text("Keep Only This Photo")
        }
        Divider()
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: photo.path)])
        } label: {
            Text("Show in Finder")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(photo.path, forType: .string)
        } label: {
            Text("Copy Path")
        }
    }
}

extension SimilarPhotoSkipReason {
    var explanation: LocalizedStringResource {
        switch self {
        case .unreadable(let code) where code == EACCES || code == EPERM: "macOS did not allow access."
        case .unreadable: "It could not be read."
        case .notDecodable: "It is not an image Clenvra can read."
        case .tooLarge: "It is too large to compare."
        case .analysisFailed: "It could not be compared."
        case .insidePhotosLibrary: "It is inside a Photos library. Use Photos to manage it."
        case .protected: "Protected by Clenvra."
        }
    }
}

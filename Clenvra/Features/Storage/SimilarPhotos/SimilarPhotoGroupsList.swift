import AppKit
import ClenvraKit
import SwiftUI

/// Every group of similar photos as thumbnails, its keeper first with a Keep badge and the photos selected to go with
/// a Remove badge. The session pre-selects every photo but each keeper and never marks a keeper.
struct SimilarPhotoGroupsList: View {
    let session: SimilarPhotosSession
    @Binding var focusedPath: String?
    @Binding var previewURL: URL?
    /// Clicking a photo opens the comparison with its group's keeper.
    @Binding var showsInspector: Bool
    /// Whether a group is open; the page owns the state so its toolbar can open or close them all.
    let isExpanded: (String) -> Binding<Bool>
    /// Shows only the groups with a photo whose file name matches (already trimmed); empty shows everything. A
    /// matching group is shown whole, so the photo kept is always in view.
    var query = ""

    /// Expansion id of the "Blurry or Dark Photos" section.
    static let lowQualityID = "lowQuality"

    static func matches(_ photos: [SimilarPhoto], _ query: String) -> Bool {
        query.isEmpty
            || photos.contains { $0.path.localizedStandardContains(query) }
    }

    private var visibleGroups: [SimilarPhotoGroup] {
        session.groups.filter { Self.matches($0.photos, query) }
    }

    var body: some View {
        list
            .pageState(isShown: visibleGroups.isEmpty && !Self.matches(session.lowQualityPhotos, query)) {
                ContentUnavailableView.search(text: query)
            }
    }

    private var list: some View {
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
                if !session.lowQualityPhotos.isEmpty, Self.matches(session.lowQualityPhotos, query) {
                    LowQualityPhotosSection(
                        session: session, focusedPath: $focusedPath, previewURL: $previewURL,
                        showsInspector: $showsInspector, isExpanded: isExpanded(SimilarPhotoGroupsList.lowQualityID))
                    Divider()
                        .padding(.horizontal, 16)
                }
                ForEach(visibleGroups) { group in
                    SimilarPhotoGroupSection(
                        group: group, session: session, focusedPath: $focusedPath, previewURL: $previewURL,
                        showsInspector: $showsInspector, isExpanded: isExpanded(group.id))
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
    @Binding var showsInspector: Bool
    @Binding var isExpanded: Bool

    private static let thumbnailSide: CGFloat = 132

    var body: some View {
        let keeper = session.keeper(of: group)
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.thumbnailSide, maximum: Self.thumbnailSide), spacing: 14)],
                alignment: .leading, spacing: 14
            ) {
                ForEach(session.photosKeeperFirst(in: group), id: \.path) { photo in
                    SimilarPhotoCell(
                        photo: photo, isKeeper: photo.path == keeper,
                        isSuggested: photo.path == group.suggestedKeeper, session: session,
                        side: Self.thumbnailSide, focusedPath: $focusedPath, previewURL: $previewURL,
                        showsInspector: $showsInspector)
                }
            }
            .padding(.top, 10)
        } label: {
            header
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var keeperName: String { (session.keeper(of: group) as NSString).lastPathComponent }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.photos.count) similar photos")
                    .font(.headline)
                Text("Keeping \(keeperName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("Frees about \(session.markedBytes(in: group).formatted(.byteCount(style: .file)))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                for photo in group.photos { session.setMarked(false, path: photo.path) }
            } label: {
                Text("Keep All")
            }
            .disabled(!group.photos.contains { session.isMarked($0.path) })
            Button {
                session.setKeeper(session.keeper(of: group))
            } label: {
                Text("Select All but the Kept Photo")
            }
            .help(Text("Selects every photo in this group except the one marked Keep."))
        }
        .controlSize(.small)
    }
}

/// Photos macOS image analysis rates as blurry, dark or otherwise failed. All are pre-selected except a group's
/// keeper; a photo that is also in a group keeps that group's rule.
private struct LowQualityPhotosSection: View {
    let session: SimilarPhotosSession
    @Binding var focusedPath: String?
    @Binding var previewURL: URL?
    @Binding var showsInspector: Bool
    @Binding var isExpanded: Bool

    private static let thumbnailSide: CGFloat = 132

    private var totalBytes: Int64 { session.lowQualityPhotos.reduce(0) { $0 + $1.size } }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: Self.thumbnailSide, maximum: Self.thumbnailSide), spacing: 14)
                    ],
                    alignment: .leading, spacing: 14
                ) {
                    ForEach(session.lowQualityPhotos, id: \.path) { photo in
                        SimilarPhotoCell(
                            photo: photo, isKeeper: session.isKeeper(photo.path), isSuggested: false,
                            session: session, side: Self.thumbnailSide, focusedPath: $focusedPath,
                            previewURL: $previewURL, showsInspector: $showsInspector)
                    }
                }
                Text("Rated by macOS image analysis. Check each photo before moving it to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            header
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityIdentifier("similarPhotos.lowQuality")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Blurry or Dark Photos")
                    .font(.headline)
                Text(
                    "\(session.lowQualityPhotos.count) photos · \(totalBytes.formatted(.byteCount(style: .file)))"
                )
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Frees about \(session.markedBytesInLowQuality.formatted(.byteCount(style: .file)))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                for photo in session.lowQualityPhotos { session.setMarked(false, path: photo.path) }
            } label: {
                Text("Keep All")
            }
            .disabled(!session.lowQualityPhotos.contains { session.isMarked($0.path) })
        }
        .controlSize(.small)
    }
}

private struct SimilarPhotoCell: View {
    let photo: SimilarPhoto
    /// The photo its group keeps; never marked.
    let isKeeper: Bool
    /// The photo Clenvra suggested keeping (the most pixels, then the newest).
    let isSuggested: Bool
    let session: SimilarPhotosSession
    let side: CGFloat
    @Binding var focusedPath: String?
    @Binding var previewURL: URL?
    @Binding var showsInspector: Bool

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
            .help(
                isKeeper
                    ? Text("This photo is kept. To remove it, choose Keep This Instead on another photo of its group.")
                    : Text("One photo in every group is always kept.")
            )
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
                if isKeeper {
                    badge {
                        Label {
                            Text("Keep")
                        } icon: {
                            Image(systemName: "star.fill")
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                    .help(
                        isSuggested
                            ? Text("Suggested to keep: the most pixels, then the newest.")
                            : Text("You chose to keep this photo."))
                } else if isMarked {
                    badge {
                        Label {
                            Text("Remove")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .foregroundStyle(.red)
                    .help(Text("Selected to move to the Trash. Click the photo to compare it with the one kept."))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                focusedPath = photo.path
                previewURL = URL(filePath: photo.path)
            }
            .onTapGesture {
                focusedPath = photo.path
                showsInspector = true
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
        if isKeeper { return Text("Kept, \(details)") }
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
            focusedPath = photo.path
            showsInspector = true
        } label: {
            Text("Show Details")
        }
        // Also offered in the blurry or dark section for a photo that is in a group.
        if !isKeeper, session.keeperPhoto(comparedWith: photo.path) != nil {
            Button {
                session.setKeeper(photo.path)
            } label: {
                Text("Keep This Instead")
            }
        }
        if !isKeeper, session.isMarked(photo.path) {
            Button {
                session.setMarked(false, path: photo.path)
            } label: {
                Text("Don't Remove")
            }
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

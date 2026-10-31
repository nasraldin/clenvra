import AppKit
import ClenvraKit
import SwiftUI

/// The details panel of Similar Photos: the clicked photo next to the photo its group keeps, so it is always clear
/// which one stays. A keeper or a blurry or dark photo in no group is shown alone.
struct SimilarPhotoComparison: View {
    let session: SimilarPhotosSession
    let path: String?

    var body: some View {
        if let path, let photo = photo(at: path) {
            content(photo)
        } else {
            NoSelectionInspector(description: "Click a photo to compare it with the one kept in its group.")
        }
    }

    private func photo(at path: String) -> SimilarPhoto? {
        session.groups.lazy.flatMap(\.photos).first { $0.path == path }
            ?? session.lowQualityPhotos.first { $0.path == path }
    }

    private func content(_ photo: SimilarPhoto) -> some View {
        let keeper = session.keeperPhoto(comparedWith: photo.path)
        let isKeeper = keeper?.path == photo.path
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(photo, keeper: keeper)
                if let keeper, !isKeeper {
                    HStack(alignment: .top, spacing: 12) {
                        ComparedPhotoColumn(photo: photo, role: session.isMarked(photo.path) ? .remove : .notRemoved)
                        ComparedPhotoColumn(photo: keeper, role: .keep)
                    }
                } else {
                    ComparedPhotoColumn(
                        photo: photo, role: isKeeper ? .keep : (session.isMarked(photo.path) ? .remove : .notRemoved))
                }
                actions(photo, keeper: keeper, isKeeper: isKeeper)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.inspector")
    }

    @ViewBuilder private func summary(_ photo: SimilarPhoto, keeper: SimilarPhoto?) -> some View {
        if keeper == nil {
            Text("Rated blurry or dark. It is in no group, so nothing else is kept in its place.")
                .foregroundStyle(.secondary)
        } else if keeper?.path == photo.path {
            Text("This photo is kept. The other photos of its group are compared with it.")
                .foregroundStyle(.secondary)
        } else {
            Text("Compared with the photo kept in its group.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func actions(_ photo: SimilarPhoto, keeper: SimilarPhoto?, isKeeper: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if keeper != nil, !isKeeper {
                Button {
                    session.setKeeper(photo.path)
                } label: {
                    Text("Keep This Instead")
                }
                .help(Text("Keep this photo and select the other photos of its group to move to the Trash."))
                .accessibilityIdentifier("similarPhotos.keepInstead")
            }
            if !isKeeper {
                if session.isMarked(photo.path) {
                    Button {
                        session.setMarked(false, path: photo.path)
                    } label: {
                        Text("Don't Remove")
                    }
                    .accessibilityIdentifier("similarPhotos.dontRemove")
                } else {
                    Button {
                        session.setMarked(true, path: photo.path)
                    } label: {
                        Text("Move to Trash")
                    }
                    .disabled(!session.canMark(photo.path))
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: photo.path)])
            } label: {
                Text("Show in Finder")
            }
        }
        .disabled(session.phase != .ready)
    }
}

/// One photo of the comparison: its thumbnail, what happens to it, and the facts to compare.
private struct ComparedPhotoColumn: View {
    enum Role {
        case keep
        case remove
        case notRemoved
    }

    let photo: SimilarPhoto
    let role: Role

    private static let side: CGFloat = 150

    private var name: String { (photo.path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            roleLabel
                .font(.callout.weight(.semibold))
            PhotoThumbnail(path: photo.path, side: Self.side)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(role == .keep ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
                }
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .environment(\.layoutDirection, .leftToRight)
                .help(Text(verbatim: photo.path))
            fact {
                Text("Size")
            } value: {
                Text(photo.size.formatted(.byteCount(style: .file)))
            }
            fact {
                Text("Dimensions")
            } value: {
                Text(verbatim: "\(photo.pixelWidth.formatted()) × \(photo.pixelHeight.formatted())")
            }
            fact {
                Text("Modified")
            } value: {
                Text(photo.modificationDate, format: .dateTime.year().month(.abbreviated).day())
            }
            fact {
                Text("Quality")
            } value: {
                quality
            }
            fact {
                Text("Folder")
            } value: {
                PathText(path: (photo.path as NSString).deletingLastPathComponent)
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var roleLabel: some View {
        switch role {
        case .keep:
            Label {
                Text("Keep")
            } icon: {
                Image(systemName: "star.fill")
            }
            .foregroundStyle(Color.accentColor)
        case .remove:
            Label {
                Text("Remove")
            } icon: {
                Image(systemName: "trash")
            }
            .foregroundStyle(.red)
        case .notRemoved:
            Label {
                Text("Not Removed")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var quality: some View {
        if let quality = photo.quality {
            if quality.isUtility {
                Text("Screenshot or Document")
            } else if quality.isLow {
                Text("Blurry or Dark")
            } else {
                Text("Good")
            }
        } else {
            Text("Not Rated")
        }
    }

    private func fact<Label: View, Value: View>(
        @ViewBuilder _ label: () -> Label, @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label()
                .font(.caption2)
                .foregroundStyle(.secondary)
            value()
                .font(.caption)
                .monospacedDigit()
        }
    }
}

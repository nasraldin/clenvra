import ClenvraKit
import SwiftUI

/// Confirmation before moving an app and its files to the Trash.
struct ConfirmUninstallSheet: View {
    let appName: String
    let count: Int
    let bytes: Int64
    let hasRevealOnlyItems: Bool
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Uninstall \(appName)?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            Text("The app and \(count - 1) of its items will be moved to the Trash.")
            Text("This frees about \(bytes.formatted(.byteCount(style: .file))).")
            if hasRevealOnlyItems {
                Text("Files outside your home folder are not removed.")
                    .foregroundStyle(.secondary)
            }
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
                Button(role: .destructive, action: confirm) {
                    Text("Move to Trash")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Confirmation before running `brew uninstall`, which bypasses the Trash.
struct ConfirmHomebrewSheet: View {
    let appName: String
    let command: Command
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Uninstall \(appName) with Homebrew?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
            }
            Text("Clenvra will run this command:")
            CommandText(command: command)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
            Text("Homebrew removes the app permanently. It does not go to the Trash and can't be put back.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .destructive, action: confirm) {
                    Text("Run Command")
                }
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// What `brew` printed and whether it succeeded.
struct HomebrewResultSheet: View {
    let result: CommandResult
    let output: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if result.terminationReason == .exited && result.exitStatus == 0 {
                Text("Homebrew removed the app")
                    .font(.title3.bold())
            } else {
                Text("Homebrew could not remove the app")
                    .font(.title3.bold())
                Text("Nothing else was changed. The output below explains what went wrong.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(verbatim: output.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .accessibilityIdentifier("review.results")
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Shown when an uninstall was not started because the app became unavailable after review.
struct NotUninstalledSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing was removed")
                .font(.title3.bold())
            Text("The app is open, or it changed after you reviewed it. Quit it and try again.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

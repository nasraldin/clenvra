import ClenvraKit
import SwiftUI

/// The Developer Tools page: checks tools only when asked, then lists what each one stores.
struct DeveloperToolsView: View {
    /// Nil until the login-shell PATH is known (tools from Homebrew, nvm, volta… live there).
    let session: ToolStorageSession?

    var body: some View {
        if let session {
            if session.phase == .idle && session.rows.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(AppSection.developerTools.title)
                    } icon: {
                        Image(systemName: AppSection.developerTools.symbol)
                    }
                } description: {
                    Text(
                        "See how much space npm, pnpm, Homebrew, Docker and your other tools keep, and clean it with each tool’s own command."
                    )
                } actions: {
                    Button {
                        Task { await session.inspect() }
                    } label: {
                        Text("Check Tools")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("review.scan")
                }
            } else {
                List {
                    ToolStorageSection(session: session)
                }
                .accessibilityIdentifier("review.results")
                .accessibilityLabel(Text(AppSection.developerTools.title))
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await session.inspect() }
                        } label: {
                            Label {
                                Text("Check Again")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help(Text("Check your tools again (⌘R)"))
                        .disabled(session.phase == .inspecting)
                    }
                }
            }
        } else {
            ProgressView {
                Text("Finding your developer tools…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Developer tools' own storage, each cleaned by the tool's own command (shown before it runs).
struct ToolStorageSection: View {
    let session: ToolStorageSession

    @State private var confirming: ToolStorage?
    @State private var showingOutput = false

    var body: some View {
        Section {
            if session.phase == .inspecting && session.rows.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking developer tools…").foregroundStyle(.secondary)
                }
            }
            ForEach(session.rows) { row in
                ToolRow(row: row, isRunning: session.phase == .running(rowID: row.id)) {
                    confirming = row
                }
                .disabled(isBusy)
            }
        } footer: {
            Text("Space managed by your tools. Cleaning runs the tool's own command, which does not use the Trash.")
                .font(.callout)
        }
        .sheet(item: $confirming) { row in
            ConfirmToolCleanupSheet(row: row) {
                confirming = nil
                Task {
                    await session.runCleanup(rowID: row.id)
                    showingOutput = true
                }
            }
        }
        .sheet(isPresented: $showingOutput) {
            if let run = session.lastRun { ToolRunResultSheet(run: run) }
        }
    }

    private var isBusy: Bool {
        if case .running = session.phase { true } else { false }
    }
}

private struct ToolRow: View {
    let row: ToolStorage
    let isRunning: Bool
    let clean: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tool)
                if let note = row.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if let location = row.location { PathText(path: location) }
            }
            Spacer(minLength: 12)
            if let size = row.size {
                SizeText(bytes: size).frame(minWidth: 80, alignment: .trailing)
            } else {
                Text(verbatim: "—").foregroundStyle(.tertiary).frame(minWidth: 80, alignment: .trailing)
            }
            if isRunning {
                ProgressView().controlSize(.small)
            } else if row.cleanup != nil {
                Button(action: clean) {
                    Text("Clean…")
                }
                // Nothing measured to free; an unknown size (—) stays enabled.
                .disabled(row.size == 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shows exactly what will run and that it cannot be undone.
private struct ConfirmToolCleanupSheet: View {
    let row: ToolStorage
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run this command?").font(.title3.bold())
            if let summary = row.cleanup?.summary {
                Text(verbatim: summary)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
            }
            if let note = row.note { Text(note) }
            Label {
                Text("This does not use the Trash and cannot be undone.")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: confirm) {
                    Text("Run")
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct ToolRunResultSheet: View {
    let run: ToolStorageSession.Run

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = run.result, result.terminationReason == .exited, result.exitStatus == 0 {
                Label {
                    Text("Finished")
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
                .font(.title3.bold())
            } else {
                Label {
                    Text("The command did not finish successfully")
                } icon: {
                    Image(systemName: "xmark.octagon").foregroundStyle(.red)
                }
                .font(.title3.bold())
            }
            Text(verbatim: run.summary).font(.callout.monospaced()).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: outputText)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .environment(\.layoutDirection, .leftToRight)
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
        .frame(width: 560)
    }

    private var outputText: String {
        let lines = run.output.map(\.text)
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        return [run.result?.standardOutput, run.result?.standardError].compactMap { $0 }.joined(separator: "\n")
    }
}

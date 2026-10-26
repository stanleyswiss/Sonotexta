import SwiftUI

/// Single-row API key cell used by the Connections tab.
///
/// Three states:
///   - `.configured`   — key is set; row shows masked key + Test + Remove.
///   - `.missing`      — no key; row shows "Add key" CTA which opens an
///                       inline editor sheet.
///   - `.runningLocal` — keyless provider (Ollama); row shows "Ready" badge
///                       and a one-line setup hint.
///
/// The row is self-contained: it owns its editor sheet, test state, and
/// removal confirmation. `provider` is the only required input; the row
/// looks up the key state on appear and after every save/remove.
struct APIKeyRow: View {
    let provider: KeychainProvider

    /// Optional override of the displayed name. Used when the SAME provider
    /// is rendered twice (OpenAI in Speech + Post-processing sections) and
    /// the caller wants a contextual subtitle distinct from `provider.displayName`.
    var nameOverride: String? = nil

    @State private var isEditing = false
    @State private var editorKey = ""
    @State private var showKey = false
    @State private var isTesting = false
    @State private var testResult: KeychainProvider.TestOutcome?
    @State private var maskedKey: String?
    @State private var refreshTrigger = 0   // bumped after save/remove to refresh body

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.icon)
                .foregroundStyle(DesignTokens.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(nameOverride ?? provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                stateLine
            }

            Spacer(minLength: 8)

            controls
        }
        .padding(.vertical, 6)
        .id(refreshTrigger)
        .onAppear { refreshState() }
        .sheet(isPresented: $isEditing, onDismiss: { showKey = false }) {
            editorSheet
        }
    }

    // MARK: - State line

    @ViewBuilder
    private var stateLine: some View {
        if provider.isKeyless && provider == .ollama {
            Text("Running locally")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if provider == .appleTranslate {
            Text("Built-in on macOS 26+")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let mask = maskedKey {
            Text(mask)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("— not configured —")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Trailing controls

    @ViewBuilder
    private var controls: some View {
        if let result = testResult {
            // Status badge after a Test — auto-disappears after the user
            // re-edits the key or removes it (handled in refreshState).
            switch result {
            case .success(let msg):
                StatusBadge(status: .configured, label: msg)
            case .failure(let msg):
                StatusBadge(status: .error, label: msg)
            }
        }

        if provider == .ollama {
            StatusBadge(status: .configured, label: "Ready")
        } else if provider == .appleTranslate {
            StatusBadge(status: .configured, label: "Ready")
        } else if maskedKey != nil {
            // Configured state — Test + Remove.
            Button {
                runTest()
            } label: {
                HStack(spacing: 4) {
                    if isTesting { ProgressView().scaleEffect(0.5) }
                    Text("Test")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isTesting)

            Button("Remove", role: .destructive) {
                provider.saveKey(nil)
                testResult = nil
                refreshState()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            // Missing — Add key CTA.
            Button("Add key") {
                editorKey = ""
                isEditing = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DesignTokens.accent)
        }
    }

    // MARK: - Editor sheet (inline key entry)

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(provider.displayName) key")
                .font(.system(size: 16, weight: .semibold))
            Text(provider.keyPlaceholder)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                if showKey {
                    TextField(provider.keyPlaceholder, text: $editorKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                } else {
                    SecureField(provider.keyPlaceholder, text: $editorKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
                Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    .buttonStyle(.borderless)
            }

            Text("Stored securely in the macOS Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                Button("Save") {
                    provider.saveKey(editorKey)
                    testResult = nil
                    refreshState()
                    isEditing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editorKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - State helpers

    private func refreshState() {
        maskedKey = provider.maskedDisplay()
        refreshTrigger &+= 1
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task { @MainActor in
            let outcome = await provider.testKey()
            testResult = outcome
            isTesting = false
        }
    }
}

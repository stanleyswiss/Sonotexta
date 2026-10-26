import SwiftUI
import AppKit
import Combine

// MARK: - Controller

final class DictationOverlayController {
    private var window: NSPanel?
    private var hostingView: NSHostingView<DictationOverlayView>?
    private var viewModel = DictationOverlayViewModel()

    /// Set this to the DictationManager's stopDictation callback
    var onStop: (() -> Void)?

    func show(status: String = "Listening...", profileName: String? = nil, languageInfo: String? = nil) {
        viewModel.status = status
        viewModel.transcriptionText = ""
        viewModel.profileName = profileName
        viewModel.languageInfo = languageInfo
        updatePhase(from: status)

        if window != nil { return }

        viewModel.onStop = { [weak self] in
            self?.onStop?()
        }

        let overlayView = DictationOverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 120)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 240
            let y = screenFrame.maxY - 140
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        window = panel
        hostingView = hosting
    }

    func update(status: String) {
        viewModel.status = status
        updatePhase(from: status)

        // If the status contains live transcription text, extract it
        if status.contains("Dictating:") || status.count > 40 {
            // For realtime engines, the status IS the transcription
            viewModel.transcriptionText = status
        }
    }

    /// Update the overlay with the live transcription text separately
    func updateTranscription(_ text: String) {
        viewModel.transcriptionText = text
    }

    func hide() {
        // Default hide: brief "Delivered" flash before hiding. Use this only
        // when actual delivery succeeded; call `hideWith(status:phase:after:)`
        // for non-delivered cases so the overlay reflects reality.
        hideWith(status: "Delivered", phase: .delivered, after: 0.8)
    }

    /// Hide the overlay after showing a final status + phase. The previous
    /// `hide()` always flashed "Delivered" regardless of whether the text
    /// actually reached the target app — when `accessibilityService.insertText`
    /// fell back to the clipboard or failed entirely, the overlay still
    /// claimed success. 3.14.1-beta.2 fix: deliverText now calls this with
    /// the real delivery result.
    func hideWith(status: String, phase: OverlayPhase, after delay: TimeInterval) {
        viewModel.phase = phase
        viewModel.status = status

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.hostingView = nil
            self?.viewModel.phase = .idle
            self?.viewModel.transcriptionText = ""
        }
    }

    private func updatePhase(from status: String) {
        if status.contains("AI") || status.contains("Translating") || status.contains("Processing") {
            viewModel.phase = .processing
        } else if status.contains("Loading") {
            viewModel.phase = .loading
        } else if status.contains("Delivered") {
            viewModel.phase = .delivered
        } else if status.contains("error") || status.contains("Error") {
            viewModel.phase = .error
        } else {
            viewModel.phase = .listening
        }
    }
}

// MARK: - ViewModel

enum OverlayPhase {
    case idle, loading, listening, processing, delivered, error
}

class DictationOverlayViewModel: ObservableObject {
    @Published var status: String = "Listening..."
    @Published var phase: OverlayPhase = .listening
    @Published var transcriptionText: String = ""
    @Published var profileName: String?
    @Published var languageInfo: String?
    var onStop: (() -> Void)?
}

// MARK: - Overlay View

struct DictationOverlayView: View {
    @ObservedObject var viewModel: DictationOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar: waveform/icon + status + profile badge + stop button
            HStack(spacing: 10) {
                // Phase indicator
                phaseIndicator
                    .frame(width: 32, height: 32)

                // Status text
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    if let profile = viewModel.profileName {
                        HStack(spacing: 4) {
                            Text(profile)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DesignTokens.hudForeground.opacity(0.5))
                            if let lang = viewModel.languageInfo {
                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignTokens.hudForeground.opacity(0.3))
                                Text(lang)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(DesignTokens.accent.opacity(0.56))
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Stop button
                Button(action: { viewModel.onStop?() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignTokens.hudForeground.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(DesignTokens.hudForeground.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Stop dictation")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, transcriptionPreview.isEmpty ? 12 : 8)

            // Live transcription text (if available)
            if !transcriptionPreview.isEmpty {
                Text(transcriptionPreview)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DesignTokens.hudForeground.opacity(0.6))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 260, maxWidth: 480)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(DesignTokens.hudBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .shadow(color: shadowColor, radius: 16, y: 6)
        )
        .animation(.easeInOut(duration: 0.3), value: viewModel.phase)
    }

    // MARK: - Phase Indicator

    @ViewBuilder
    private var phaseIndicator: some View {
        switch viewModel.phase {
        case .idle:
            EmptyView()

        case .loading:
            ProgressView()
                .scaleEffect(0.6)
                .tint(DesignTokens.hudForeground)

        case .listening:
            OverlayWaveformView()

        case .processing:
            ZStack {
                Circle()
                    .fill(DesignTokens.accent.opacity(0.2))
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DesignTokens.accent.opacity(0.7))
            }

        case .delivered:
            ZStack {
                Circle()
                    .fill(DesignTokens.statusSuccess.opacity(0.2))
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DesignTokens.statusSuccess)
            }

        case .error:
            ZStack {
                Circle()
                    .fill(DesignTokens.statusDanger.opacity(0.2))
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DesignTokens.statusDanger)
            }
        }
    }

    // MARK: - Computed

    private var statusLabel: String {
        switch viewModel.phase {
        case .delivered: return "Delivered"
        case .error: return viewModel.status
        default:
            // Clean up internal status strings for display
            let s = viewModel.status
            if s.contains("Hearing:") { return "Listening..." }
            if s.contains("Dictating:") { return "Listening..." }
            return s
        }
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .listening: return DesignTokens.hudForeground
        case .processing: return DesignTokens.accent.opacity(0.7)
        case .delivered: return DesignTokens.statusSuccess
        case .error: return DesignTokens.statusDanger
        default: return DesignTokens.hudForeground.opacity(0.7)
        }
    }

    private var borderColor: Color {
        switch viewModel.phase {
        case .listening: return DesignTokens.accent.opacity(0.4)
        case .processing: return DesignTokens.accent.opacity(0.5)
        case .delivered: return DesignTokens.statusSuccess.opacity(0.4)
        case .error: return DesignTokens.statusDanger.opacity(0.4)
        default: return DesignTokens.hudForeground.opacity(0.1)
        }
    }

    private var shadowColor: Color {
        switch viewModel.phase {
        case .listening, .processing: return DesignTokens.accent.opacity(0.2)
        case .delivered: return DesignTokens.statusSuccess.opacity(0.15)
        default: return DesignTokens.hudBackground.opacity(0.3)
        }
    }

    private var transcriptionPreview: String {
        let text = viewModel.transcriptionText
        guard !text.isEmpty else { return "" }
        // Show last ~80 chars of transcription
        if text.count > 80 {
            return "..." + String(text.suffix(77))
        }
        return text
    }
}

// MARK: - Purple Waveform

struct OverlayWaveformView: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                OverlayWaveformBar(index: i)
            }
        }
    }
}

struct OverlayWaveformBar: View {
    let index: Int
    @State private var height: CGFloat = 4

    private let purple = DesignTokens.accent
    private let lightPurple = DesignTokens.accent.opacity(0.7)

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(
                LinearGradient(
                    colors: [lightPurple, purple],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: height)
            .opacity(0.8)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: Double.random(in: 0.3...0.6))
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.07)
                ) {
                    height = CGFloat.random(in: 10...26)
                }
            }
    }
}

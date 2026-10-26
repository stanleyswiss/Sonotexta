import AVFoundation
import Combine

final class AudioCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var hasPermission = false

    private var audioEngine: AVAudioEngine?

    init() {
        checkPermission()
    }

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            hasPermission = false
        default:
            hasPermission = false
        }
    }

    func requestPermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run { hasPermission = granted }
        return granted
    }

    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            onBuffer(buffer, time)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        isCapturing = true
    }

    func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isCapturing = false
    }
}

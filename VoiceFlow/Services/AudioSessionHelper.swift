import AVFoundation
import CoreAudio
import Foundation

/// Represents an available audio input device.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Configures the system audio input for shared access so VoiceFlow can record
/// while other apps (FaceTime, Zoom, Teams) are using the microphone.
enum AudioSessionHelper {

    // MARK: - Device Enumeration

    /// Returns all available audio input devices on the system.
    static func availableInputDevices() -> [AudioInputDevice] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        ) == noErr else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else { return [] }

        var inputDevices: [AudioInputDevice] = []

        for deviceID in deviceIDs {
            // Check if this device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr else { continue }

            inputDevices.append(AudioInputDevice(
                id: deviceID,
                uid: uidRef as String,
                name: nameRef as String
            ))
        }

        return inputDevices
    }

    /// Find the AudioDeviceID for a given UID string.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let devices = availableInputDevices()
        return devices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Engine Configuration

    /// Configure a per-app input override before installing a tap. The capture
    /// client format is explicitly renegotiated after selecting the device.
    /// Hardware validation on C920/Tahoe is still required for this candidate.
    static func setInputDevice(_ deviceUID: String?, on engine: AVAudioEngine) {
        guard let uid = deviceUID,
              let deviceID = deviceID(forUID: uid) else {
            // nil or not found → use system default (no action needed)
            return
        }

        let inputNode = engine.inputNode
        guard let au = inputNode.audioUnit else { return }

        // beta.3 diagnostic: capture pre-swap state so any future user-side
        // -10868 (kAudioUnitErr_FormatNotSupported) report has the data we
        // need to debug without another back-and-forth. Cheap to keep — only
        // runs on the per-app device-override code path.
        let formatBefore = inputNode.outputFormat(forBus: 0)
        let systemDefaultUID = systemDefaultInputDeviceUID()
        let availableRates = availableNominalSampleRates(forDevice: deviceID)
        print("[VoiceFlow][setInputDevice] requested=\(uid) systemDefault=\(systemDefaultUID ?? "<none>") availableRates=\(availableRates.map { Int($0) }) formatBefore=\(Int(formatBefore.sampleRate))Hz×\(formatBefore.channelCount)ch")

        _ = configureCaptureUnit(au, deviceID: deviceID)
        let formatAfter = inputNode.outputFormat(forBus: 0)
        print("[VoiceFlow][setInputDevice] formatAfter=\(Int(formatAfter.sampleRate))Hz×\(formatAfter.channelCount)ch")
    }

    /// Capture-only AUHAL setup follows Apple TN2091: enable input, disable
    /// output, select the device, then align the client side of input element 1
    /// with the hardware rate before initialization. Selecting a microphone must
    /// not try to drive an output stream on an input-only device such as C920.
    /// This never changes the system-default device or its nominal sample rate.
    private static func configureCaptureUnit(_ unit: AudioUnit, deviceID: AudioDeviceID) -> Bool {
        let uninit = AudioUnitUninitialize(unit)
        var enable: UInt32 = 1
        let input = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                        kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        enable = 0
        let output = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                         kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        var selected = deviceID
        let device = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let read = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &hardware, &size)
        var formatStatus: OSStatus = kAudioUnitErr_FormatNotSupported
        if device == noErr, read == noErr, var client = captureClientFormat(hardware: hardware) {
            formatStatus = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Output, 1, &client, size)
        }
        // Reinitialize even after failure so the engine is not left torn down.
        let initialized = AudioUnitInitialize(unit)
        var actual: AudioDeviceID = 0
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readDevice = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &actual, &size)
        let success = input == noErr && output == noErr && device == noErr && read == noErr
            && formatStatus == noErr && initialized == noErr && readDevice == noErr && actual == deviceID
        print("[Sonotexta][input-format] requested=\(deviceID) actual=\(actual) hardware=\(hardware.mSampleRate)Hz×\(hardware.mChannelsPerFrame)ch uninit=\(uninit) inputIO=\(input) outputIO=\(output) setDevice=\(device) readFormat=\(read) setClientFormat=\(formatStatus) init=\(initialized) verified=\(success)")
        return success
    }

    /// AUHAL cannot resample here. Match the hardware rate/channels; the local
    /// engine's AVAudioConverter performs the separate conversion to 16 kHz.
    static func captureClientFormat(hardware: AudioStreamBasicDescription) -> AudioStreamBasicDescription? {
        guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0,
              hardware.mChannelsPerFrame > 0 else { return nil }
        // `AVAudioFormat(commonFormat:channels:)` rejects nonstandard channel
        // counts such as the 3-channel built-in microphone route FaceTime
        // creates. AUHAL does not need a semantic speaker layout here: it needs
        // explicit linear PCM matching the hardware rate/channel count.
        return AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: hardware.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Return the system default input device's AudioDeviceID, or nil.
    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &defaultID
        ) == noErr, defaultID != 0 else { return nil }
        return defaultID
    }

    /// Return the system default input device's UID, or nil if unavailable.
    /// Used by setInputDevice diagnostics to make device-override failures
    /// easy to triage.
    private static func systemDefaultInputDeviceUID() -> String? {
        guard let defaultID = systemDefaultInputDeviceID() else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(defaultID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr else { return nil }
        return uidRef as String
    }

    /// Re-point the engine's input AU at the SYSTEM DEFAULT device, using the
    /// same uninitialize/set/initialize bracket as `setInputDevice` so the
    /// format chain is renegotiated. Used by the 3.16.4 device-override
    /// fallback when a per-app override device can't start (Tahoe C920-class
    /// -10868 — see the 3.16.1 release notes' known limitation).
    @discardableResult
    static func resetToSystemDefaultInput(on engine: AVAudioEngine) -> Bool {
        guard let defaultID = systemDefaultInputDeviceID(), let unit = engine.inputNode.audioUnit else {
            print("[VoiceFlow][fallback] no system default input device available")
            return false
        }
        return configureCaptureUnit(unit, deviceID: defaultID)
    }

    /// Return the device's supported nominal sample rates (Hz). Empty if
    /// unavailable. Useful for diagnosing format-chain mismatches: if a USB
    /// device reports {48000} but AVAudioEngine cached a different rate at
    /// inputNode access time, engine.start() throws -10868.
    private static func availableNominalSampleRates(forDevice deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        // Most devices report each supported rate as a singleton range (min==max).
        // For continuous ranges, show the upper bound which is the typical max.
        return ranges.map { $0.mMaximum }.sorted()
    }

    /// Configure capture without opening an unnecessary output stream. Core Audio
    /// shares normal input devices; bypassing an effect does not enable sharing.
    /// The default route needs the same input-only setup as a device override,
    /// especially when a call has already configured the input/output hardware.
    /// This does not change system routes, device rates, or another app's mute.
    static func configureSharedInput(for engine: AVAudioEngine) {
        if let uid = AppSettings.shared.selectedInputDeviceUID,
           deviceID(forUID: uid) != nil {
            setInputDevice(uid, on: engine)
        } else if !resetToSystemDefaultInput(on: engine) {
            print("[Sonotexta] Could not configure the default microphone for input-only capture; engine start will report any failure")
        }
    }

    /// Try to start the audio engine with retry logic for when another app
    /// holds the mic. Waits briefly and retries if the first attempt fails.
    ///
    /// Uses `Task.sleep` (cooperative) instead of `Thread.sleep` so the
    /// retry backoff never blocks the calling thread — critical when invoked
    /// from a `@MainActor` context while Core Audio is busy (e.g. music playing).
    ///
    /// Each `engine.start()` attempt is raced against a 4s timeout via a
    /// detached task. `engine.start()` is a synchronous Core Audio call that
    /// can block indefinitely on a freshly-switched Bluetooth audio unit
    /// (AirPods, headsets) — without the timeout the calling Task hangs
    /// forever and the UI stays stuck on "Loading...". With the timeout, we
    /// surface a clear actionable error and let the user pick a different
    /// input device.
    static func startEngine(_ engine: AVAudioEngine, retries: Int = 5) async throws {
        var lastError: Error?

        for attempt in 1...retries {
            do {
                if engine.isRunning {
                    if attempt > 1 {
                        print("[Sonotexta] Audio engine already running on attempt \(attempt)")
                    }
                    return
                }
                try await attemptTimedStart(engine)
                if attempt > 1 {
                    print("[Sonotexta] Audio engine started on attempt \(attempt)")
                }
                return
            } catch {
                lastError = error
                print("[Sonotexta] Audio engine start attempt \(attempt)/\(retries) failed: \(error.localizedDescription)")
                if attempt < retries {
                    // Progressive backoff — cooperative sleep, does not block the thread
                    try await Task.sleep(nanoseconds: UInt64(0.3 * Double(attempt) * 1_000_000_000))
                }
            }
        }

        // 3.16.4-beta.1: device-override fallback. If every attempt failed
        // while a per-app input override is active, the override device is
        // the likely culprit (Tahoe C920-class -10868: the AU can't
        // renegotiate the USB device's format). Rather than dying silently —
        // which read as "the app just stops working" in the field — re-point
        // the AU at the system default input and try once more. The override
        // SETTING is left untouched; we only fall back for this session and
        // tell the user via .audioInputFellBackToDefault.
        if AppSettings.shared.selectedInputDeviceUID != nil {
            print("[Sonotexta] All attempts failed with a device override set — falling back to system default input")
            guard resetToSystemDefaultInput(on: engine) else {
                throw lastError ?? NSError(domain: "Sonotexta.audio", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone and default-input fallback could not be configured. Choose another input device."])
            }
            do {
                try await attemptTimedStart(engine)
                print("[Sonotexta] Audio engine started on SYSTEM DEFAULT input (override device unavailable)")
                NotificationCenter.default.post(name: .audioInputFellBackToDefault, object: nil)
                return
            } catch {
                lastError = error
                print("[Sonotexta] Fallback to system default input also failed: \(error.localizedDescription)")
            }
        }

        throw lastError ?? NSError(domain: "Sonotexta", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start audio engine after \(retries) attempts. Try switching the microphone in Settings → Engine (e.g., to System Default), or disconnect and reconnect your Bluetooth headset."])
    }

    /// Single engine.start() attempt raced against a 4s timeout.
    /// `engine.start()` is a synchronous Core Audio call that can block
    /// indefinitely on a freshly-switched Bluetooth audio unit — the timeout
    /// keeps the calling Task from hanging forever.
    private static func attemptTimedStart(_ engine: AVAudioEngine) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // engine.prepare() + engine.start() are synchronous.
                // Run on a detached task so the timeout race below can
                // actually fire if Core Audio hangs.
                try await Task.detached(priority: .userInitiated) {
                    engine.prepare()
                    try engine.start()
                }.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                throw NSError(
                    domain: "Sonotexta.audio",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "engine.start() timed out after 4s (audio unit may be hung)"]
                )
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - IO Reconfiguration handling (Bluetooth profile flips, mic disconnect)

    /// Subscribe to `AVAudioEngineConfigurationChange` and re-run the supplied
    /// `installTap` closure when the system reconfigures the audio IO unit.
    ///
    /// Background: when a Bluetooth headset (AirPods Max, etc.) is selected as
    /// input, macOS flips the device profile from A2DP (output-only) to
    /// HFP/SCO (bidirectional with mic) within ~100ms of recording start. The
    /// profile flip triggers a CoreAudio IO-unit reconfiguration, which makes
    /// AVAudioEngine **automatically stop itself** (Apple's documented
    /// behavior). Without re-arming after this event, the engine appears to
    /// the user as "Listening..." forever with no audio frames flowing. The
    /// same notification fires for other system events (sample-rate change,
    /// headphone plug/unplug, route change), so the observer is engine-wide
    /// defense for all audio capture, not just Bluetooth.
    ///
    /// The returned `NSObjectProtocol` token is the observer; callers MUST
    /// retain it for the duration of the capture session and pass it to
    /// `NotificationCenter.default.removeObserver(_:)` during cleanup.
    ///
    /// `setupTap` receives the engine and is responsible for re-installing the
    /// tap against the current native format. Callers must not start the
    /// engine inside `setupTap`; this helper restarts it for you.
    ///
    /// Reconfig attempts are capped at 5 per session to prevent infinite
    /// loops when a misbehaving device never stabilizes.
    static func installReconfigObserver(
        for engine: AVAudioEngine,
        engineName: String,
        isActive: @escaping () -> Bool,
        setupTap: @escaping (AVAudioEngine) throws -> Void,
        onFatal: @escaping () -> Void
    ) -> NSObjectProtocol {
        var attempts = 0
        let maxAttempts = 5
        let reconfigQueue = DispatchQueue(label: "Sonotexta.audio.reconfig.\(engineName)")
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            reconfigQueue.async {
                attempts += 1
                if attempts > maxAttempts {
                    print("[Sonotexta][\(engineName)-reconfig] Exceeded \(maxAttempts) attempts, giving up — input device may be unstable")
                    return
                }

                guard isActive() else {
                    print("[Sonotexta][\(engineName)-reconfig] Ignoring reconfig while capture is inactive")
                    return
                }

                let nativeFormat = engine.inputNode.outputFormat(forBus: 0)
                print("[Sonotexta][\(engineName)-reconfig] IO unit reconfig fired (#\(attempts)) — native=\(Int(nativeFormat.sampleRate))Hz × \(nativeFormat.channelCount)ch")
                guard nativeFormat.sampleRate > 0 && nativeFormat.channelCount > 0 else {
                    print("[Sonotexta][\(engineName)-reconfig] Native format not ready yet, skipping this round")
                    return
                }

                engine.stop()
                engine.inputNode.removeTap(onBus: 0)

                var swiftError: Error?
                let exception = ObjCExceptionCatcher.catchException {
                    do {
                        try setupTap(engine)
                        try engine.start()
                    } catch {
                        swiftError = error
                    }
                }

                if let exception {
                    print("[Sonotexta][\(engineName)-reconfig] Fatal AVAudioEngine exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason provided")")
                    onFatal()
                    return
                }

                if let swiftError {
                    print("[Sonotexta][\(engineName)-reconfig] Restart failed: \(swiftError.localizedDescription)")
                    return
                }

                print("[Sonotexta][\(engineName)-reconfig] Capture restarted successfully")
            }
        }
        return observer
    }
}

extension Notification.Name {
    /// Posted by `AudioSessionHelper.startEngine` when the user's per-app
    /// input-device override failed to start and capture fell back to the
    /// system default input for this session. DictationManager listens and
    /// surfaces the fallback in the overlay status.
    static let audioInputFellBackToDefault = Notification.Name("SonotextaAudioInputFellBackToDefault")
}

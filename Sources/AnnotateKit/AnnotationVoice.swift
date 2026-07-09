//
//  AnnotationVoice.swift
//
//  On-device dictation for the note field, so the user can talk instead of
//  typing — the fastest way to describe a UI bug while pointing at it.
//
//  iOS 26 (Apple Intelligence devices) picks the new on-device transcriber
//  under the hood as long as `requiresOnDeviceRecognition = true` is set; on
//  earlier iOS versions the same flag drops down to the classic on-device
//  Siri model. No network round-trip either way.
//
//  Host apps must declare in Info.plist:
//    - NSSpeechRecognitionUsageDescription
//    - NSMicrophoneUsageDescription
//

#if DEBUG
import AVFoundation
import Combine
import Speech

@MainActor
final class AnnotationVoice: ObservableObject {

    enum State: Equatable {
        case idle
        case requesting
        case listening
        case denied
        case unavailable
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Live transcript (partial + final). Read while `state == .listening`.
    @Published private(set) var transcript: String = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale = .autoupdatingCurrent) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Locales the speech recognizer can transcribe, sorted by their localized
    /// display name — the settings panel's language picker.
    static var supportedLocaleIdentifiers: [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted { lhs, rhs in
                displayName(forLocaleIdentifier: lhs)
                    .localizedCaseInsensitiveCompare(displayName(forLocaleIdentifier: rhs)) == .orderedAscending
            }
    }

    static func displayName(forLocaleIdentifier id: String) -> String {
        Locale.current.localizedString(forIdentifier: id)?.capitalized(with: .current) ?? id
    }

    /// Only useful to draw a mic button at all — false hides it entirely
    /// (device without a supported locale, e.g. some enterprise MDM lock).
    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    // MARK: - Lifecycle

    func toggle() {
        switch state {
        case .listening: stop()
        default: Task { await start() }
        }
    }

    func start() async {
        guard state != .listening else { return }
        state = .requesting
        transcript = ""

        guard await ensurePermissions() else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }

        do {
            try configureAudioSession()
        } catch {
            state = .failed("audio: \(error.localizedDescription)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Foundation on-device path — never leaves the device.
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(iOS 16, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanup()
            state = .failed("engine: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.stop() }
                }
                if let error = error as NSError? {
                    // 216/301/1101 = user stopped / recognizer cancelled — not an error to surface.
                    let benign: Set<Int> = [216, 301, 1101, 203]
                    if !benign.contains(error.code) {
                        self.state = .failed("recognizer: \(error.localizedDescription)")
                    }
                    self.cleanup()
                }
            }
        }

        state = .listening
    }

    func stop() {
        guard state == .listening || state == .requesting else { return }
        request?.endAudio()
        cleanup()
        state = .idle
    }

    // MARK: - Permissions

    private func ensurePermissions() async -> Bool {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            state = .denied
            return false
        }
        let micGranted: Bool = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard micGranted else {
            state = .denied
            return false
        }
        return true
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func cleanup() {
        task?.cancel()
        task = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    deinit {
        Task { @MainActor [audioEngine] in
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }
}
#endif

import AVFoundation
import Combine
import UIKit

/// Records only after the user taps Listen. ShazamKit generates a fingerprint locally; the sample
/// is deleted before that fingerprint is sent in one community recognition request.
@MainActor
final class MusicRecognizer: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = MusicRecognizer()

    enum Phase: Equatable {
        case idle, requestingPermission, listening, matching
        case found(RecognizedSong), noMatch, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var cooldownUntil: Date?
    private lazy var operation = RecognitionOperation<URL, RecognitionSignature.Payload, RecognizedSong>(
        authorize: { [weak self] in
            guard let self else { throw CancellationError() }
            let allowed = await AVAudioApplication.requestRecordPermission()
            try Task.checkCancellation()
            guard allowed else { throw RecordingError.permissionDenied }
            try await self.waitUntilActive()
        },
        capture: { [weak self] check in
            guard let self else { throw CancellationError() }
            let reservation = PlayerController.shared.reserveAudioForMusicRecognition { [weak self] in self?.stop() }
            do { try check() } catch {
                PlayerController.shared.releaseAudioForMusicRecognition(reservation)
                throw error
            }
            self.playbackReservation = reservation
            try self.configureRecordingSession(check: check)
            try check()
            return try await self.recordSample(check: check)
        },
        prepare: { sample in try await RecognitionSignature.make(from: sample) },
        match: { signature in
            try await RecognitionAPI.recognize(signature: signature.data, sampleDuration: signature.duration)
        },
        cleanup: { [weak self] in
            self?.finishRecording(error: CancellationError())
            self?.restorePlaybackSession()
            self?.removeSample()
        },
        state: { [weak self] event in self?.receive(event) }
    )
    private var recordingTimeout: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var recordingCompletion: CheckedContinuation<URL, Error>?
    private var sampleFile: URL?
    private var playbackReservation: UUID?
    private var previousSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                                  options: AVAudioSession.CategoryOptions)?
    private var observers: [NSObjectProtocol] = []

    private enum RecordingError: Error {
        case permissionDenied, microphoneUnavailable, recordingFailed

        var message: String {
            switch self {
            case .permissionDenied:
                return String(localized: "Consenti l’accesso al microfono nelle impostazioni per riconoscere un brano.")
            case .microphoneUnavailable:
                return String(localized: "Il microfono non è disponibile. Controlla l’ingresso audio e riprova.")
            case .recordingFailed:
                return String(localized: "Impossibile registrare il campione audio. Riprova.")
            }
        }
    }

    private override init() {
        super.init()
        // A crash or force-quit can bypass cleanup. Recordings never belong in Documents or backups.
        try? FileManager.default.removeItem(at: Self.recordingFolder)
        observeLifecycle()
    }

    /// The initial sheet is informational: this is called only by its explicit listening action.
    func start() {
        if let cooldownUntil, Date.now < cooldownUntil {
            phase = .failed(RecognitionAPI.Failure.rateLimited.localizedDescription)
            return
        }
        operation.start()
    }

    /// Synchronous microphone/session cleanup lets playback controls safely reclaim the session.
    func stop() { operation.cancel() }

    private func receive(_ event: RecognitionOperation<URL, RecognitionSignature.Payload, RecognizedSong>.Event) {
        switch event {
        case .idle: phase = .idle
        case .requestingPermission: phase = .requestingPermission
        case .listening: phase = .listening
        case .matching: phase = .matching
        case .found(let song): phase = .found(song)
        case .noMatch: phase = .noMatch
        case .failed(let error):
            if let error = error as? RecordingError { phase = .failed(error.message) }
            else if let error = error as? RecognitionSignature.Failure { phase = .failed(error.localizedDescription) }
            else if let error = error as? RecognitionAPI.Failure {
                if error == .rateLimited { cooldownUntil = Date.now.addingTimeInterval(60) }
                phase = .failed(error.localizedDescription)
            } else {
                // Never echo raw OS errors, request details or remote JSON in the interface.
                phase = .failed(String(localized: "Il servizio di riconoscimento non è disponibile. Riprova più tardi."))
            }
        }
    }

    private func waitUntilActive() async throws {
        // Permission can return a moment before UIKit becomes active again. Wait briefly for that
        // transition; cancellation prevents permission granted after Stop from starting capture.
        for _ in 0..<40 {
            try Task.checkCancellation()
            if UIApplication.shared.applicationState == .active { return }
            if UIApplication.shared.applicationState == .background { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    private func configureRecordingSession(check: () throws -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        previousSession = (session.category, session.mode, session.categoryOptions)
        do {
            try check()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try check()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try check()
            try session.setActive(true)
            try check()
            guard session.isInputAvailable else { throw RecordingError.microphoneUnavailable }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RecordingError.microphoneUnavailable
        }
    }

    private func recordSample(check: () throws -> Void) async throws -> URL {
        do {
            try check()
            try FileManager.default.createDirectory(at: Self.recordingFolder, withIntermediateDirectories: true)
            let file = Self.recordingFolder.appending(path: "\(UUID().uuidString).m4a")
            sampleFile = file
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            self.recorder = recorder
            recorder.delegate = self
            return try await withCheckedThrowingContinuation { completion in
                recordingCompletion = completion
                // A bounded sample leaves room for AAC frame padding beneath the signature's 12 s window.
                do {
                    try check()
                    guard recorder.prepareToRecord() else { throw RecordingError.recordingFailed }
                    try check()
                    guard recorder.record(forDuration: 10) else { throw RecordingError.recordingFailed }
                    try check()
                } catch {
                    // A synchronous audio notification may already have cleared self.recorder.
                    recorder.stop()
                    finishRecording(error: error)
                    return
                }
                recordingTimeout = Task { [weak self, weak recorder] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard let self, let recorder, self.recorder === recorder else { return }
                    self.finishRecording(error: RecordingError.recordingFailed)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RecordingError.recordingFailed
        }
    }

    private func finishRecording(error: Error? = nil) {
        recordingTimeout?.cancel()
        recordingTimeout = nil
        let completion = recordingCompletion
        recordingCompletion = nil
        let recorder = recorder
        self.recorder = nil
        recorder?.delegate = nil
        recorder?.stop()
        guard let completion else { return }
        if let error { completion.resume(throwing: error) }
        else if let file = sampleFile { completion.resume(returning: file) }
        else { completion.resume(throwing: RecordingError.recordingFailed) }
    }

    private func restorePlaybackSession() {
        if let previous = previousSession {
            previousSession = nil
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.category, mode: previous.mode, options: previous.options)
        }
        if let reservation = playbackReservation {
            playbackReservation = nil
            PlayerController.shared.releaseAudioForMusicRecognition(reservation)
        }
    }

    private func removeSample() {
        if let sampleFile { try? FileManager.default.removeItem(at: sampleFile) }
        sampleFile = nil
    }

    private static var recordingFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Seaglass-recognition", directoryHint: .isDirectory)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.finishRecording(error: flag ? nil : RecordingError.recordingFailed)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.finishRecording(error: RecordingError.recordingFailed)
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening || self.phase == .matching else { return }
                self.stop()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.stop()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening,
                      let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      reason != .categoryChange, reason != .override else { return }
                self.stop()
            }
        })
    }
}

import AVFoundation
import Foundation

@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var savedFileURL: URL?

    private var recorder: AVAudioRecorder?
    private var durationTimer: Timer?

    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let fileName = "voice_\(UUID().uuidString).m4a"
        let url = voiceNotesDirectory().appendingPathComponent(fileName)

        recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
        recorder?.prepareToRecord()
        recorder?.record()
        isRecording = true
        recordingDuration = 0

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.recordingDuration += 0.1
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false

        let url = recorder?.url
        savedFileURL = url
        recorder = nil

        try? AVAudioSession.sharedInstance().setActive(false)
        return url
    }

    func cancelRecording() {
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false
        recorder = nil
    }

    private func voiceNotesDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("VoiceNotes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var durationString: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

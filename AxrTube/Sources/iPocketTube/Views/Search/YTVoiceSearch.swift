#if os(iOS)
import SwiftUI
import AVFoundation
import Speech
import Observation

/// On-device voice search in Russian. Listens only while the sheet is open
/// and gives the audio session back to playback when it closes.
@MainActor
@Observable
final class VoiceSearchRecognizer {
    enum Phase: Equatable { case idle, listening, denied, failed }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))

    func start() async {
        transcript = ""
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else { phase = .denied; return }
        guard let recognizer, recognizer.isAvailable else { phase = .failed; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            phase = .listening
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if isFinal || error != nil { self.stopListening() }
                }
            }
        } catch {
            phase = .failed
            stopListening()
        }
    }

    func stopListening() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if phase == .listening { phase = .idle }
        _ = PlaybackViewModel.activatePlaybackAudioSession(reason: "voice search ended")
    }
}

/// YouTube-style listening sheet: big mic, live transcript, auto-submit.
struct YTVoiceSearchSheet: View {
    let onResult: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recognizer = VoiceSearchRecognizer()
    @State private var submitTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Закрыть")
            }
            Text(headline)
                .font(.system(size: 24, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 90)
                .padding(.horizontal, 24)
            Spacer()
            Button {
                if recognizer.phase == .listening { finish() } else { Task { await recognizer.start() } }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(recognizer.phase == .listening ? YTColor.brandRed : YTColor.secondaryText, in: Circle())
            }
            .accessibilityLabel(recognizer.phase == .listening ? "Закончить" : "Говорить")
            Spacer()
        }
        .foregroundStyle(YTColor.primaryText)
        .padding()
        .background(YTColor.background)
        .task { await recognizer.start() }
        .onChange(of: recognizer.transcript) { _, text in
            // Submit after a short pause in speech, like YouTube.
            submitTask?.cancel()
            guard !text.isEmpty else { return }
            submitTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                finish()
            }
        }
        .onDisappear { recognizer.stopListening() }
    }

    private var headline: String {
        switch recognizer.phase {
        case .denied: "Разрешите доступ к микрофону и распознаванию речи в Настройках"
        case .failed: "Распознавание речи сейчас недоступно"
        case .idle, .listening: recognizer.transcript.isEmpty ? "Говорите…" : recognizer.transcript
        }
    }

    private func finish() {
        let text = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        recognizer.stopListening()
        dismiss()
        if !text.isEmpty { onResult(text) }
    }

    private func close() {
        submitTask?.cancel()
        recognizer.stopListening()
        dismiss()
    }
}
#endif

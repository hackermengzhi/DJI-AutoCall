import AVFoundation
import Speech
import SwiftUI

/// Recognition sees only modem downlink. Synthesized PCM enters the existing
/// modem uplink, never the Mac speakers or a system-wide audio device.
final class RelayCaptionInput {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func use(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }
    func receive(_ data: Data) {
        lock.withLock {
            guard let request, data.count >= 2,
                  let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
                  let output = buffer.floatChannelData?[0] else { return }
            let frames = data.count / 2
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in 0..<frames {
                    let value = Float(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)) / 32768
                    output[i * 2] = value
                    output[i * 2 + 1] = value
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames * 2)
            request.append(buffer)
        }
    }
}

@MainActor
final class AccessibleCallRelay: ObservableObject {
    @Published var textMode = false
    @Published var monitorSpeaker = false
    @Published var monitorOwnSpeech = true
    @Published var connected = false
    @Published var captionsEnabled = false
    @Published var caption = ""
    @Published var transcript: [String] = []
    @Published var sent: [String] = []
    @Published var message = "通话接通后，可以开启字幕并发送文字语音。"
    @Published var synthesizing = false
    @Published var language = "zh-CN"
    @Published var englishVoice = "Samantha"
    @Published var speechRate = 165
    var outputDeviceID: (() -> UInt32?)?
    nonisolated let input = RelayCaptionInput()
    private var speechProcess: Process?
    private var speechTimeout: Task<Void, Never>?
    private var speechToken = UUID()
    private var captionToken = UUID()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotation: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?

    nonisolated func receive(_ pcm: Data) { input.receive(pcm) }

    func setCallConnected(_ value: Bool) {
        guard value != connected else { return }
        connected = value
        if !value {
            stopCaptions()
            stopSpeech()
            message = "通话未接通，文字不会发送。"
        } else {
            transcript.removeAll()
            sent.removeAll()
            message = "音频已连接，正在开启字幕。"
            startCaptions()
        }
    }

    func preparePermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                Task { @MainActor in self?.message = "请在系统设置中允许麦克风权限，以连接通话音频。" }
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    self?.message = status == .authorized
                        ? "通话音频和语音识别权限已准备好。"
                        : "麦克风已允许；字幕还需要在系统设置中允许语音识别。"
                }
            }
        }
    }

    func startCaptions() {
        guard connected else { message = "请先接通电话并等待音频连接。"; return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.connected, !self.captionsEnabled else { return }
                guard status == .authorized else {
                    self.message = "需要在系统设置中允许 DJOneHub 使用语音识别。"; return
                }
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: self.language)),
                      recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                    self.message = "此语言的本机识别暂不可用，请在系统设置中下载对应听写语言后重试。"
                    return
                }
                self.recognizer = recognizer
                self.captionsEnabled = true
                self.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        guard connected, captionsEnabled, let recognizer else { return }
        let token = UUID()
        captionToken = token
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        input.use(request)
        message = "字幕已开启 · 仅在本机识别，识别文字可能有误。"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.captionToken == token, self.captionsEnabled else { return }
                if let result { self.caption = result.bestTranscription.formattedString }
                if result?.isFinal == true {
                    self.rotateRecognition()
                } else if let error {
                    self.stopCaptions()
                    self.message = "字幕已停止：\(error.localizedDescription)"
                }
            }
        }
        rotation?.cancel()
        rotation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, self.captionToken == token else { return }
            self.rotateRecognition()
        }
    }

    private func saveCaption() {
        if !caption.isEmpty {
            transcript.append(caption)
            if transcript.count > 200 { transcript.removeFirst() }
            caption = ""
        }
    }

    private func rotateRecognition() {
        stopRecognition()
        saveCaption()
        beginRecognition()
    }

    private func stopRecognition() {
        captionToken = UUID()
        rotation?.cancel()
        rotation = nil
        input.use(nil)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    func stopCaptions() {
        captionsEnabled = false
        stopRecognition()
        saveCaption()
    }

    func stopSpeech() {
        speechToken = UUID()
        speechTimeout?.cancel()
        speechTimeout = nil
        if let process = speechProcess, process.isRunning { process.terminate() }
        speechProcess = nil
        synthesizing = false
        message = "代说已停止。字幕仍保持原来的状态。"
    }

    func speak(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, textMode else { message = "请先接通电话并开启文字代说。"; return }
        guard !text.isEmpty, text.count <= 600 else { message = "每次请输入 1～600 个字。"; return }
        guard !synthesizing else { message = "正在代说，请先停止或等待完成。"; return }
        guard let device = outputDeviceID?() else {
            message = "模块的通话音频输出还未就绪，文字没有发送。"; return
        }
        let spokenLanguage = Self.speechLanguage(for: text, selected: language)
        let systemVoice = spokenLanguage == "zh-CN" ? "Tingting" : englishVoice
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-a", String(device), "-v", systemVoice, "-r", String(speechRate), text]
        if spokenLanguage == "en-US", englishVoice == "Pocket Alba",
           let resources = Bundle.main.resourceURL {
            let pocket = resources.appendingPathComponent("PocketTTS")
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            process.executableURL = pocket.appendingPathComponent("pocket-tts")
            process.currentDirectoryURL = pocket
            process.arguments = ["generate", "--config", "english.yaml", "--voice", "alba.safetensors",
                                 "--text", text, "--output-path", wav.path]
            startSpeech(process, text: text, playback: (device, wav))
            return
        }
        if monitorOwnSpeech {
            let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
            process.arguments = ["-o", audio.path, "-v", systemVoice,
                                 "-r", String(speechRate), text]
            startSpeech(process, text: text, playback: (device, audio))
            return
        }
        startSpeech(process, text: text)
    }

    private func startSpeech(_ process: Process, text: String, playback: (UInt32, URL)? = nil, cleanup: URL? = nil) {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let token = UUID()
        let useMonitor = monitorOwnSpeech
        speechToken = token
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                guard let self, self.speechToken == token else {
                    if let playback { try? FileManager.default.removeItem(at: playback.1) }
                    return
                }
                if let (device, wav) = playback {
                    if finished.terminationStatus == 0 {
                        let audio = try? AVAudioFile(forReading: wav)
                        guard let audio, Double(audio.length) / audio.processingFormat.sampleRate > 0.05 else {
                            try? FileManager.default.removeItem(at: wav)
                            self.speechTimeout?.cancel()
                            self.speechTimeout = nil
                            self.speechProcess = nil
                            self.synthesizing = false
                            self.message = "未生成可播放的语音，请检查文字与所选声音的语言。"
                            return
                        }
                    }
                    if finished.terminationStatus == 0, self.connected, self.textMode,
                       self.outputDeviceID?() == device, let executable = Bundle.main.executableURL {
                        self.speechTimeout?.cancel()
                        let player = Process()
                        player.executableURL = executable
                        player.arguments = [useMonitor ? "--play-to-modem-monitor" : "--play-to-modem", String(device), wav.path]
                        self.startSpeech(player, text: text, cleanup: wav)
                        return
                    }
                    try? FileManager.default.removeItem(at: wav)
                }
                self.speechTimeout?.cancel()
                self.speechTimeout = nil
                self.speechProcess = nil
                self.synthesizing = false
                self.message = finished.terminationStatus == 0
                    ? "代说播放已结束，请根据对方回应确认是否听清。"
                    : "代说已停止或音频输出失败。"
            }
        }
        do {
            try process.run()
            speechProcess = process
            synthesizing = true
            if playback == nil { sent.append(text) }
            if sent.count > 100 { sent.removeFirst() }
            message = playback == nil ? "正在向模块通话音频输出代说。可随时点击停止。" : "正在本机生成语音…"
            // Bound a stuck device-output process; all speech has one owner.
            speechTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled, let self, self.speechToken == token else { return }
                self.stopSpeech()
                self.message = "代说超过时限，已自动停止。"
            }
        } catch {
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            if let playback { try? FileManager.default.removeItem(at: playback.1) }
            synthesizing = false
            speechProcess = nil
            message = "无法启动代说：\(error.localizedDescription)"
        }
    }

    nonisolated static func speechLanguage(for text: String, selected: String) -> String {
        let hasChinese = text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x3134F).contains(scalar.value)
        }
        return hasChinese ? "zh-CN" : selected
    }

    static func selfTestStopControl() {
        precondition(speechLanguage(for: "您好", selected: "en-US") == "zh-CN")
        precondition(speechLanguage(for: "Hello", selected: "en-US") == "en-US")
        let relay = AccessibleCallRelay()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try! process.run()
        relay.speechProcess = process
        relay.synthesizing = true
        relay.stopSpeech()
        process.waitUntilExit()
        precondition(!process.isRunning && !relay.synthesizing && relay.speechProcess == nil)
        precondition(relay.message.hasPrefix("代说已停止"))
    }

    nonisolated static func pcm8k(_ samples: [Float], rate: Double) -> Data {
        guard samples.count > 1, rate > 0 else { return Data() }
        var output = Data()
        let count = Int(Double(samples.count - 1) * 8000 / rate)
        output.reserveCapacity(count * 2)
        for frame in 0..<count {
            let position = Double(frame) * rate / 8000
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let value = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            var sample = Int16(max(-1, min(1, value)) * 32767).littleEndian
            withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
        }
        return output
    }
}

struct AccessibleCallView: View {
    @EnvironmentObject private var calls: CallCenter
    @ObservedObject var relay: AccessibleCallRelay
    @State private var draft = ""
    private let phrases = [
        "您好，我正在使用文字转语音与您通话，请稍等我打字回复。",
        "请您说慢一点，一次说一句，谢谢。",
        "请再说一遍。",
        "好的，我明白了，谢谢。"
    ]
    private let supportSteps: [(String, String)] = [
        ("转人工", "Could I speak to someone about expired points, please?"),
        ("说明诉求", "I’m helping a member get their expired points back. They tried to sign in from China, but the verification texts didn’t come through. They earned the points through purchases. Could you check whether a one-time reinstatement is possible?"),
        ("核验时请稍等", "One moment, please. I’ll let the account holder take over for verification."),
        ("请主管复核", "I understand. Could a supervisor review the request and see if an exception is possible?"),
        ("确认结果", "Thanks. Could you confirm what happens next and give me a reference number?")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("无障碍通话").font(.title2.bold())
                Label(relay.connected ? "通话音频已连接" : "等待电话接通", systemImage: relay.connected ? "phone.fill" : "phone")
                    .foregroundStyle(relay.connected ? .green : .secondary)
                if !relay.connected {
                    Button("准备通话与字幕权限") { relay.preparePermissions() }
                }
                if let error = calls.lastActionError { Text(error).foregroundStyle(.red) }
                Picker("通话语言", selection: $relay.language) {
                    Text("普通话").tag("zh-CN")
                    Text("English").tag("en-US")
                }
                .disabled(relay.synthesizing)
                .onChange(of: relay.language) { _ in
                    if relay.captionsEnabled {
                        relay.stopCaptions()
                        relay.startCaptions()
                    }
                }
                if relay.language == "en-US" {
                    Picker("英语声音", selection: $relay.englishVoice) {
                        Text("Samantha · 美式").tag("Samantha")
                        Text("Karen · 澳式").tag("Karen")
                        Text("Alba · Pocket TTS").tag("Pocket Alba")
                    }.disabled(relay.synthesizing)
                }
                Stepper("代说语速：\(relay.speechRate)", value: $relay.speechRate, in: 130...200, step: 5)
                    .disabled(relay.synthesizing || (relay.language == "en-US" && relay.englishVoice == "Pocket Alba"))
                Toggle("代说耳返（同时听到发给对方的语音）", isOn: $relay.monitorOwnSpeech)
                    .disabled(relay.synthesizing)
                Toggle("播放对方声音", isOn: Binding(
                    get: { relay.monitorSpeaker }, set: { calls.setSpeakerMonitoring($0) }
                ))
                Toggle("文字代说（不传送麦克风声音）", isOn: Binding(
                    get: { relay.textMode }, set: { calls.setAccessibleTextMode($0) }
                ))
                HStack {
                    Text("对方说的话").font(.headline)
                    Spacer()
                    Button(relay.captionsEnabled ? "关闭字幕" : "开启字幕") {
                        if relay.captionsEnabled { relay.stopCaptions() } else { relay.startCaptions() }
                    }.disabled(!relay.connected)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(relay.transcript.suffix(3).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.title3)
                    }
                    Text(relay.caption.isEmpty ? "等待对方说话…" : String(relay.caption.suffix(240)))
                        .font(.title3).foregroundStyle(relay.caption.isEmpty ? .secondary : .primary)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text("你想说的话").font(.headline)
                TextEditor(text: $draft).font(.title3).frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                    .accessibilityLabel("输入要通过电话说出的文字")
                HStack {
                    Button(relay.synthesizing ? "代说中…" : "发送到电话") { relay.speak(draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!relay.connected || !relay.textMode || relay.synthesizing || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 600)
                    Button("停止代说") { relay.stopSpeech() }
                    Spacer()
                    Text("\(draft.count)/600").font(.caption).foregroundStyle(.secondary)
                }
                if relay.language == "en-US" {
                    DisclosureGroup("客服通话步骤") {
                        ForEach(supportSteps.indices, id: \.self) { index in
                            Button(supportSteps[index].0) { draft = supportSteps[index].1 }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if relay.connected && relay.textMode {
                    Button("本人接管（开启麦克风与监听）") {
                        calls.setAccessibleTextMode(false)
                        if calls.isMuted { calls.toggleMute() }
                        calls.setSpeakerMonitoring(true)
                    }
                }
                Text("常用回复（点选后可编辑，再发送）").font(.subheadline)
                ForEach(phrases, id: \.self) { phrase in
                    Button(phrase) { draft = phrase }.multilineTextAlignment(.leading)
                }
                Text(relay.message).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                if let last = relay.sent.last { Text("最近代说内容：\(last)").font(.caption) }
                Text("字幕与文字仅保留在本次应用内存中。字幕可能有误，请核对号码、金额等重要内容。")
                    .font(.caption).foregroundStyle(.secondary)
                if calls.activeCall != nil {
                    Button("挂断电话", role: .destructive) { calls.hangup() }.buttonStyle(.bordered)
                }
            }.padding(20)
        }
    }
}

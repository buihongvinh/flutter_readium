import AVFoundation
import PDFKit
import ReadiumShared
import ReadiumNavigator

/// TTS navigator dành riêng cho PDF publications trên iOS.
///
/// Trích xuất văn bản từ PDF bằng Apple PDFKit (framework tích hợp sẵn,
/// không cần thư viện bên ngoài), sau đó phát bằng AVSpeechSynthesizer.
///
/// Tích hợp hoàn toàn với giao thức `FlutterTimebasedNavigator` để Flutter side
/// hoạt động giống hệt như với EPUB TTS — cùng các event channel, cùng lệnh
/// play/pause/next/previous.
public class FlutterPdfTtsNavigator: NSObject, FlutterTimebasedNavigator, AVSpeechSynthesizerDelegate {

    private let TAG = "FlutterPdfTtsNavigator"

    // MARK: - FlutterTimebasedNavigator

    public let publication: Publication
    public let initialLocator: Locator?
    public var currentLocator: Locator? { buildCurrentLocator() }
    public var listener: (any TimebasedListener)?

    // MARK: - TTS engine

    private let synthesizer = AVSpeechSynthesizer()
    internal var preferences: TTSPreferences

    // MARK: - Extracted content

    struct Sentence {
        let text: String
        let pageIndex: Int    // 0-based
        let totalPages: Int
    }

    private var sentences: [Sentence] = []
    private var currentIndex: Int = 0

    // MARK: - Playback state

    private var isReady = false
    private var pendingPlayRequested = false
    private var pendingPlayLocator: Locator?
    private var isPlaying = false
    private var isPaused  = false

    // MARK: - Init

    public init(
        publication: Publication,
        preferences: TTSPreferences = TTSPreferences(),
        initialLocator: Locator?
    ) {
        self.publication    = publication
        self.preferences    = preferences
        self.initialLocator = initialLocator
        super.init()
    }

    // MARK: - FlutterTimebasedNavigator — lifecycle

    public func initNavigator() async {
        synthesizer.delegate = self

        listener?.timebasedNavigator(self, didChangeState:
            ReadiumTimebasedState(state: .loading))

        do {
            let extracted = try await extractSentences()
            self.sentences = extracted

            if sentences.isEmpty {
                FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(
                    FlutterReadiumError(
                        message: "PDF không chứa văn bản có thể trích xuất. File có thể là ảnh scan.",
                        code: "pdf_no_text",
                        data: nil
                    )
                )
                listener?.timebasedNavigator(self, didChangeState:
                    ReadiumTimebasedState(state: .ended))
                return
            }

            // Nhảy đến trang gần nhất với initialLocator nếu có
            if let loc = initialLocator, let pos = loc.locations.position {
                let targetPage = pos - 1 // 0-based
                if let idx = sentences.firstIndex(where: { $0.pageIndex >= targetPage }) {
                    currentIndex = idx
                }
            }

            debugPrint(TAG, "initNavigator: \(sentences.count) câu từ \(sentences.last?.totalPages ?? 0) trang PDF")
            isReady = true
            if pendingPlayRequested {
                let locator = pendingPlayLocator
                pendingPlayRequested = false
                pendingPlayLocator = nil
                Task { @MainActor in
                    await self.play(fromLocator: locator)
                }
            } else {
                listener?.timebasedNavigator(self, didChangeState:
                    ReadiumTimebasedState(state: .paused, currentLocator: buildCurrentLocator()))
            }

        } catch {
            debugPrint(TAG, "initNavigator error: \(error)")
            FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(
                FlutterReadiumError(
                    message: "Lỗi khởi tạo PDF TTS: \(error.localizedDescription)",
                    code: "pdf_tts_init_error",
                    data: nil
                )
            )
            listener?.timebasedNavigator(self, encounteredError: error,
                withDescription: "PdfTtsInitError")
        }
    }

    /// Không cần: AVSpeechSynthesizerDelegate xử lý tất cả sự kiện.
    public func setupNavigatorListeners() {}

    @MainActor
    public func dispose() {
        pendingPlayRequested = false
        pendingPlayLocator = nil
        isReady = false
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = nil
        isPlaying = false
        isPaused  = false
        listener?.timebasedNavigator(self, didChangeState:
            ReadiumTimebasedState(state: .ended))
        listener = nil
        debugPrint(TAG, "dispose()")
    }

    // MARK: - FlutterTimebasedNavigator — playback control

    @MainActor
    public func play(fromLocator: Locator?) async {
        guard isReady else {
            pendingPlayRequested = true
            pendingPlayLocator = fromLocator
            return
        }

        // Nhảy đến trang từ locator nếu được cung cấp
        if let loc = fromLocator, let pos = loc.locations.position {
            let targetPage = pos - 1 // 0-based
            if let idx = sentences.firstIndex(where: { $0.pageIndex >= targetPage }) {
                synthesizer.stopSpeaking(at: .immediate)
                currentIndex = idx
            }
        }

        if isPaused && synthesizer.isPaused {
            // Tiếp tục từ điểm bị tạm dừng trong AVSpeechSynthesizer
            synthesizer.continueSpeaking()
            isPaused  = false
            isPlaying = true
        } else {
            isPlaying = true
            isPaused  = false
            speakCurrentSentence()
        }
    }

    @MainActor
    public func pause() async {
        pendingPlayRequested = false
        pendingPlayLocator = nil
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        isPaused  = true
        listener?.timebasedNavigator(self, didChangeState:
            ReadiumTimebasedState(state: .paused, currentLocator: buildCurrentLocator()))
        debugPrint(TAG, "pause() tại câu \(currentIndex)/\(sentences.count)")
    }

    @MainActor
    public func resume() async {
        await play(fromLocator: nil)
    }

    @MainActor
    public func togglePlayPause() async {
        if isPlaying { await pause() } else { await resume() }
    }

    @MainActor
    public func seekForward() async -> Bool {
        guard isReady else { return false }
        synthesizer.stopSpeaking(at: .immediate)
        if currentIndex < sentences.count - 1 { currentIndex += 1 }
        if isPlaying { speakCurrentSentence() } else { emitCurrentLocator() }
        return true
    }

    @MainActor
    public func seekBackward() async -> Bool {
        guard isReady else { return false }
        synthesizer.stopSpeaking(at: .immediate)
        if currentIndex > 0 { currentIndex -= 1 }
        if isPlaying { speakCurrentSentence() } else { emitCurrentLocator() }
        return true
    }

    @MainActor
    public func seek(toLocator: Locator) async -> Bool {
        guard isReady else {
            pendingPlayRequested = true
            pendingPlayLocator = toLocator
            return true
        }
        await play(fromLocator: toLocator)
        return true
    }

    @MainActor
    public func seek(toProgression progression: Double) async -> Bool {
        guard isReady, !sentences.isEmpty else { return false }
        synthesizer.stopSpeaking(at: .immediate)
        let targetIndex = Int((Double(sentences.count - 1) * progression).rounded())
        currentIndex = min(max(targetIndex, 0), sentences.count - 1)
        if isPlaying { speakCurrentSentence() } else { emitCurrentLocator() }
        return true
    }

    @MainActor public func seek(toOffset: Double) async -> Bool { return false }
    @MainActor public func seekRelative(byOffsetSeconds: Double) async -> Bool { return false }
    @MainActor public func decorationsUpdated() {}

    // MARK: - TTS preferences

    public func ttsSetPreferences(prefs: TTSPreferences) {
        preferences.rate = prefs.rate
        preferences.pitch = prefs.pitch
        preferences.voiceIdentifier = prefs.voiceIdentifier
        preferences.overrideLanguage = prefs.overrideLanguage
    }

    public func ttsSetVoice(voiceIdentifier: String) throws {
        guard AVSpeechSynthesisVoice(identifier: voiceIdentifier) != nil else {
            throw ReadiumError.voiceNotFound
        }
        preferences.voiceIdentifier = voiceIdentifier
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                   didStart utterance: AVSpeechUtterance) {
        emitCurrentLocator()
        listener?.timebasedNavigator(self, didChangeState:
            ReadiumTimebasedState(state: .playing, currentLocator: buildCurrentLocator()))
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                   didFinish utterance: AVSpeechUtterance) {
        guard isPlaying else { return }
        currentIndex += 1

        if currentIndex >= sentences.count {
            isPlaying = false
            listener?.timebasedNavigator(self, didChangeState:
                ReadiumTimebasedState(state: .ended))
            debugPrint(TAG, "Đọc xong toàn bộ PDF")
        } else {
            speakCurrentSentence()
        }
    }

    /// Bị hủy chủ động (stopSpeaking) — không cần xử lý thêm.
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                   didCancel utterance: AVSpeechUtterance) {}

    // MARK: - Private: TTS

    private func speakCurrentSentence() {
        guard currentIndex < sentences.count else {
            isPlaying = false
            listener?.timebasedNavigator(self, didChangeState:
                ReadiumTimebasedState(state: .ended))
            return
        }

        let sentence  = sentences[currentIndex]
        let utterance = AVSpeechUtterance(string: sentence.text)

        // Áp dụng voice từ preferences (identifier ưu tiên hơn language code)
        if let voiceId = preferences.voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceId)
        } else if let lang = preferences.overrideLanguage {
            utterance.voice = AVSpeechSynthesisVoice(language: "\(lang)")
        }

        utterance.rate            = preferences.rate ?? AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = preferences.pitch ?? 1.0

        debugPrint(TAG, "speak[\(currentIndex)] page=\(sentence.pageIndex) — \"\(String(sentence.text.prefix(60)))\"")
        synthesizer.speak(utterance)
    }

    // MARK: - Private: Locator

    private func emitCurrentLocator() {
        guard let locator = buildCurrentLocator() else { return }
        listener?.timebasedNavigator(self, reachedLocator: locator, segmentDuration: nil)
    }

    private func buildCurrentLocator() -> Locator? {
        guard !sentences.isEmpty else { return nil }
        let idx      = min(currentIndex, sentences.count - 1)
        let sentence = sentences[idx]

        guard let link = publication.readingOrder.first else { return nil }

        let progression = sentences.isEmpty ? 0.0 : Double(idx) / Double(sentences.count)

        return Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .pdf,
            locations: .init(
                totalProgression: progression,
                position: sentence.pageIndex + 1  // 1-based cho Flutter side
            )
        )
    }

    // MARK: - Private: Text extraction

    /// Trích xuất văn bản từ tất cả các trang PDF bằng PDFKit.
    /// Chạy trong Task.detached (background) để không block Main thread.
    private func extractSentences() async throws -> [Sentence] {
        guard let pdfLink = publication.readingOrder.first else {
            throw FlutterPdfTtsError.noPdfLink
        }

        let urlStr = pdfLink.url().string
        let pdfURL: URL

        if let resolvedURL = URL(string: urlStr), resolvedURL.isFileURL {
            pdfURL = resolvedURL
        } else if let resolvedURL = URL(string: urlStr),
                  ["http", "https"].contains(resolvedURL.scheme?.lowercased() ?? "") {
            pdfURL = try await downloadToTemp(url: resolvedURL)
        } else if urlStr.hasPrefix("/") {
            pdfURL = URL(fileURLWithPath: urlStr)
        } else {
            throw FlutterPdfTtsError.invalidURL(urlStr)
        }

        return try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: pdfURL) else {
                throw FlutterPdfTtsError.cannotOpenPdf(pdfURL.path)
            }

            let totalPages = document.pageCount
            var result: [Sentence] = []

            for pageIdx in 0 ..< totalPages {
                guard let page    = document.page(at: pageIdx) else { continue }
                let pageText  = page.string ?? ""
                let trimmed   = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                for sentence in FlutterPdfTtsNavigator.splitIntoSentences(trimmed) {
                    result.append(Sentence(text: sentence, pageIndex: pageIdx, totalPages: totalPages))
                }
            }

            return result
        }.value
    }

    private func downloadToTemp(url: URL) async throws -> URL {
        let (localURL, _) = try await URLSession.shared.download(from: url)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.moveItem(at: localURL, to: tempURL)
        return tempURL
    }

    // MARK: - Static: Sentence splitting

    /// Tách văn bản thành các câu dùng `enumerateSubstrings(bySentences)`.
    /// iOS tự nhận diện ngôn ngữ — hoạt động tốt với tiếng Việt, Anh, Đan Mạch, v.v.
    static func splitIntoSentences(_ text: String) -> [String] {
        var result: [String] = []

        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences]) { sub, _, _, _ in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count > 2 else { return }

            // Câu quá dài (> 400 ký tự) → tách thêm tại dấu phẩy/xuống dòng
            if trimmed.count > 400 {
                let sub = trimmed
                    .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.count > 2 }
                result.append(contentsOf: sub)
            } else {
                result.append(trimmed)
            }
        }

        return result.isEmpty
            ? [text.trimmingCharacters(in: .whitespacesAndNewlines)]
            : result
    }
}

// MARK: - Error types

enum FlutterPdfTtsError: LocalizedError {
    case noPdfLink
    case invalidURL(String)
    case cannotOpenPdf(String)

    var errorDescription: String? {
        switch self {
        case .noPdfLink:               return "Không tìm thấy link PDF trong publication readingOrder"
        case .invalidURL(let url):     return "URL PDF không hợp lệ: \(url)"
        case .cannotOpenPdf(let path): return "Không thể mở file PDF: \(path)"
        }
    }
}

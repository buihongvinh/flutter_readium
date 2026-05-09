package dk.nota.flutter_readium.navigators

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import dk.nota.flutter_readium.FlutterTtsPreferences
import dk.nota.flutter_readium.ReadiumReader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import java.io.File
import java.util.Locale

private const val TAG = "PdfTtsNavigator"

/**
 * TTS navigator cho PDF publications.
 *
 * Trích xuất văn bản từ PDF bằng Apache PDFBox Android, sau đó phát bằng
 * Android TextToSpeech. Tích hợp với hệ thống sự kiện hiện có (TimedBasedState,
 * TextLocator) để Flutter side không cần thay đổi gì.
 *
 * Luồng hoạt động:
 *   ttsEnable() → initialize() → play() → speakCurrentSentence() → onDone → speakNextSentence()
 */
class PdfTtsNavigator(
    private val context: Context,
    private val pdfFilePath: String,
    private val publication: Publication,
    private var preferences: FlutterTtsPreferences,
    private val timebaseListener: TimebasedNavigator.TimebasedListener,
) : TextToSpeech.OnInitListener {

    // ── Coroutine scopes ──────────────────────────────────────────────────────
    private val ioScope   = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // ── TTS engine ────────────────────────────────────────────────────────────
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingPlayRequested = false
    private var pendingPlayLocator: Locator? = null

    // ── Văn bản đã trích xuất ─────────────────────────────────────────────────
    /** Đơn vị tối thiểu được đọc — một câu trong một trang. */
    data class Sentence(
        val text: String,
        val pageIndex: Int,   // 0-based
        val totalPages: Int,
    )

    private val sentences   = mutableListOf<Sentence>()
    private var currentIdx  = 0

    // ── Trạng thái phát ──────────────────────────────────────────────────────
    private var isPlaying = false
    private var isPaused  = false

    // ─── Vòng đời ────────────────────────────────────────────────────────────

    /**
     * Trích xuất văn bản PDF và khởi động TTS engine.
     * Phải được gọi trước [play].
     */
    suspend fun initialize() {
        timebaseListener.onTimebasedPlaybackStateChanged(TimebasedNavigator.TimebasedState.Loading)

        try {
            // Trích xuất text trên IO thread để không chặn UI
            val extracted = withContext(Dispatchers.IO) {
                extractSentencesFromPdf(pdfFilePath)
            }

            sentences.clear()
            sentences.addAll(extracted)

            if (sentences.isEmpty()) {
                ReadiumReader.emitError(
                    message = "PDF không chứa văn bản có thể trích xuất. " +
                              "File có thể là PDF dạng ảnh scan.",
                    code = "pdf_no_text",
                )
                timebaseListener.onTimebasedPlaybackStateChanged(
                    TimebasedNavigator.TimebasedState.Failure
                )
                return
            }

            Log.d(TAG, "initialize: ${sentences.size} câu từ " +
                       "${sentences.lastOrNull()?.totalPages ?: 0} trang PDF")

            // Khởi động TTS engine trên Main thread
            withContext(Dispatchers.Main) {
                tts = TextToSpeech(context, this@PdfTtsNavigator)
            }

        } catch (e: Exception) {
            Log.e(TAG, "initialize lỗi: $e")
            ReadiumReader.emitError(
                message = "Lỗi khởi tạo PDF TTS: ${e.message}",
                code    = "pdf_tts_init_error",
            )
            timebaseListener.onTimebasedPlaybackStateChanged(
                TimebasedNavigator.TimebasedState.Failure
            )
        }
    }

    /** Callback từ TextToSpeech khi engine đã sẵn sàng. */
    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            ttsReady = true
            applyPreferences()
            setupUtteranceListener()
            if (pendingPlayRequested) {
                val locator = pendingPlayLocator
                pendingPlayRequested = false
                pendingPlayLocator = null
                mainScope.launch { play(locator) }
            } else {
                timebaseListener.onTimebasedPlaybackStateChanged(
                    TimebasedNavigator.TimebasedState.Paused
                )
            }
            Log.d(TAG, "TTS engine sẵn sàng, ${sentences.size} câu")
        } else {
            Log.e(TAG, "Không thể khởi tạo TTS engine (status=$status)")
            ReadiumReader.emitError(
                message = "Không thể khởi tạo TTS engine",
                code    = "tts_engine_init_failed",
            )
            timebaseListener.onTimebasedPlaybackStateChanged(
                TimebasedNavigator.TimebasedState.Failure
            )
        }
    }

    // ─── Điều khiển phát ─────────────────────────────────────────────────────

    /**
     * Bắt đầu hoặc tiếp tục phát.
     * @param fromLocator Nếu được cung cấp, nhảy đến trang tương ứng.
     */
    suspend fun play(fromLocator: Locator? = null) {
        if (!ttsReady) {
            pendingPlayRequested = true
            pendingPlayLocator = fromLocator
            Log.w(TAG, "play() gọi trước khi TTS engine sẵn sàng — sẽ tự phát khi ready")
            return
        }

        // Nhảy đến trang/câu từ locator nếu có
        if (fromLocator != null) {
            val targetPage = (fromLocator.locations.position ?: 1) - 1 // 0-based
            val idx = sentences.indexOfFirst { it.pageIndex >= targetPage }
            if (idx >= 0) currentIdx = idx
        }

        if (isPaused) {
            // Tiếp tục câu đang bị tạm dừng
            isPaused  = false
            isPlaying = true
            speakCurrentSentence()
        } else {
            isPlaying = true
            isPaused  = false
            speakCurrentSentence()
        }
    }

    /** Tạm dừng phát. */
    suspend fun pause() {
        pendingPlayRequested = false
        pendingPlayLocator = null
        isPlaying = false
        isPaused  = true
        tts?.stop()
        timebaseListener.onTimebasedPlaybackStateChanged(
            TimebasedNavigator.TimebasedState.Paused
        )
        Log.d(TAG, "pause() tại câu $currentIdx / ${sentences.size}")
    }

    /** Tiếp tục phát sau tạm dừng. */
    suspend fun resume() {
        if (!isPaused) return
        play()
    }

    /** Quay lại câu trước. */
    fun goBack() {
        tts?.stop()
        if (currentIdx > 0) currentIdx--
        if (isPlaying) mainScope.launch { speakCurrentSentence() }
        else emitCurrentLocator()
    }

    /** Chuyển sang câu tiếp theo. */
    fun goForward() {
        tts?.stop()
        if (currentIdx < sentences.size - 1) currentIdx++
        if (isPlaying) mainScope.launch { speakCurrentSentence() }
        else emitCurrentLocator()
    }

    /**
     * Nhảy đến trang [pageIndex] (0-based) và phát từ câu đầu tiên của trang đó.
     */
    fun goToPage(pageIndex: Int) {
        tts?.stop()
        val idx = sentences.indexOfFirst { it.pageIndex >= pageIndex }
        if (idx >= 0) currentIdx = idx
        if (isPlaying) mainScope.launch { speakCurrentSentence() }
        else emitCurrentLocator()
    }

    /** Dừng hoàn toàn và reset vị trí về đầu. */
    fun stop() {
        pendingPlayRequested = false
        pendingPlayLocator = null
        isPlaying = false
        isPaused  = false
        tts?.stop()
        currentIdx = 0
        timebaseListener.onTimebasedPlaybackStateChanged(
            TimebasedNavigator.TimebasedState.Ended
        )
        Log.d(TAG, "stop()")
    }

    /** Cập nhật preferences (speed, pitch, language). */
    fun updatePreferences(prefs: FlutterTtsPreferences) {
        preferences = preferences.plus(prefs)
        applyPreferences()
    }

    fun setPreferredVoice(voiceId: String, language: String) {
        val voices = preferences.voices?.toMutableMap() ?: mutableMapOf()
        voices[language] = voiceId
        updatePreferences(FlutterTtsPreferences(voices = voices))
    }

    /** Giải phóng tài nguyên. */
    fun dispose() {
        pendingPlayRequested = false
        pendingPlayLocator = null
        isPlaying = false
        isPaused  = false
        tts?.stop()
        tts?.shutdown()
        tts = null
        Log.d(TAG, "dispose()")
    }

    // ─── Private: TTS ─────────────────────────────────────────────────────────

    private fun applyPreferences() {
        val preferredLanguage = preferences.languageOverride ?: preferences.voices?.keys?.firstOrNull()
        val locale = preferredLanguage
            ?.let { runCatching { Locale.forLanguageTag(it) }.getOrNull() }
            ?: Locale.getDefault()
        tts?.language = locale

        val preferredVoiceId = preferences.voices?.get(locale.toLanguageTag())
            ?: preferences.voices?.get(locale.language)
            ?: preferences.voices?.values?.firstOrNull()
        if (preferredVoiceId != null) {
            tts?.voices
                ?.firstOrNull { it.name == preferredVoiceId }
                ?.let { tts?.voice = it }
        }

        // Flutter speed: 0.5 - 2.0; Android TTS: 0.0 - 2.0 (1.0 = bình thường)
        tts?.setSpeechRate((preferences.speed?.toFloat() ?: 1.0f))
        tts?.setPitch((preferences.pitch?.toFloat() ?: 1.0f))
    }

    private fun setupUtteranceListener() {
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                // Phát state Playing và locator khi bắt đầu một câu mới
                mainScope.launch {
                    timebaseListener.onTimebasedPlaybackStateChanged(
                        TimebasedNavigator.TimebasedState.Playing
                    )
                    emitCurrentLocator()
                }
            }

            override fun onDone(utteranceId: String?) {
                if (!isPlaying) return
                mainScope.launch {
                    currentIdx++
                    speakCurrentSentence()
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                Log.w(TAG, "TTS utterance error: $utteranceId — tiếp tục câu tiếp theo")
                if (isPlaying) {
                    mainScope.launch {
                        currentIdx++
                        speakCurrentSentence()
                    }
                }
            }
        })
    }

    /** Đọc câu tại [currentIdx]. Khi hết câu → emit Ended. */
    private fun speakCurrentSentence() {
        val engine = tts ?: return

        if (currentIdx >= sentences.size) {
            isPlaying = false
            timebaseListener.onTimebasedPlaybackStateChanged(
                TimebasedNavigator.TimebasedState.Ended
            )
            Log.d(TAG, "Đọc xong toàn bộ PDF")
            return
        }

        val sentence = sentences[currentIdx]
        Log.d(TAG, "speakCurrentSentence: [$currentIdx] trang=${sentence.pageIndex} — \"${sentence.text.take(60)}…\"")

        engine.speak(
            sentence.text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "utt_$currentIdx",
        )
    }

    // ─── Private: Locator ─────────────────────────────────────────────────────

    /**
     * Phát sự kiện TextLocator để visual PDF view đồng bộ trang.
     */
    private fun emitCurrentLocator() {
        if (sentences.isEmpty()) return
        val idx      = currentIdx.coerceIn(0, sentences.size - 1)
        val sentence = sentences[idx]

        val pdfHref    = publication.readingOrder.firstOrNull()?.url()?.toString() ?: pdfFilePath
        val progression = if (sentences.isEmpty()) 0.0 else idx.toDouble() / sentences.size

        val locatorJson = JSONObject().apply {
            put("href", pdfHref)
            put("type", "application/pdf")
            put("locations", JSONObject().apply {
                put("position", sentence.pageIndex + 1) // 1-based
                put("totalProgression", progression)
            })
        }

        runCatching {
            val locator = Locator.fromJSON(locatorJson)
            if (locator != null) {
                ReadiumReader.emitTextLocatorUpdate(locator)
            }
        }.onFailure { e ->
            Log.e(TAG, "emitCurrentLocator lỗi: $e")
        }
    }

    // ─── Private: PDF text extraction ─────────────────────────────────────────

    /**
     * Trích xuất và tách câu từ tất cả các trang PDF.
     * Chạy trên IO thread — **không** được gọi từ Main thread.
     */
    private fun extractSentencesFromPdf(filePath: String): List<Sentence> {
        // PDFBoxResourceLoader.init() an toàn khi gọi nhiều lần
        PDFBoxResourceLoader.init(context)

        val file = File(filePath)
        check(file.exists()) { "PDF file không tồn tại: $filePath" }

        val result = mutableListOf<Sentence>()

        PDDocument.load(file).use { doc ->
            val totalPages = doc.numberOfPages
            val stripper   = PDFTextStripper()
            stripper.sortByPosition = true

            for (pageIdx in 0 until totalPages) {
                stripper.startPage = pageIdx + 1
                stripper.endPage   = pageIdx + 1

                val pageText = stripper.getText(doc).trim()
                if (pageText.isBlank()) continue

                for (sentence in splitIntoSentences(pageText)) {
                    result.add(Sentence(sentence, pageIdx, totalPages))
                }
            }
        }

        return result
    }

    // ─── Companion: sentence splitting ───────────────────────────────────────

    companion object {
        /**
         * Tách đoạn văn bản thành các câu ngắn phù hợp để TTS đọc.
         *
         * Chiến lược:
         * 1. Tách tại dấu [.!?…] theo sau bởi khoảng trắng và chữ hoa.
         * 2. Nếu câu quá dài (> 400 ký tự), tiếp tục tách tại [,;:] hoặc xuống dòng.
         * 3. Lọc các chuỗi rỗng và quá ngắn.
         */
        fun splitIntoSentences(text: String): List<String> {
            // Chuẩn hóa khoảng trắng và xuống dòng
            val normalized = text
                .replace(Regex("""\r\n|\r"""), "\n")
                .replace(Regex("""\n{3,}"""), "\n\n")
                .replace(Regex("""[ \t]+"""), " ")
                .trim()

            // Tách tại cuối câu theo sau bởi chữ hoa (Latin + các ngôn ngữ khác)
            val primarySplit = Regex("""(?<=[.!?…])\s+(?=\p{Lu})""")
                .split(normalized)

            return primarySplit
                .flatMap { chunk ->
                    val c = chunk.trim()
                    if (c.length <= 400) {
                        listOf(c)
                    } else {
                        // Câu quá dài: tách thêm tại dấu phẩy / xuống dòng
                        Regex("""(?<=[,;:])\s+|(?<=\n)""")
                            .split(c)
                            .map { it.trim() }
                    }
                }
                .filter { it.isNotBlank() && it.length > 2 }
                .ifEmpty { listOf(normalized) }
        }
    }
}

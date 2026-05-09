package dk.nota.flutter_readium

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import androidx.fragment.app.FragmentManager
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryOwner
import dk.nota.flutter_readium.events.ErrorEventChannel
import dk.nota.flutter_readium.events.ReadiumErrorEvent
import dk.nota.flutter_readium.events.ReadiumReaderStatus
import dk.nota.flutter_readium.events.ReadiumReaderStatusEventChannel
import dk.nota.flutter_readium.events.TextLocatorEventChannel
import dk.nota.flutter_readium.events.TimedBasedStateEventChannel
import dk.nota.flutter_readium.models.ReadiumTimebasedState
import dk.nota.flutter_readium.navigators.AudiobookNavigator
import dk.nota.flutter_readium.navigators.EpubNavigator
import dk.nota.flutter_readium.navigators.SyncAudiobookNavigator
import dk.nota.flutter_readium.navigators.TTSNavigator
import dk.nota.flutter_readium.navigators.TimebasedNavigator
import dk.nota.flutter_readium.pdf.AndroidPdfDocumentFactory
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.navigator.media.tts.android.AndroidTtsEngine
import org.readium.navigator.media.tts.android.AndroidTtsPreferences
import org.readium.navigator.media.tts.android.AndroidTtsSettings
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.InternalReadiumApi
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.allAreHtml
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.DebugError
import org.readium.r2.shared.util.Language
import org.readium.r2.shared.util.ThrowableError
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.Try.Companion.failure
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.asset.Asset
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.http.HttpRequest
import org.readium.r2.shared.util.http.HttpTry
import org.readium.r2.shared.util.resource.Resource
import org.readium.r2.shared.util.resource.TransformingContainer
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.PublicationOpener.OpenError
import org.readium.r2.streamer.parser.DefaultPublicationParser
import java.lang.ref.WeakReference
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

private const val TAG = "ReadiumReader"

private const val stateKey = "dk.nota.flutter_readium.ReadiumReaderState"

private const val currentPublicationUrlKey = "currentPublicationUrl"
private const val cachedPdfFilePathKey = "cachedPdfFilePath"
private const val ttsEnabledKey = "ttsEnabled"
private const val audioEnabledKey = "audioEnabled"
private const val syncAudioEnabledKey = "syncAudioEnabled"

private const val epubEnabledKey = "epubEnabled"
private const val ttsNavigatorStateKey = "ttsState"
private const val audioNavigatorStateKey = "audioState"
private const val syncAudioNavigatorStateKey = "syncAudioState"
private const val epubNavigatorStateKey = "epubState"
private const val decorationStyleKey = "decorationStyle"

// TODO: Support custom headers and authentication header for content files.

@ExperimentalCoroutinesApi
@OptIn(ExperimentalReadiumApi::class)
object ReadiumReader : TimebasedNavigator.TimebasedListener, EpubNavigator.VisualListener {
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val jobs = mutableListOf<Job>()

    private var appRef: WeakReference<Application>? = null

    private var timedBasedStateEventChannel: TimedBasedStateEventChannel? = null

    private var textLocatorEventChannel: TextLocatorEventChannel? = null

    private var readiumReaderStatusEventChannel: ReadiumReaderStatusEventChannel? = null

    private var errorEventChannel: ErrorEventChannel? = null

    /** Navigator TTS dành riêng cho PDF (dùng PDFBox + Android TextToSpeech). */
    private var pdfTtsNavigator: dk.nota.flutter_readium.navigators.PdfTtsNavigator? = null

    private var readerViewRef: WeakReference<ReadiumReaderWidget>? = null

    private var savedStateRef: WeakReference<SavedStateRegistry>? = null

    // in-memory cached state
    private val state = mutableMapOf<String, Any?>()

    private val currentTimebasedState = MutableStateFlow<TimebasedNavigator.TimebasedState?>(null)

    private val currentTimebasedDuration = MutableStateFlow<Double?>(null)

    private val currentTimebasedOffset = MutableStateFlow<Double?>(null)

    private val currentTimebasedBuffer = MutableStateFlow<Long?>(null)

    private val currentTimebasedLocator = MutableStateFlow<Locator?>(null)

    private var defaultHttpHeaders = mutableMapOf<String, String>()

    var decorationStyle: FlutterDecorationPreferences
        get() = state[decorationStyleKey] as? FlutterDecorationPreferences
            ?: FlutterDecorationPreferences()
        set(value) {
            state[decorationStyleKey] = value
        }

    fun createCurrentTimebasedReaderState(): Flow<ReadiumTimebasedState?> {
        return combine(
            currentTimebasedLocator.throttleLatest(100.milliseconds).distinctUntilChanged(),
            currentTimebasedState.throttleLatest(100.milliseconds).distinctUntilChanged(),
            currentTimebasedOffset.throttleLatest(100.milliseconds).distinctUntilChanged(),
            currentTimebasedBuffer.throttleLatest(250.milliseconds).distinctUntilChanged(),
            currentTimebasedDuration.throttleLatest(100.milliseconds).distinctUntilChanged(),
        ) { locator, state, offset, buffer, duration ->
            if (state == null) {
                return@combine null
            }

            ReadiumTimebasedState(locator, state, offset, buffer, duration ?: 0.0)
        }.throttleLatest(100.milliseconds).distinctUntilChanged()
    }

    private val httpClient by lazy {
        DefaultHttpClient(callback = object : DefaultHttpClient.Callback {
            override suspend fun onStartRequest(request: HttpRequest): HttpTry<HttpRequest> {
                val requestWithHeaders = request.copy {
                    defaultHttpHeaders.toMap().forEach { (key, value) ->
                        setHeader(key, value)
                    }
                }
                return Try.success(requestWithHeaders)
            }
        })
    }

    private var _assetRetriever: AssetRetriever? = null

    private val assetRetriever: AssetRetriever
        get() {
            if (_assetRetriever == null) {
                _assetRetriever = AssetRetriever(context.contentResolver, httpClient)
            }

            return _assetRetriever!!
        }

    private var _publicationOpener: PublicationOpener? = null

    private var ttsNavigator: TTSNavigator? = null

    private var audiobookNavigator: AudiobookNavigator? = null
    private var syncAudiobookNavigator: SyncAudiobookNavigator? = null

    private var epubNavigator: EpubNavigator? = null

    val epubCurrentLocator: Locator?
        get() = epubNavigator?.currentLocator?.value

    private var _audioPreferences: FlutterAudioPreferences = FlutterAudioPreferences()

    /** Current audio preferences (defaults if audio hasn't been enabled yet). */
    val audioPreferences: FlutterAudioPreferences
        get() = _audioPreferences

    /**
     * The PublicationFactory is used to open publications.
     * Sử dụng [AndroidPdfDocumentFactory] để hỗ trợ file PDF mà không cần thư viện thương mại.
     */
    private val publicationOpener: PublicationOpener
        get() {
            if (_publicationOpener == null) {
                _publicationOpener = PublicationOpener(
                    publicationParser = DefaultPublicationParser(
                        context,
                        assetRetriever = assetRetriever,
                        httpClient = httpClient,
                        // Sử dụng AndroidPdfDocumentFactory (dùng android.graphics.pdf.PdfRenderer tích hợp sẵn).
                        // Thay thế bằng PsPDFKitDocumentFactory nếu cần tính năng PDF nâng cao (yêu cầu license).
                        pdfFactory = AndroidPdfDocumentFactory(context),
                    ),
                )
            }

            return _publicationOpener!!
        }

    // Initialize from plugin or anywhere you have an Application or Context.
    fun attach(activity: Activity, messenger: BinaryMessenger) {
        unwrapToApplication(activity)?.let { appRef = WeakReference(it) }

        timedBasedStateEventChannel?.dispose()
        timedBasedStateEventChannel = TimedBasedStateEventChannel(messenger)

        textLocatorEventChannel = TextLocatorEventChannel(messenger)
        readiumReaderStatusEventChannel = ReadiumReaderStatusEventChannel(messenger)
        errorEventChannel = ErrorEventChannel(messenger)

        // store weak ref only
        (activity as? SavedStateRegistryOwner)?.savedStateRegistry?.let {
            savedStateRef = WeakReference(it)
            it.registerSavedStateProvider(stateKey) {
                storeState()
            }

            restoreState(it.consumeRestoredStateForKey(stateKey))
        }

        createCurrentTimebasedReaderState().onEach {
            Log.d(
                TAG, "currentTimebasedReaderState: ${
                    jsonEncode(
                        it?.toJSON()
                    )
                }"
            )

            if (it != null) {
                timedBasedStateEventChannel?.sendEvent(it)
            }
        }.launchIn(mainScope).let { jobs.add(it) }
    }

    private fun storeState(): Bundle {
        if (currentPublicationUrl == null) {
            // No current publication, no state.
            return Bundle()
        }

        return Bundle().apply {
            putString(currentPublicationUrlKey, currentPublicationUrl)
            putBoolean(epubEnabledKey, epubNavigator != null)
            putBundle(epubNavigatorStateKey, epubNavigator?.storeState())
            putBoolean(ttsEnabledKey, ttsNavigator != null)
            putBundle(ttsNavigatorStateKey, ttsNavigator?.storeState())
            putBoolean(audioEnabledKey, audiobookNavigator != null)
            putBundle(audioNavigatorStateKey, audiobookNavigator?.storeState())
            putBoolean(syncAudioEnabledKey, syncAudiobookNavigator != null)
            putBundle(syncAudioNavigatorStateKey, syncAudiobookNavigator?.storeState())
            putParcelable(decorationStyleKey, decorationStyle)
        }
    }

    private fun restoreState(bundle: Bundle?) {
        if (bundle == null) {
            Log.d(TAG, ":restoreState nothing to restore")
            return
        }

        Log.d(TAG, ":restoreState $bundle")
        val pubUrl = bundle.getString(currentPublicationUrlKey)
        if (pubUrl == null) {
            Log.d(TAG, ":storeState - currentPublicationUrl - not restored")
            return
        }

        Log.d(TAG, ":restoreState - currentPublicationUrl - $pubUrl")
        mainScope.launch {
            val pub = openPublication(pubUrl).getOrElse {
                Log.d(TAG, ":restoreState - failed to restore publication")
                // TODO: Handle this somehow
                return@launch
            }

            decorationStyle =
                bundle.getParcelable(decorationStyleKey) as? FlutterDecorationPreferences
                    ?: FlutterDecorationPreferences()

            if (bundle.getBoolean(epubEnabledKey)) {
                Log.d(TAG, ":storeState - restore epub navigator")
                bundle.getBundle(epubNavigatorStateKey)?.let { state ->
                    epubNavigator =
                        EpubNavigator.restoreState(pub, this@ReadiumReader, state).apply {
                            initNavigator()
                            Log.d(TAG, ":storeState - epubNavigator restored")
                        }
                }
            }

            if (bundle.getBoolean(ttsEnabledKey)) {
                // Restore TTS navigator
                Log.d(TAG, ":storeState - restore tts navigator")
                bundle.getBundle(ttsNavigatorStateKey)?.let { state ->
                    ttsNavigator = TTSNavigator.restoreState(pub, this@ReadiumReader, state).apply {
                        initNavigator()
                        Log.d(TAG, ":storeState - ttsNavigator restored")
                    }
                }
            }

            if (bundle.getBoolean(audioEnabledKey)) {
                // Restore Audio navigator
                Log.d(TAG, ":storeState - restore audio navigator")
                bundle.getBundle(audioNavigatorStateKey)?.let { state ->
                    audiobookNavigator =
                        AudiobookNavigator.restoreState(pub, this@ReadiumReader, state).apply {
                            initNavigator()
                            Log.d(TAG, ":storeState - audioNavigator restored")
                        }
                }
            } else if (bundle.getBoolean(syncAudioEnabledKey)) {
                // Restore Sync Audio navigator
                Log.d(TAG, ":storeState - restore sync audio navigator")
                val (ap, mediaOverlays) = pub.makeSyncAudiobook()
                if (mediaOverlays != null) {
                    bundle.getBundle(syncAudioNavigatorStateKey)?.let { state ->
                        syncAudiobookNavigator =
                            SyncAudiobookNavigator.restoreState(
                                ap,
                                mediaOverlays,
                                this@ReadiumReader,
                                state
                            )
                                .apply {
                                    initNavigator()
                                    Log.d(TAG, ":storeState - syncAudioNavigator restored")
                                }
                    }
                } else {
                    Log.e(TAG, ":storeState - no media overlays for sync audio navigator")
                }
            }

            Log.d(TAG, "consumeRestoredStateForKey - 2 - $currentPublication")
        }
    }

    fun detach() {
        mainScope.launch {
            closePublication()
        }

        appRef?.clear()
        appRef = null

        savedStateRef?.clear()
        savedStateRef = null

        _assetRetriever = null
        _publicationOpener = null

        readerViewRef?.clear()
        readerViewRef = null

        timedBasedStateEventChannel?.dispose()
        timedBasedStateEventChannel = null

        textLocatorEventChannel?.dispose()
        textLocatorEventChannel = null

        readiumReaderStatusEventChannel?.dispose()
        readiumReaderStatusEventChannel = null

        errorEventChannel?.dispose()
        errorEventChannel = null

        jobs.forEach { it.cancel() }
        jobs.clear()
        mainScope.coroutineContext.cancelChildren()
    }

    // Safe getter — returns applicationContext or throws if not available.
    val application: Application
        get() = appRef?.get()
            ?: throw IllegalStateException("Application not initialized. Call ReadiumReader.attach(...) first.")

    var currentReaderWidget: ReadiumReaderWidget?
        get() = readerViewRef?.get()
        set(value) {
            readerViewRef = value?.let { WeakReference(it) }
        }

    private val context: Context
        get() = application.applicationContext

    private var _currentPublication: Publication? = null
    val currentPublication: Publication?
        get() = _currentPublication
    var currentPublicationUrl
        get() = state[currentPublicationUrlKey] as String?
        set(value) {
            state[currentPublicationUrlKey] = value
        }

    /**
     * Đường dẫn tuyệt đối đến file PDF hiện tại, hoặc null nếu không phải PDF.
     * Được cache khi [openPublication] thành công để tránh re-parse URL (vốn fragile
     * khi tên file có dấu cách hoặc ký tự đặc biệt).
     */
    private var cachedPdfFilePath: String?
        get() = state[cachedPdfFilePathKey] as String?
        set(value) {
            state[cachedPdfFilePathKey] = value
        }

    /**
     * Sets the headers used in the HTTP requests for fetching publication resources, including
     * resources in already created `Publication` objects.
     *
     * @param headers a map of HTTP header key value pairs.
     */
    fun setDefaultHttpHeaders(headers: Map<String, String>) {
        defaultHttpHeaders.clear()
        defaultHttpHeaders.putAll(headers)
    }

    private suspend fun assetToPublication(
        asset: Asset
    ): Try<Publication, OpenError> {
        val publication: Publication =
            publicationOpener.open(asset, allowUserInteraction = true, onCreatePublication = {
                container = TransformingContainer(container) { _: Url, resource: Resource ->
                    resource.injectScriptsAndStyles()
                }
            }).getOrElse { err: OpenError ->
                Log.e(TAG, "Error opening publication: $err")
                asset.close()
                return failure(err)
            }
        Log.d(TAG, "Open publication success: $publication")
        return Try.success(publication)
    }

    /**
     * Load a publication from a String url.
     * Note: Remember to close the publication to avoid leaks.
     */
    suspend fun loadPublication(
        pubUrl: String?
    ): Try<Publication, PublicationError> {
        if (pubUrl == null) {
            return failure(
                PublicationError.Unexpected(
                    DebugError("missing argument")
                )
            )
        }

        return AbsoluteUrl.invoke(pubUrl)?.let { pubUrl -> loadPublication(pubUrl) } ?: failure(
            PublicationError.Unexpected(
                DebugError("Invalid Url")
            )
        )
    }

    /**
     * Load a publication from an AbsoluteUrl
     *
     * Note: Remember to close the publication to avoid leaks.
     */
    suspend fun loadPublication(
        pubUrl: AbsoluteUrl
    ): Try<Publication, PublicationError> {
        if (currentPublicationUrl == pubUrl.toString()) {
            // Current publication is the same as the one we are trying to load, return it.
            currentPublication?.let {
                return Try.success(it)
            }
        }

        return withContext(Dispatchers.IO) {
            try {
                // TODO: should client provide mediaType to assetRetriever?
                val asset: Asset = assetRetriever.retrieve(pubUrl)
                    .getOrElse { error: AssetRetriever.RetrieveUrlError ->
                        Log.e(TAG, "Error retrieving asset: $error from url:$pubUrl")
                        return@withContext failure(PublicationError.invoke(error))
                    }
                val pub = assetToPublication(asset).getOrElse { error: OpenError ->
                    Log.e(TAG, "Error loading asset to Publication object: $error from url:$pubUrl")
                    return@withContext failure(PublicationError.invoke(error))
                }
                Log.d(TAG, "Opened publication = ${pub.metadata.identifier} from url:$pubUrl")
                return@withContext Try.success(pub)
            } catch (e: Throwable) {
                return@withContext failure(PublicationError.Unexpected(ThrowableError(e)))
            }
        }
    }

    /**
     * Open a publication and set it as the current publication.
     */
    suspend fun openPublication(
        pubUrl: String?
    ): Try<Publication, PublicationError> {
        if (pubUrl == null) {
            return failure(
                PublicationError.Unexpected(
                    DebugError("missing argument")
                )
            )
        }

        return AbsoluteUrl.invoke(pubUrl)?.let { pubUrl -> openPublication(pubUrl) } ?: failure(
            PublicationError.Unexpected(
                DebugError("Invalid Url")
            )
        )
    }

    /**
     * Open a publication and set it as the current publication.
     */
    suspend fun openPublication(
        pubUrl: AbsoluteUrl
    ): Try<Publication, PublicationError> {
        if (currentPublicationUrl == pubUrl.toString()) {
            // Current publication is the same as the one we are trying to open, return it.
            // If you need to reload the publication, you need to close it first.
            currentPublication?.let {
                return Try.success(it)
            }
        }

        // Close previously opened publication to avoid leaks.
        closePublication()

        val pub = loadPublication(pubUrl).getOrElse { e -> return failure(e) }

        _currentPublication = pub
        currentPublicationUrl = pubUrl.toString()

        // Cache đường dẫn file PDF ngay tại đây để tránh re-parse URL sau này.
        // android.net.Uri.parse() decode percent-encoding (%20 → space) đúng cách
        // và không throw exception khi URL có ký tự đặc biệt.
        cachedPdfFilePath = if (isPdfPublication(pub)) {
            val urlStr = pubUrl.toString()
            val path = when {
                urlStr.startsWith("file:") ->
                    try {
                        android.net.Uri.parse(urlStr).path
                    } catch (e: Exception) {
                        Log.e(TAG, "openPublication: lỗi parse file URL '$urlStr': $e")
                        null
                    }
                urlStr.startsWith("/") -> urlStr
                else -> null
            }
            Log.d(TAG, "openPublication: cached PDF path = '$path' (from URL: $urlStr)")
            path
        } else {
            null
        }

        return Try.success(pub)
    }

    /**
     * Load a publication from a URL
     * Note: Remember to close the publication to avoid leaks.
     */
    suspend fun loadPublicationFromUrl(urlStr: String): Try<Publication, PublicationError> {
        val pubUrl = resolvePubUrl(urlStr).getOrElse {
            return failure(PublicationError.InvalidPublicationUrl(urlStr))
        }

        Log.d(TAG, "loadPublicationFromUrl: $pubUrl")

        return loadPublication(pubUrl)
    }

    /**
     * Open a publication from a URL.
     *
     * Note: This sets the publication as the current publication.
     */
    suspend fun openPublicationFromUrl(urlStr: String): Try<Publication, PublicationError> {
        val pubUrl = resolvePubUrl(urlStr).getOrElse {
            return failure(PublicationError.InvalidPublicationUrl(urlStr))
        }

        Log.d(TAG, "openPublicationFromUrl: $pubUrl")

        return openPublication(pubUrl)
    }

    /**
     * Helper function for resolving a URL and make sure a file path is turned into a URL.
     *
     * Lưu ý: Sử dụng [java.io.File.toURI] thay vì ghép chuỗi "file://" để đảm bảo
     * tên file có dấu cách hoặc ký tự đặc biệt được percent-encode đúng cách
     * (ví dụ: "Tham Do Tiem Thuc.pdf" → "file:///…/Tham%20Do%20Tiem%20Thuc.pdf").
     * Nếu không encode, [AbsoluteUrl] sẽ trả về null và gây lỗi notFound.
     */
    private fun resolvePubUrl(urlStr: String): Try<AbsoluteUrl, PublicationError> {
        var pubUrlStr = urlStr
        // If URL is neither http nor file, assume it is a local file reference.
        if (!pubUrlStr.startsWith("http") && !pubUrlStr.startsWith("file")) {
            // File.toURI() percent-encodes spaces và ký tự đặc biệt trong đường dẫn
            pubUrlStr = java.io.File(pubUrlStr).toURI().toString()
        }
        // Create AbsoluteUrl, return PublicationError.InvalidPublicationUrl if null
        val pubUrl = AbsoluteUrl(pubUrlStr) ?: return failure(
            PublicationError.InvalidPublicationUrl(pubUrlStr)
        )

        return Try.success(pubUrl)
    }

    suspend fun closePublication() {
        mainScope.async {
            _currentPublication?.close()
            _currentPublication = null

            pdfTtsNavigator?.dispose()
            pdfTtsNavigator = null

            ttsNavigator?.dispose()
            ttsNavigator = null
            audiobookNavigator?.dispose()
            audiobookNavigator = null
            syncAudiobookNavigator?.dispose()
            syncAudiobookNavigator = null

            _audioPreferences = FlutterAudioPreferences()

            state.clear()
        }.await()
    }

    override fun onTimebasedPlaybackStateChanged(timebasedState: TimebasedNavigator.TimebasedState) {
        Log.d(TAG, ":onTimebasedPlaybackStateChanged $timebasedState")
        currentTimebasedState.value = timebasedState
    }

    override fun onTimebasedBufferChanged(buffer: Duration?) {
        Log.d(TAG, ":onTimebasedBufferChanged $buffer")
        currentTimebasedBuffer.value = buffer?.inWholeMilliseconds
    }

    override fun onTimebasedPlaybackFailure(error: PublicationError) {
        Log.d(TAG, ":onTimebasedPlaybackFailure $error")
        // TODO: Notify client
    }

    override fun onTimebasedCurrentLocatorChanges(
        locator: Locator, currentReadingOrderLink: Link?
    ) {
        val duration = currentReadingOrderLink?.duration
        val timeOffset =
            locator.locations.fragments.find { it.startsWith("t=") }?.substring(2)?.toDoubleOrNull()
                ?: (duration?.let { duration ->
                    locator.locations.progression?.let { prog -> duration * prog }
                })

        Log.d(TAG, ":onTimebasedCurrentLocatorChanges $locator, timeOffset=$timeOffset")

        currentTimebasedOffset.value = timeOffset?.let { it * 1000 }
        currentTimebasedDuration.value = duration?.let { it * 1000 }
        currentTimebasedLocator.value = locator
    }

    override fun onTimebasedLocationChanged(locator: Locator) {
        Log.d(TAG, ":onTimebasedLocationChanged $locator")

        currentReaderWidget?.go(locator, true)
    }

    @OptIn(InternalReadiumApi::class)
    suspend fun epubEnable(
        initialLocator: Locator?,
        initialPreferences: EpubPreferences,
        fragmentManager: FragmentManager,
        viewGroup: ViewGroup,
        readerWidget: ReadiumReaderWidget
    ) {
        val pub = currentPublication ?: throw Exception("Publication not opened cannot enable epub")

        currentReaderWidget = readerWidget

        val isEpub = pub.conformsTo(Publication.Profile.EPUB) || pub.readingOrder.allAreHtml
        if (!isEpub) {
            throw Exception("Publication is not an EPUB, cannot enable epub navigator")
        }

        withScope(mainScope) {
            epubNavigator?.let {
                attachEpubNavigator(fragmentManager, viewGroup)
                return@withScope
            } // Already enabled - assume from restored state.

            EpubNavigator(pub, initialLocator, this@ReadiumReader, initialPreferences).apply {
                initNavigator()
                epubNavigator = this
                attachEpubNavigator(fragmentManager, viewGroup)
                return@withScope
            }
        }
    }

    suspend fun attachEpubNavigator(fragmentManager: FragmentManager?, viewGroup: ViewGroup?) {
        if (fragmentManager == null || viewGroup == null) {
            Log.d(TAG, "attachEpubNavigator: Missing fragmentManager or viewGroup")
            return
        }

        mainScope.async {
            epubNavigator?.attachNavigator(fragmentManager, viewGroup)
        }.await()
    }

    fun epubClose() {
        currentReaderWidget = null
        epubNavigator?.dispose()
        epubNavigator = null
    }

    suspend fun ttsEnable(ttsPrefs: FlutterTtsPreferences) {
        val pub = currentPublication ?: throw Exception("Publication not opened cannot enable tts")

        if (isCurrentPublicationPdf()) {
            // ── PDF: trích xuất text bằng PDFBox, phát bằng Android TextToSpeech ──
            val filePath = cachedPdfFilePath
                ?: throw Exception("PDF file path not cached — openPublication() phải chạy trước")

            pdfTtsNavigator?.dispose()
            pdfTtsNavigator = dk.nota.flutter_readium.navigators.PdfTtsNavigator(
                context           = application,
                pdfFilePath       = filePath,
                publication       = pub,
                preferences       = ttsPrefs,
                timebaseListener  = this@ReadiumReader,
            ).also { it.initialize() }

        } else {
            // ── EPUB/WebPub: Readium TtsNavigator như cũ ──────────────────────────
            ttsNavigator?.dispose()
            ttsNavigator = TTSNavigator(pub, this@ReadiumReader, null, ttsPrefs).apply {
                initNavigator()
            }
        }
    }

    suspend fun ttsSetPreferences(ttsPrefs: FlutterTtsPreferences) {
        if (pdfTtsNavigator != null) {
            pdfTtsNavigator?.updatePreferences(ttsPrefs)
        } else {
            ttsNavigator?.updatePreferences(ttsPrefs)
                ?: throw Exception("TTS is not enabled, can't set preferences")
        }
    }

    suspend fun setDecorationStyle(style: FlutterDecorationPreferences) {
        decorationStyle = style

        ttsNavigator?.decorationsUpdated()
        syncAudiobookNavigator?.decorationsUpdated()
    }

    suspend fun ttsGetAvailableVoices(): Set<AndroidTtsEngine.Voice> {
        // Get the available voices from the TTS navigator.
        // If the TTS navigator hasn't been initialized, create a dummy AndroidTtsEngine.
        return ttsNavigator?.voices ?: AndroidTtsEngine.invoke(
            context,
            {
                AndroidTtsSettings(
                    Language("C"),
                    false,
                    0.0,
                    0.0,
                    mapOf()
                )
            },
            { language, availableVoices -> null },
            AndroidTtsPreferences())?.voices ?: setOf()
    }

    fun ttsGetPreferences(): FlutterTtsPreferences? {
        return ttsNavigator?.preferences
    }

    suspend fun ttsSetPreferredVoice(voiceId: String?, language: String?) {
        if (voiceId == null) {
            Log.d(TAG, ":ttsSetPreferredVoice - missing voiceId")
            return
        }

        if (language == null) {
            Log.d(TAG, ":ttsSetPreferredVoice - missing language")
            return
        }

        if (pdfTtsNavigator != null) {
            pdfTtsNavigator?.setPreferredVoice(voiceId, language)
        } else {
            ttsNavigator?.setPreferredVoice(voiceId, language)
        }
    }

    suspend fun play(locator: Locator?) {
        var fromLocator = locator

        if (fromLocator == null) {
            fromLocator = currentReaderWidget?.getFirstVisibleLocator()
        }

        pdfTtsNavigator?.play(fromLocator)
        audiobookNavigator?.play(fromLocator)
        syncAudiobookNavigator?.play(fromLocator)
        ttsNavigator?.play(fromLocator)
    }

    suspend fun pause() {
        pdfTtsNavigator?.pause()
        audiobookNavigator?.pause()
        syncAudiobookNavigator?.pause()
        ttsNavigator?.pause()
    }

    suspend fun resume() {
        pdfTtsNavigator?.resume()
        audiobookNavigator?.resume()
        syncAudiobookNavigator?.resume()
        ttsNavigator?.resume()
    }

    suspend fun stop() {
        pdfTtsNavigator?.apply {
            stop()
            dispose()
            pdfTtsNavigator = null
        }

        audiobookNavigator?.apply {
            pause()
            dispose()
            audiobookNavigator = null
        }

        syncAudiobookNavigator?.apply {
            dispose()
            syncAudiobookNavigator = null
        }

        ttsNavigator?.apply {
            pause()
            dispose()
            ttsNavigator = null
        }
    }

    /**
     * Skip backwards.
     */
    suspend fun previous() {
        pdfTtsNavigator?.goBack()
        audiobookNavigator?.goBack()
        syncAudiobookNavigator?.goBack()
        ttsNavigator?.goBack()
    }

    /**
     * Skip forwards.
     */
    suspend fun next() {
        pdfTtsNavigator?.goForward()
        audiobookNavigator?.goForward()
        syncAudiobookNavigator?.goForward()
        ttsNavigator?.goForward()
    }

    /**
     * Go to a specific locator.
     */
    suspend fun goToLocator(locator: Locator) {
        audiobookNavigator?.goToLocator(locator)
        syncAudiobookNavigator?.goToLocator(locator)
        ttsNavigator?.goToLocator(locator)
        epubGoToLocator(locator, true)
    }

    suspend fun audioSeek(offsetSeconds: Double) {
        audiobookNavigator?.seekTo(offsetSeconds)
        syncAudiobookNavigator?.seekTo(offsetSeconds)
    }

    @OptIn(InternalReadiumApi::class)
    suspend fun audioEnable(initialLocator: Locator?, preferences: FlutterAudioPreferences) {
        _audioPreferences = preferences

        currentPublication?.let { publication ->
            // Handle karaoke books - by creating a pseudo audio publication from the media overlays.
            val (ap, overlays) = publication.makeSyncAudiobook()

            audiobookNavigator?.dispose()
            syncAudiobookNavigator?.dispose()
            audiobookNavigator = null
            syncAudiobookNavigator = null

            if (overlays == null) {
                audiobookNavigator = AudiobookNavigator(
                    ap, this@ReadiumReader, initialLocator, preferences
                ).apply {
                    initNavigator()
                }
            } else {
                val ail = initialLocator ?: epubNavigator?.currentLocator?.value
                syncAudiobookNavigator = SyncAudiobookNavigator(
                    ap, overlays, this@ReadiumReader, ail, preferences
                ).apply {
                    initNavigator()
                }
            }
        } ?: throw Exception("Publication not opened")
    }

    suspend fun audioUpdatePreferences(preferences: FlutterAudioPreferences) {
        _audioPreferences = preferences

        mainScope.async {
            audiobookNavigator?.updatePreferences(preferences)
                ?: syncAudiobookNavigator?.updatePreferences(preferences)
                ?: throw Exception("Audio not enabled, cannot update preferences")
        }.await()
    }

    suspend fun applyDecorations(
        decorations: List<Decoration>, group: String
    ) {
        epubNavigator?.applyDecorations(decorations, group)
    }

    override fun onPageLoaded() {
        currentReaderWidget?.onPageLoaded()
    }

    override fun onPageChanged(
        pageIndex: Int, totalPages: Int, locator: Locator
    ) {
        currentReaderWidget?.onPageChanged(pageIndex, totalPages, locator)
    }

    override fun onExternalLinkActivated(url: AbsoluteUrl) {
        currentReaderWidget?.onExternalLinkActivated(url)
    }

    override fun onVisualCurrentLocationChanged(locator: Locator) {
        currentReaderWidget?.onVisualCurrentLocationChanged(locator)
    }

    override fun onVisualReaderIsReady() {
        currentReaderWidget?.onVisualReaderIsReady()
    }

    suspend fun getFirstVisibleLocator(): Locator? {
        return epubNavigator?.firstVisibleElementLocator()
    }

    suspend fun epubEvaluateJavascript(script: String): String? {
        return epubNavigator?.evaluateJavascript(script)
    }

    /**
     * Update EPUB navigator preferences.
     */
    fun epubUpdatePreferences(preferences: EpubPreferences) {
        epubNavigator?.updatePreferences(preferences)
    }

    /**
     * Go to a specific locator in the EPUB navigator, without scrolling to the locator position.
     */
    suspend fun epubGo(locator: Locator, animated: Boolean) {
        epubNavigator?.go(locator, animated)
    }

    /**
     * Go left (previous page) in the EPUB navigator.
     */
    fun epubGoLeft(animated: Boolean) {
        epubNavigator?.goLeft(animated)
    }

    /**
     * Go right (next page) in the EPUB navigator.
     */
    fun epubGoRight(animated: Boolean) {
        epubNavigator?.goRight(animated)
    }

    /**
     * Go to a specific locator in the EPUB navigator, this scrolls to the locator position if needed.
     */
    suspend fun epubGoToLocator(locator: Locator, animated: Boolean) {
        epubNavigator?.goToLocator(locator, animated)
    }

    /**
     * Get locator fragments from EPUB navigator.
     */
    suspend fun epubGetLocatorFragments(locator: Locator): Locator? {
        return epubNavigator?.getLocatorFragments(locator)
    }

    /**
     * Emit reader status update to the flutter layer.
     */
    fun emitReaderStatusUpdate(statusUpdate: ReadiumReaderStatus) {
        readiumReaderStatusEventChannel?.sendEvent(statusUpdate)
    }

    /**
     * Emit text locator to the flutter layer
     */
    fun emitTextLocatorUpdate(locator: Locator) {
        textLocatorEventChannel?.sendEvent(locator)
    }

    /**
     * Emit an error event to the flutter layer via the error event channel.
     */
    fun emitError(message: String, code: String? = null, data: String? = null) {
        errorEventChannel?.sendEvent(ReadiumErrorEvent(message = message, code = code, data = data))
    }

    // ─── PDF Support ─────────────────────────────────────────────────────────

    /**
     * Kiểm tra xem publication hiện tại có phải là PDF hay không.
     * PDF publications thường có readingOrder đầu tiên với mediaType chứa "pdf".
     */
    fun isCurrentPublicationPdf(): Boolean {
        val pub = _currentPublication ?: return false
        return isPdfPublication(pub)
    }

    /**
     * Helper: Kiểm tra [Publication] có phải là PDF không.
     */
    fun isPdfPublication(publication: org.readium.r2.shared.publication.Publication): Boolean {
        // Kiểm tra qua readingOrder media type
        val firstLinkType = publication.readingOrder.firstOrNull()?.mediaType?.toString() ?: ""
        if (firstLinkType.contains("pdf", ignoreCase = true)) return true

        // Kiểm tra qua manifest links
        val selfLink = publication.links.firstOrNull { it.rels.contains("self") }
        val selfType = selfLink?.mediaType?.toString() ?: ""
        if (selfType.contains("pdf", ignoreCase = true)) return true

        return false
    }

    /**
     * Lấy đường dẫn file PDF từ publication hiện tại (nếu là PDF).
     *
     * Trả về đường dẫn tuyệt đối đến file PDF trên thiết bị,
     * hoặc null nếu publication không phải PDF hoặc không phải local file.
     *
     * Path được cache trong [currentPdfFilePath] từ lúc [openPublication] thành công
     * để tránh re-parse URL (vấn đề với tên file có dấu cách).
     */
    fun getCurrentPdfFilePath(): String? {
        val path = cachedPdfFilePath
        Log.d(TAG, "getCurrentPdfFilePath: '$path' (currentPublicationUrl='$currentPublicationUrl')")
        return path
    }
}

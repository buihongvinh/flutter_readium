package dk.nota.flutter_readium

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import android.util.AttributeSet
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.LinearLayout.generateViewId
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.commitNow
import dk.nota.flutter_readium.events.ReadiumReaderStatus
import dk.nota.flutter_readium.fragments.EpubReaderFragment
import dk.nota.flutter_readium.fragments.PdfReaderFragment
import dk.nota.flutter_readium.navigators.EpubNavigator
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.AbsoluteUrl

private const val TAG = "ReadiumReaderView"
internal const val viewTypeChannelName = "dk.nota.flutter_readium/ReadiumReaderWidget"

@ExperimentalCoroutinesApi
@OptIn(ExperimentalReadiumApi::class)
class ReadiumReaderWidget(
    private val context: Context,
    id: Int,
    creationParams: Map<String?, Any?>,
    messenger: BinaryMessenger,
    attrs: AttributeSet? = null
) : PlatformView, MethodChannel.MethodCallHandler,
    EpubReaderFragment.Listener, EpubNavigator.VisualListener, PdfReaderFragment.Listener {

    private val channel: ReadiumReaderChannel

    /**
     * Make sure we only sent ready status once.
     */
    var hasSentReady = false

    private val layout: ViewGroup

    private val activity
        get() = (context as ContextWrapper).baseContext as FragmentActivity
    private val fragmentManager
        get() = activity.supportFragmentManager

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun getView(): View {
        //Log.d(TAG, "::getView")
        return layout
    }

    override fun dispose() {
        Log.d(TAG, "::dispose")

        // Đóng cả EPUB navigator lẫn PDF fragment nếu có
        ReadiumReader.epubClose()
        closePdfFragment()

        ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Closed)
        hasSentReady = false

        channel.setMethodCallHandler(null)

        mainScope.coroutineContext.cancelChildren()
        layout.removeAllViews()
    }

    override fun onFlutterViewAttached(flutterView: View) {
        // Seems to never be called, so can't use this. Flutter bug?
        Log.d(TAG, "::onFlutterViewAttached")
        super.onFlutterViewAttached(flutterView)
    }

    override fun onFlutterViewDetached() {
        // Seems to never be called, so can't use this. Flutter bug?
        Log.d(TAG, "::onFlutterViewDetached")
        super.onFlutterViewDetached()
    }

    init {
        Log.d(TAG, "::init")

        @Suppress("UNCHECKED_CAST")
        val initPrefsMap = creationParams["preferences"] as Map<String, Any?>?
        val publication = ReadiumReader.currentPublication
        val locatorString = creationParams["initialLocator"] as String?
        val allowScreenReaderNavigation = creationParams["allowScreenReaderNavigation"] as Boolean?
        var initialLocator =
            if (locatorString == null) null else Locator.fromJSON(jsonDecode(locatorString) as JSONObject)
        val initialPreferences =
            if (initPrefsMap == null) EpubPreferences() else epubPreferencesFromMap(
                initPrefsMap,
                null
            )
        Log.d(TAG, "publication = $publication")

        layout = LinearLayout(context, attrs)
        layout.id = generateViewId()
        layout.setBackgroundColor(Color.TRANSPARENT)
        layout.setPadding(0, 0, 0, 0)

        ReadiumReader.currentReaderWidget = this

        channel = ReadiumReaderChannel(messenger, "$viewTypeChannelName:$id")
        channel.setMethodCallHandler(this)

        ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Loading)

        hasSentReady = false

        // By default reader contents are hidden from screen-readers, as not to trap them within it.
        // This can be toggled back on via the 'allowScreenReaderNavigation' creation param.
        // See issue: https://notalib.atlassian.net/browse/NOTA-9828
        if (allowScreenReaderNavigation != true) {
            layout.importantForAccessibility =
                View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }

        // Remove existing fragments if any (this is to avoid crashing on restore).
        fragmentManager.findFragmentByTag(NAVIGATOR_FRAGMENT_TAG)?.let { fragment ->
            Log.d(TAG, "::init - remove existing navigator fragment")
            fragmentManager.commitNow { remove(fragment) }
        }
        fragmentManager.findFragmentByTag(PDF_FRAGMENT_TAG)?.let { fragment ->
            Log.d(TAG, "::init - remove existing PDF fragment")
            fragmentManager.commitNow { remove(fragment) }
        }

        mainScope.launch {
            // Kiểm tra xem publication hiện tại có phải PDF không để chọn navigator phù hợp.
            if (ReadiumReader.isCurrentPublicationPdf()) {
                Log.d(TAG, "::init - publication la PDF, parse va hien thi qua text")
                enablePdfViewer(initialLocator)
            } else {
                Log.d(TAG, "::init - publication là EPUB/WebPub, sử dụng EpubNavigator")
                ReadiumReader.epubEnable(
                    initialLocator,
                    initialPreferences,
                    fragmentManager,
                    layout,
                    this@ReadiumReaderWidget,
                )
            }
        }
    }

    override fun onPageLoaded() {
        Log.d(TAG, "::onPageLoaded")
    }

    // To avoid duplicate onPageChanged events.
    private var lastPageLoadedKey: String? = null

    override fun onPageChanged(pageIndex: Int, totalPages: Int, locator: Locator) {
        // Keep page index in the dedupe key so page transitions are not swallowed when
        // the locator progression still points to the same spanning text node.
        val currentKey = "$pageIndex/$totalPages@${locator.href}@${locator.locations.progression}"
        Log.d(
            TAG,
            "::onPageChanged $pageIndex/$totalPages ${locator.href} ${locator.locations.progression} ${locator.locations}"
        )

        if (lastPageLoadedKey == currentKey) {
            // Sometimes we get duplicate calls to onPageChanged with same locator.
            // Not sure why, but ignore them.
            return
        }

        lastPageLoadedKey = currentKey

        mainScope.launch {
            if (!hasSentReady) {
                hasSentReady = true

                ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Ready)
            }
            emitOnPageChanged(locator)
        }
    }

    override fun onExternalLinkActivated(url: AbsoluteUrl) {
        Log.d(TAG, "::onExternalLinkActivated $url")
        mainScope.launch { emitOnExternalLinkActivated(url) }
    }

    override fun onVisualCurrentLocationChanged(locator: Locator) {
        Log.d(TAG, "::onVisualCurrentLocationChanged $locator")
    }

    override fun onVisualReaderIsReady() {
        Log.d(TAG, "::onVisualReaderIsReady")
        if (!hasSentReady) {
            ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Ready)

            hasSentReady = true
        }
    }

    suspend fun getFirstVisibleLocator(): Locator? =
        withScope(mainScope) {
            pdfFragment?.let { fragment ->
                return@withScope createPdfLocator(
                    pageIndex = fragment.getCurrentPage(),
                    totalPages = fragment.getTotalPages(),
                    metrics = fragment.getTextMetrics(),
                )
            }
            ReadiumReader.getFirstVisibleLocator()
        }

    @Throws(IllegalArgumentException::class)
    private fun setPreferencesFromMap(prefMap: Map<String, Any?>) {
        Log.d(TAG, "::setPreferencesFromMap")
        val newPreferences = epubPreferencesFromMap(prefMap, null)
        updatePreferences(newPreferences)
    }

    private suspend fun emitOnPageChanged(locator: Locator) {
        try {
            val locatorWithFragments = ReadiumReader.epubGetLocatorFragments(locator)
            if (locatorWithFragments == null) {
                Log.e(TAG, "emitOnPageChanged: window.epubPage.getVisibleRange failed!")
                return
            }

            channel.onPageChanged(locatorWithFragments)
            ReadiumReader.emitTextLocatorUpdate(locatorWithFragments)
        } catch (e: Exception) {
            Log.e(TAG, "emitOnPageChanged: window.epubPage.getVisibleRange failed! $e")
        }
    }

    private fun emitOnExternalLinkActivated(url: AbsoluteUrl) {
        channel.onExternalLinkActivated(url)
    }

    private suspend fun setLocation(
        locator: Locator,
        isAudioBookWithText: Boolean
    ) {
        val json = locator.toJSON().toString()
        Log.d(TAG, "::scrollToLocations: Go to locations $json")
        evaluateJavascript("window.epubPage.setLocation($json, $isAudioBookWithText);")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // TODO: To be safe we're doing everything on the Main thread right now.
        // Could probably optimize by using .IO and then change to Main
        // when affecting readerView or returning a result.
        mainScope.launch {
            Log.d(TAG, "::onMethodCall ${call.method}")
            when (call.method) {
                "setPreferences" -> {
                    @Suppress("UNCHECKED_CAST")
                    val prefsMap = call.arguments as Map<String, Any?>
                    try {
                        setPreferencesFromMap(prefsMap)
                        result.success(null)
                    } catch (ex: Exception) {
                        result.error("FlutterReadium", "Failed to set preferences", ex.message)
                    }
                }

                "go" -> {
                    val args = call.arguments as List<*>
                    val locatorJson = JSONObject(args[0] as String)
                    val animated = args[1] as Boolean
                    val isAudioBookWithText = args[2] as Boolean
                    if (locatorJson.optString("type") == "") {
                        locatorJson.put("type", " ")
                        Log.e(
                            TAG,
                            "Got locator with empty type! This shouldn't happen. $locatorJson"
                        )
                    }
                    val locator = Locator.fromJSON(locatorJson)!!
                    pdfFragment?.let { fragment ->
                        val pageIndex = (locator.locations.position ?: 1) - 1
                        fragment.goToPage(pageIndex)
                        result.success(null)
                        return@launch
                    }
                    ReadiumReader.epubGoToLocator(locator, animated)
                    setLocation(locator, isAudioBookWithText)
                    result.success(null)
                }

                "goLeft" -> {
                    val animated = call.arguments as Boolean
                    goLeft(animated)
                    result.success(null)
                }

                "goRight" -> {
                    val animated = call.arguments as Boolean
                    goRight(animated)
                    result.success(null)
                }

                "setLocation" -> {
                    val args = call.arguments as List<*>
                    val locatorJson = JSONObject(args[0] as String)
                    val isAudioBookWithText = args[1] as Boolean
                    val locator = Locator.fromJSON(locatorJson)!!
                    pdfFragment?.let { fragment ->
                        val pageIndex = (locator.locations.position ?: 1) - 1
                        fragment.goToPage(pageIndex)
                        result.success(null)
                        return@launch
                    }
                    setLocation(locator, isAudioBookWithText)
                    result.success(null)
                }

                "isLocatorVisible" -> {
                    val args = call.arguments as String
                    val locatorJson = JSONObject(args)
                    val locator = Locator.fromJSON(locatorJson)!!
                    pdfFragment?.let { fragment ->
                        result.success(locator.locations.position == fragment.getCurrentPage() + 1)
                        return@launch
                    }
                    var visible = locator.href == ReadiumReader.epubCurrentLocator?.href
                    if (visible) {
                        val jsonRes =
                            evaluateJavascript("window.epubPage.isLocatorVisible($args);")
                                ?: "false"
                        try {
                            visible = jsonDecode(jsonRes) as Boolean
                        } catch (e: Error) {
                            Log.e(TAG, "::isLocatorVisible - invalid response:$jsonRes - e:$e")
                            visible = false
                        }
                    }
                    result.success(visible)
                }

                "getLocatorFragments" -> {
                    val args = call.arguments as String?
                    Log.d(TAG, "::====== $args")
                    val locatorJson = JSONObject(args!!)
                    Log.d(TAG, "::====== $locatorJson")

                    pdfFragment?.let { fragment ->
                        val locator = Locator.fromJSON(locatorJson)
                        val pageIndex = (locator?.locations?.position ?: fragment.getCurrentPage() + 1) - 1
                        val locatorWithMetrics = createPdfLocator(
                            pageIndex = pageIndex,
                            totalPages = fragment.getTotalPages(),
                            metrics = fragment.getTextMetrics(pageIndex),
                        )
                        result.success(jsonEncode(locatorWithMetrics?.toJSON() ?: locatorJson))
                        return@launch
                    }

                    val locator =
                        ReadiumReader.epubGetLocatorFragments(Locator.fromJSON(locatorJson)!!)
                    Log.d(TAG, "::====== $locator")

                    result.success(jsonEncode(locator?.toJSON()))
                }

                "applyDecorations" -> {
                    val args = call.arguments as List<*>
                    val groupId = args[0] as String

                    @Suppress("UNCHECKED_CAST")
                    val decorationListStr = args[1] as List<Map<String, String>>
                    val decorations = decorationListStr.mapNotNull { decorationFromMap(it) }

                    ReadiumReader.applyDecorations(decorations, groupId)
                    result.success(null)
                }

                "dispose" -> {
                    dispose()
                    result.success(null)
                }

                "getCurrentLocator" -> {
                    pdfFragment?.let { fragment ->
                        result.success(
                            createPdfLocator(
                                pageIndex = fragment.getCurrentPage(),
                                totalPages = fragment.getTotalPages(),
                                metrics = fragment.getTextMetrics(),
                            )?.let { jsonEncode(it.toJSON()) }
                        )
                        return@launch
                    }
                    result.success(ReadiumReader.epubCurrentLocator?.let { jsonEncode(it.toJSON()) })
                }

                else -> {
                    Log.e(TAG, "Unhandled call ${call.method}")
                    result.notImplemented()
                }
            }
        }
    }

    fun go(locator: Locator, animated: Boolean) {
        Log.d(TAG, "::go ${locator.href}")
        mainScope.launch {
            pdfFragment?.let { fragment ->
                val pageIndex = (locator.locations.position ?: 1) - 1
                fragment.goToPage(pageIndex)
                return@launch
            }
            ReadiumReader.epubGoToLocator(locator, animated)
        }
    }

    private fun goLeft(animated: Boolean) {
        Log.d(TAG, "::goLeft")
        pdfFragment?.let { fragment ->
            fragment.goToPage(fragment.getCurrentPage() - 1)
            return
        }
        ReadiumReader.epubGoLeft(animated)
    }

    private fun goRight(animated: Boolean) {
        pdfFragment?.let { fragment ->
            fragment.goToPage(fragment.getCurrentPage() + 1)
            return
        }
        ReadiumReader.epubGoRight(animated)
    }

    private suspend fun evaluateJavascript(script: String): String? {
        val ret = ReadiumReader.epubEvaluateJavascript(script)
        if (ret == null || ret == "null" || ret == "undefined") {
            // Hopefully can't happen.
            Log.e(TAG, "::evaluateJavascript($script) returned null $ret")

            return null
        }

        return ret
    }

    private fun updatePreferences(preferences: EpubPreferences) {
        ReadiumReader.epubUpdatePreferences(preferences)
    }

    // ─── PDF Support ─────────────────────────────────────────────────────────

    /** Tham chiếu đến PdfReaderFragment đang active (nếu có). */
    private var pdfFragment: PdfReaderFragment? = null

    /**
     * Khởi tạo và hiển thị [PdfReaderFragment] cho publication PDF theo luồng text.
     *
     * @param initialLocator  Locator ban đầu (hiện tại chỉ dùng để lấy trang đầu).
     */
    private suspend fun enablePdfViewer(initialLocator: org.readium.r2.shared.publication.Locator?) {
        val filePath = ReadiumReader.getCurrentPdfFilePath()
        if (filePath == null) {
            Log.e(TAG, "enablePdfViewer: khong tim thay duong dan file PDF")
            ReadiumReader.emitError(
                message = "PDF file path not found. The publication URL could not be resolved to a local file path.",
                code = "pdf_path_not_found",
            )
            ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Error)
            return
        }

        Log.d(TAG, "enablePdfViewer: $filePath")

        // Lấy số trang ban đầu từ locator nếu có
        val initialPage = initialLocator?.locations?.position?.let { it - 1 }?.coerceAtLeast(0) ?: 0

        // Giữ tham số renderWidth để tương thích với factory hiện tại; fragment text không render bitmap.
        val renderWidth = layout.width.takeIf { it > 0 } ?: 1080

        val fragment = PdfReaderFragment.newInstance(
            pdfFilePath = filePath,
            initialPage = initialPage,
            renderWidth = renderWidth,
        ).also {
            it.listener = this@ReadiumReaderWidget
        }

        pdfFragment = fragment

        ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Loading)

        // Dùng overload add(ViewGroup, Fragment, tag) thay vì add(containerViewId, Fragment, tag)
        // để tránh lỗi "Invalid resource ID" khi layout chưa được attach vào Activity hierarchy.
        // Pattern này giống EPUB: epubNavigator.attachNavigator(fragmentManager, viewGroup)
        // cũng gọi fragmentManager.commitNow { add(viewGroup, navigator, tag) }.
        fragmentManager.commitNow {
            add(layout, fragment, PDF_FRAGMENT_TAG)
        }
    }

    /** Đóng và xóa PdfReaderFragment nếu đang hiển thị. */
    private fun closePdfFragment() {
        pdfFragment?.let { fragment ->
            if (fragment.isAdded) {
                fragmentManager.commitNow { remove(fragment) }
            }
            pdfFragment = null
            Log.d(TAG, "closePdfFragment: đã đóng PDF fragment")
        }
    }

    // ─── PdfReaderFragment.Listener ──────────────────────────────────────────

    override fun onPdfReady() {
        Log.d(TAG, "onPdfReady")
        if (!hasSentReady) {
            hasSentReady = true
            ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Ready)
        }
    }

    override fun onPdfError(message: String) {
        Log.e(TAG, "onPdfError: $message")
        ReadiumReader.emitReaderStatusUpdate(ReadiumReaderStatus.Error)
    }

    override fun onPdfPageChanged(pageIndex: Int, totalPages: Int) {
        Log.d(TAG, "onPdfPageChanged: page ${pageIndex + 1}/$totalPages")
        val locator = createPdfLocator(pageIndex, totalPages, pdfFragment?.getTextMetrics(pageIndex))
        if (locator != null) {
            channel.onPageChanged(locator)
            ReadiumReader.emitTextLocatorUpdate(locator)
        } else {
            Log.w(TAG, "onPdfPageChanged: khong the tao Locator tu PDF text page")
        }
    }

    private fun createPdfLocator(
        pageIndex: Int,
        totalPages: Int,
        metrics: PdfReaderFragment.PdfTextMetrics? = null,
    ): Locator? {
        val hrefStr = ReadiumReader.currentPublication
            ?.readingOrder
            ?.firstOrNull()
            ?.url()
            ?.toString()
            ?: ReadiumReader.currentPublicationUrl
            ?: return null

        val progression = if (totalPages > 0) pageIndex.toDouble() / totalPages else 0.0
        val fragments = org.json.JSONArray().apply {
            put("page=${pageIndex + 1}")
            put("totalPages=$totalPages")
            metrics?.let {
                put("textHeight=${it.textHeight}")
                put("heightText=${it.textHeight}")
                put("viewportHeight=${it.viewportHeight}")
                put("scrollY=${it.scrollY}")
                put("pageTop=${it.pageTop}")
                put("pageHeight=${it.pageHeight}")
            }
        }
        val locatorJson = org.json.JSONObject().apply {
            put("href", hrefStr)
            put("type", "application/pdf")
            put("locations", org.json.JSONObject().apply {
                put("position", pageIndex + 1)
                put("totalProgression", progression)
                put("progression", progression)
                put("fragments", fragments)
            })
        }
        return Locator.fromJSON(locatorJson)
    }

    companion object {
        const val NAVIGATOR_FRAGMENT_TAG = "NAVIGATOR_READER_FRAGMENT"
        const val PDF_FRAGMENT_TAG = "PDF_READER_FRAGMENT"
    }
}

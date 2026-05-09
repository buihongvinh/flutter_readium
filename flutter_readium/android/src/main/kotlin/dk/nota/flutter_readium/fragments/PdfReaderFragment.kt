package dk.nota.flutter_readium.fragments

import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.setPadding
import androidx.fragment.app.Fragment
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private const val TAG = "PdfReaderFragment"

/**
 * Fragment hien thi PDF theo luong text.
 *
 * File PDF duoc parse thanh text theo tung trang bang PDFBox Android, sau do render
 * bang TextView thay vi mo/render PDF bitmap truc tiep.
 */
class PdfReaderFragment : Fragment() {

    interface Listener {
        /** Duoc goi khi text PDF da parse va hien thi xong. */
        fun onPdfReady()

        /** Duoc goi khi xay ra loi parse PDF. */
        fun onPdfError(message: String)

        /** Duoc goi khi nguoi dung cuon den trang moi. */
        fun onPdfPageChanged(pageIndex: Int, totalPages: Int)
    }

    companion object {
        private const val ARG_PDF_FILE_PATH = "pdf_file_path"
        private const val ARG_INITIAL_PAGE = "initial_page"
        private const val ARG_RENDER_WIDTH = "render_width"

        fun newInstance(
            pdfFilePath: String,
            initialPage: Int = 0,
            renderWidth: Int = 1080,
        ): PdfReaderFragment {
            return PdfReaderFragment().apply {
                arguments = Bundle().apply {
                    putString(ARG_PDF_FILE_PATH, pdfFilePath)
                    putInt(ARG_INITIAL_PAGE, initialPage)
                    putInt(ARG_RENDER_WIDTH, renderWidth)
                }
            }
        }
    }

    private data class PdfTextPage(
        val pageIndex: Int,
        val totalPages: Int,
        val text: String,
    )

    data class PdfTextMetrics(
        val pageIndex: Int,
        val totalPages: Int,
        val scrollY: Int,
        val viewportHeight: Int,
        val textHeight: Int,
        val pageTop: Int,
        val pageHeight: Int,
    )

    var listener: Listener? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var parseJob: Job? = null

    private lateinit var scrollView: ScrollView
    private lateinit var pageContainer: LinearLayout
    private lateinit var progressBar: ProgressBar

    private var currentPageIndex = 0
    private var totalPages = 0

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View {
        val rootLayout = LinearLayout(requireContext()).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            setBackgroundColor(android.graphics.Color.parseColor("#FAFAFA"))
        }

        progressBar = ProgressBar(requireContext()).apply {
            visibility = View.VISIBLE
        }
        rootLayout.addView(
            progressBar,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).also {
                it.gravity = android.view.Gravity.CENTER_HORIZONTAL
                it.topMargin = 32
            }
        )

        pageContainer = LinearLayout(requireContext()).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16)
        }

        scrollView = ScrollView(requireContext()).apply {
            addView(
                pageContainer,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                )
            )
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.MATCH_PARENT,
            )
            setOnScrollChangeListener { _, _, scrollY, _, _ ->
                updateCurrentPageFromScroll(scrollY)
            }
        }
        rootLayout.addView(scrollView)

        return rootLayout
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val filePath = arguments?.getString(ARG_PDF_FILE_PATH)
        val initialPage = arguments?.getInt(ARG_INITIAL_PAGE, 0) ?: 0

        if (filePath == null) {
            listener?.onPdfError("Khong co duong dan file PDF")
            return
        }

        parsePdfText(filePath, initialPage)
    }

    private fun parsePdfText(filePath: String, initialPage: Int) {
        parseJob?.cancel()
        parseJob = scope.launch {
            Log.d(TAG, "Bat dau parse text PDF: $filePath")
            progressBar.visibility = View.VISIBLE
            pageContainer.removeAllViews()
            currentPageIndex = 0
            totalPages = 0
            val appContext = requireContext().applicationContext

            try {
                val pages = withContext(Dispatchers.IO) {
                    extractTextPages(filePath, appContext)
                }

                totalPages = pages.firstOrNull()?.totalPages ?: 0
                if (totalPages == 0) {
                    progressBar.visibility = View.GONE
                    listener?.onPdfError("PDF khong co trang nao de parse")
                    return@launch
                }

                pages.forEach { page ->
                    addTextPageView(page)
                }

                progressBar.visibility = View.GONE

                val targetPage = initialPage.coerceIn(0, (totalPages - 1).coerceAtLeast(0))
                if (targetPage > 0) {
                    scrollToPage(targetPage)
                }
                currentPageIndex = targetPage
                listener?.onPdfPageChanged(targetPage, totalPages)
                listener?.onPdfReady()

                Log.d(TAG, "Parse text PDF hoan tat: $totalPages trang")
            } catch (e: Exception) {
                Log.e(TAG, "Loi parse text PDF: $e")
                progressBar.visibility = View.GONE
                listener?.onPdfError("Loi parse text PDF: ${e.message}")
            }
        }
    }

    private fun extractTextPages(filePath: String, appContext: android.content.Context): List<PdfTextPage> {
        PDFBoxResourceLoader.init(appContext)

        val file = File(filePath)
        check(file.exists()) { "PDF file khong ton tai: $filePath" }

        PDDocument.load(file).use { doc ->
            val pageCount = doc.numberOfPages
            val stripper = PDFTextStripper().apply {
                sortByPosition = true
            }

            return (0 until pageCount).map { pageIndex ->
                stripper.startPage = pageIndex + 1
                stripper.endPage = pageIndex + 1
                PdfTextPage(
                    pageIndex = pageIndex,
                    totalPages = pageCount,
                    text = stripper.getText(doc).trim(),
                )
            }
        }
    }

    private fun addTextPageView(page: PdfTextPage) {
        val text = if (page.text.isBlank()) {
            ""
        } else {
            page.text
        }

        val textView = TextView(requireContext()).apply {
            setTextColor(android.graphics.Color.parseColor("#202124"))
            textSize = 18f
            setLineSpacing(4f, 1.08f)
            setPadding(20, 18, 20, 28)
            setTextIsSelectable(true)
            contentDescription = "Trang ${page.pageIndex + 1} / ${page.totalPages}"
            this.text = text
        }

        val params = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).also { it.bottomMargin = 12 }

        pageContainer.addView(textView, params)
    }

    private fun updateCurrentPageFromScroll(scrollY: Int) {
        if (totalPages <= 0 || pageContainer.childCount == 0) return

        val markerY = scrollY + (scrollView.height * 0.25f).toInt()
        var visiblePage = currentPageIndex

        for (index in 0 until pageContainer.childCount) {
            val child = pageContainer.getChildAt(index)
            if (markerY >= child.top) {
                visiblePage = index
            } else {
                break
            }
        }

        if (visiblePage != currentPageIndex) {
            currentPageIndex = visiblePage
            listener?.onPdfPageChanged(visiblePage, totalPages)
        }
    }

    private fun scrollToPage(pageIndex: Int) {
        if (pageIndex < 0 || pageIndex >= pageContainer.childCount) return

        val targetView = pageContainer.getChildAt(pageIndex) ?: return
        scrollView.post {
            scrollView.smoothScrollTo(0, targetView.top)
        }
    }

    fun goToPage(pageIndex: Int) {
        if (totalPages <= 0) return
        val targetPage = pageIndex.coerceIn(0, totalPages - 1)
        currentPageIndex = targetPage
        scrollToPage(targetPage)
        listener?.onPdfPageChanged(targetPage, totalPages)
    }

    fun getTotalPages(): Int = totalPages

    fun getCurrentPage(): Int = currentPageIndex

    fun getTextMetrics(pageIndex: Int = currentPageIndex): PdfTextMetrics? {
        if (totalPages <= 0 || pageContainer.childCount == 0) return null

        val safePageIndex = pageIndex.coerceIn(0, pageContainer.childCount - 1)
        val pageView = pageContainer.getChildAt(safePageIndex) ?: return null

        return PdfTextMetrics(
            pageIndex = safePageIndex,
            totalPages = totalPages,
            scrollY = scrollView.scrollY,
            viewportHeight = scrollView.height,
            textHeight = pageContainer.height,
            pageTop = pageView.top,
            pageHeight = pageView.height,
        )
    }

    override fun onDestroyView() {
        super.onDestroyView()
        parseJob?.cancel()
        scope.coroutineContext.cancelChildren()
        Log.d(TAG, "PdfReaderFragment destroyed")
    }
}

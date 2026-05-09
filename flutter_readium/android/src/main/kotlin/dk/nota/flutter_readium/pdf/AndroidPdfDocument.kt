package dk.nota.flutter_readium.pdf

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.util.Log
import org.readium.r2.shared.util.pdf.PdfDocument
import java.io.File

private const val TAG = "AndroidPdfDocument"

/**
 * Triển khai [PdfDocument] sử dụng [android.graphics.pdf.PdfRenderer] tích hợp sẵn của Android.
 * Không yêu cầu thư viện PDF thương mại như PSPDFKit.
 *
 * Lưu ý: [PdfRenderer] không cung cấp metadata (tiêu đề, tác giả, v.v.) hay mục lục PDF,
 * nên các trường đó sẽ trả về null/empty.
 */
class AndroidPdfDocument(
    internal val renderer: PdfRenderer,
    internal val tempFile: File,
    private val sourceFileName: String,
    /**
     * Nếu true (mặc định), [tempFile] sẽ bị xóa khi [close] được gọi.
     * Đặt false khi [tempFile] là file gốc của người dùng (không phải file tạm).
     */
    private val deleteTempFileOnClose: Boolean = true,
) : PdfDocument {

    override val identifier: String? = sourceFileName
    override val pageCount: Int get() = renderer.pageCount
    override val title: String? = null          // PdfRenderer không expose metadata
    override val subject: String? = null
    override val keywords: List<String> = emptyList()
    override val outline: List<PdfDocument.OutlineNode> = emptyList()

    /**
     * Render một trang PDF thành [Bitmap].
     *
     * @param pageIndex  Chỉ số trang (0-based).
     * @param width      Chiều rộng mong muốn của bitmap (pixels). Nếu null, dùng kích thước gốc.
     * @return [Bitmap] đã render, hoặc null nếu thất bại.
     */
    fun renderPage(pageIndex: Int, width: Int? = null): Bitmap? {
        if (pageIndex < 0 || pageIndex >= pageCount) {
            Log.w(TAG, "renderPage: pageIndex $pageIndex ngoài phạm vi [0, $pageCount)")
            return null
        }

        return try {
            renderer.openPage(pageIndex).use { page ->
                val pageWidth = page.width
                val pageHeight = page.height

                // Tính kích thước bitmap giữ tỷ lệ khung hình
                val targetWidth = width ?: pageWidth
                val scale = targetWidth.toFloat() / pageWidth
                val targetHeight = (pageHeight * scale).toInt()

                val bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
                // Tô nền trắng trước khi render (PDF có thể có nền trong suốt)
                bitmap.eraseColor(android.graphics.Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                bitmap
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi render trang $pageIndex: $e")
            null
        }
    }

    override fun close() {
        try {
            renderer.close()
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi đóng PdfRenderer: $e")
        }
        if (deleteTempFileOnClose) {
            try {
                if (tempFile.exists()) {
                    tempFile.delete()
                    Log.d(TAG, "Đã xóa file PDF tạm: ${tempFile.path}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi xóa file PDF tạm: $e")
            }
        }
    }
}

package dk.nota.flutter_readium.pdf

import android.content.Context
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.readium.r2.shared.util.ThrowableError
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.data.ReadError
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.pdf.PdfDocumentFactory
import org.readium.r2.shared.util.resource.Resource
import java.io.File
import kotlin.reflect.KClass

private const val TAG = "AndroidPdfDocumentFactory"

/**
 * Triển khai [PdfDocumentFactory] sử dụng [android.graphics.pdf.PdfRenderer] tích hợp sẵn của Android.
 *
 * Factory này cho phép Readium parse và đọc file PDF mà không cần thư viện thương mại
 * như PSPDFKit. Phù hợp cho các tác vụ đọc cơ bản và hiển thị nội dung PDF.
 *
 * Sử dụng:
 * ```kotlin
 * val publicationOpener = PublicationOpener(
 *     publicationParser = DefaultPublicationParser(
 *         context,
 *         assetRetriever = assetRetriever,
 *         httpClient = httpClient,
 *         pdfFactory = AndroidPdfDocumentFactory(context),  // <-- Bật PDF support
 *     ),
 * )
 * ```
 */
class AndroidPdfDocumentFactory(private val context: Context) : PdfDocumentFactory<AndroidPdfDocument> {

    override val documentType: KClass<AndroidPdfDocument> = AndroidPdfDocument::class

    override suspend fun open(resource: Resource, password: String?): Try<AndroidPdfDocument, ReadError> {
        // Bước 1: Đọc bytes từ resource — getOrElse với non-local return từ hàm open()
        // (phải thực hiện ngoài withContext để non-local return hoạt động đúng)
        val bytes = withContext(Dispatchers.IO) { resource.read() }
            .getOrElse { readError ->
                Log.e(TAG, "Không thể đọc resource PDF: $readError")
                return Try.failure(readError)
            }

        // Bước 2: Ghi vào file tạm và mở PdfRenderer — toàn bộ I/O trên Dispatchers.IO
        return withContext(Dispatchers.IO) {
            try {
                val tempFile = File.createTempFile("readium_pdf_", ".pdf", context.cacheDir)
                tempFile.writeBytes(bytes)
                Log.d(TAG, "Đã ghi ${bytes.size} bytes vào file tạm: ${tempFile.path}")

                val pfd = ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_ONLY)
                val renderer = PdfRenderer(pfd)
                Log.d(TAG, "Đã mở PDF với ${renderer.pageCount} trang")

                val sourceFileName = resource.sourceUrl?.path?.split("/")?.lastOrNull()
                    ?: tempFile.name

                Try.success(
                    AndroidPdfDocument(
                        renderer = renderer,
                        tempFile = tempFile,
                        sourceFileName = sourceFileName,
                        // tempFile là file tạm do factory tạo ra → xóa khi close
                        deleteTempFileOnClose = true,
                    )
                )
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi mở PDF document: $e")
                Try.failure(ReadError.Decoding(ThrowableError(e)))
            }
        }
    }
}

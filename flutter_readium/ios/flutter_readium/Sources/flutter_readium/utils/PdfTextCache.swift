import Foundation

/// Cache text đã extract từ PDF xuống disk để tránh parse lại mỗi lần mở.
///
/// Vị trí: `<ApplicationSupport>/readium_flutter/cached/<tên_file>.textcache.json`
/// (cùng thư mục với `publicationCacheDir` bên Dart)
///
/// Invalidation: so sánh modification date của file PDF – nếu PDF thay đổi thì
/// cache tự động bị bỏ qua và extract lại.
enum PdfTextCache {

  // MARK: - Kiểu dữ liệu

  struct CachedPage: Codable {
    let pageIndex: Int
    let totalPages: Int
    let text: String
  }

  private struct CacheEnvelope: Codable {
    /// modification date của file PDF tại thời điểm cache được tạo (timeIntervalSince1970).
    let pdfModDate: Double
    let pages: [CachedPage]
  }

  // MARK: - Public API

  /// Đọc cache cho PDF tại `pdfURL`.
  /// Trả về `nil` nếu chưa có cache hoặc cache đã stale (PDF đã thay đổi).
  static func load(for pdfURL: URL) -> [CachedPage]? {
    guard pdfURL.isFileURL,
          let cacheURL = cacheFileURL(for: pdfURL),
          FileManager.default.fileExists(atPath: cacheURL.path)
    else { return nil }

    do {
      let data = try Data(contentsOf: cacheURL)
      let envelope = try JSONDecoder().decode(CacheEnvelope.self, from: data)

      // Invalidate nếu PDF đã bị thay đổi sau khi cache được tạo.
      let currentModDate = modificationDate(of: pdfURL) ?? 0
      guard abs(envelope.pdfModDate - currentModDate) < 1 else {
        print("[PdfTextCache] cache stale cho \(pdfURL.lastPathComponent) – sẽ extract lại")
        return nil
      }

      print("[PdfTextCache] cache hit: \(envelope.pages.count) trang từ \(cacheURL.lastPathComponent)")
      return envelope.pages
    } catch {
      print("[PdfTextCache] lỗi đọc cache: \(error)")
      return nil
    }
  }

  /// Lưu `pages` vào cache cho PDF tại `pdfURL`.
  /// Gọi trong background – không throw, chỉ log lỗi nếu có.
  static func save(_ pages: [CachedPage], for pdfURL: URL) {
    guard pdfURL.isFileURL,
          let cacheURL = cacheFileURL(for: pdfURL)
    else { return }

    let dir = cacheURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let modDate = modificationDate(of: pdfURL) ?? Date().timeIntervalSince1970
    let envelope = CacheEnvelope(pdfModDate: modDate, pages: pages)

    do {
      let data = try JSONEncoder().encode(envelope)
      try data.write(to: cacheURL, options: .atomic)
      print("[PdfTextCache] đã lưu \(pages.count) trang → \(cacheURL.lastPathComponent)")
    } catch {
      print("[PdfTextCache] lỗi ghi cache: \(error)")
    }
  }

  // MARK: - Private helpers

  private static func cacheFileURL(for pdfURL: URL) -> URL? {
    guard let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first else { return nil }

    let cacheDir = appSupport
      .appendingPathComponent("readium_flutter")
      .appendingPathComponent("cached")

    // Percent-encode tên file để cache key chỉ chứa ASCII an toàn,
    // tránh lỗi khi tên PDF có ký tự tiếng Việt, dấu cách, hay ký tự đặc biệt.
    let rawName = pdfURL.deletingPathExtension().lastPathComponent
    let safeName = rawName.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
      ?? rawName.data(using: .ascii, allowLossyConversion: true)
          .map { String(data: $0, encoding: .ascii) ?? "pdf" } ?? "pdf"
    return cacheDir.appendingPathComponent("\(safeName).textcache.json")
  }

  private static func modificationDate(of url: URL) -> Double? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
  }
}

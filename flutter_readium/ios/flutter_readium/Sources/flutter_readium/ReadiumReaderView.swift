import ReadiumNavigator
import ReadiumAdapterGCDWebServer
import ReadiumShared
import Flutter
import UIKit
import WebKit
import PDFKit

private let TAG = "ReadiumReaderView"
private let ReadiumReaderStatusReady = "ready"
private let ReadiumReaderStatusLoading = "loading"
private let ReadiumReaderStatusClosed = "closed"
private let ReadiumReaderStatusError = "error"

let readiumReaderViewType = "dk.nota.flutter_readium/ReadiumReaderWidget"

let allowedInitialFragments = ["id", "t", "viewrect", "xywh"]

class ReadiumBugLogger: ReadiumShared.WarningLogger {
  func log(_ warning: Warning) {
    print(TAG, "Error in Readium: \(warning)")
  }
}

private let readiumBugLogger = ReadiumBugLogger()
private var userScripts: [WKUserScript] = []
private let jsonEncoder = JSONEncoder()

private func emitReaderStatusChanged(status: String) {
  let jsonData = try! jsonEncoder.encode(status)
  if let jsonStsring = String(data: jsonData, encoding: .utf8){
    FlutterReadiumPlugin.instance?.readerStatusStreamHandler?.sendEvent(jsonStsring)
  }
}

public class ReadiumReaderView: NSObject, FlutterPlatformView, EPUBNavigatorDelegate, VisualNavigatorDelegate, UIScrollViewDelegate {

  private let channel: ReadiumReaderChannel
  private let _view: UIView

  /// Navigator EPUB – được khởi tạo khi publication là EPUB/WebPub.
  private var epubNavigatorViewController: EPUBNavigatorViewController?

  /// Text reader PDF – được khởi tạo khi publication là PDF.
  private var pdfTextScrollView: UIScrollView?
  private var pdfTextStackView: UIStackView?
  private var pdfTextPageViews: [UIView] = []
  private var pdfTextPublication: Publication?
  private var pdfTextPageCount = 0
  private var pdfTextCurrentPageIndex = 0
  private var pdfTextIsProgrammaticScroll = false

  private var isVerticalScroll = false
  private var hasSentReady = false
  private var initialLocatorForRestore: Locator?
  private var cachedLocator: Locator?
  private var hasAcceptedEpubLocator = false

  var publicationIdentifier: String?

  public func view() -> UIView {
    print(TAG, "::getView")
    return _view
  }

  deinit {
    print(TAG, "::dispose")
    epubNavigatorViewController?.view.removeFromSuperview()
    epubNavigatorViewController?.delegate = nil
    clearPdfTextReader()
    channel.setMethodCallHandler(nil)
    FlutterReadiumPlugin.instance?.setCurrentReadiumReaderView(nil)
  }

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    registrar: FlutterPluginRegistrar
  ) {
    print(TAG, "::init")
    let creationParams = args as! Dictionary<String, Any?>

    let publication = FlutterReadiumPlugin.instance!.getCurrentPublication()!

    let preferencesMap = creationParams["preferences"] as? Dictionary<String, String>?
    let defaultPreferences = preferencesMap == nil ? nil : EPUBPreferences.init(fromMap: preferencesMap!!)

    let locatorStr = creationParams["initialLocator"] as? String
    var locator = locatorStr == nil ? nil : try! Locator.init(jsonString: locatorStr!)
    print(TAG, "publication = \(publication)")

    // TODO: Our custom fragments (particularly page=x) messes up the in-chapter location.
    // only allow whitelist from https://readium.org/architecture/models/locators/best-practices/format.html
    locator?.locations.fragments.removeAll(where: { !allowedInitialFragments.contains(String($0.split(separator: "=").first ?? "none")) })
    initialLocatorForRestore = locator
    cachedLocator = locator

    channel = ReadiumReaderChannel(
      name: "\(readiumReaderViewType):\(viewId)", binaryMessenger: registrar.messenger())

    emitReaderStatusChanged(status: ReadiumReaderStatusLoading)

    print(TAG, "Publication: (identifier=\(String(describing: publication.metadata.identifier)),title=\(String(describing: publication.metadata.title)))")
    print(TAG, "Added publication at \(String(describing: publication.baseURL))")

    _view = UIView()
    super.init()

    channel.setMethodCallHandler(onMethodCall)

    // ── Phân nhánh theo loại publication ──────────────────────────────────────
    // Dùng isPdfPublication() để kiểm tra qua mediaType (không phụ thuộc vào Publication.Profile.pdf)
    if isPdfPublication(publication) {
      print(TAG, "::init - publication la PDF, parse va hien thi qua text")
      initPdfTextReader(publication: publication, locator: locator)
    } else {
      print(TAG, "::init - publication là EPUB/WebPub, sử dụng EPUBNavigatorViewController")
      initEpubNavigator(
        publication: publication,
        locator: locator,
        defaultPreferences: defaultPreferences,
        registrar: registrar
      )
    }

    FlutterReadiumPlugin.instance?.setCurrentReadiumReaderView(self)
    publicationIdentifier = publication.metadata.identifier
    print(TAG, "::init success")
  }

  // ── Khởi tạo EPUB Navigator ─────────────────────────────────────────────────

  private func initEpubNavigator(
    publication: Publication,
    locator: Locator?,
    defaultPreferences: EPUBPreferences?,
    registrar: FlutterPluginRegistrar
  ) {
    // Remove undocumented Readium default 20dp or 44dp top/bottom padding.
    var config = EPUBNavigatorViewController.Configuration()
    config.contentInset = [
      .compact: (top: 0, bottom: 0),
      .regular: (top: 0, bottom: 0),
    ]
    config.preloadPreviousPositionCount = 2
    config.preloadNextPositionCount = 4
    config.debugState = true
    config.decorationTemplates = HTMLDecorationTemplate.defaultTemplates(alpha: 1.0, experimentalPositioning: true)
    config.editingActions = [.lookup, .translate, EditingAction(title: "Custom Highlight Action", action: #selector(onCustomEditingAction))]

    if let prefs = defaultPreferences {
      config.preferences = prefs
    }

    let navigator = try! EPUBNavigatorViewController(
      publication: publication,
      initialLocation: locator,
      config: config,
      httpServer: sharedReadium.httpServer!
    )

    if userScripts.isEmpty {
      initUserScripts(registrar: registrar)
    }

    epubNavigatorViewController = navigator
    navigator.delegate = self

    embedChildView(navigator.view)

    DirectionalNavigationAdapter(
      pointerPolicy: .init(types: [.mouse, .touch])
    ).bind(to: navigator)
  }

  // ── Khởi tạo PDF text reader ────────────────────────────────────────────────

  private struct PdfTextPage {
    let pageIndex: Int
    let totalPages: Int
    let text: String
  }

  private func initPdfTextReader(publication: Publication, locator: Locator?) {
    pdfTextPublication = publication
    pdfTextCurrentPageIndex = max((locator?.locations.position ?? 1) - 1, 0)

    let scrollView = UIScrollView()
    scrollView.alwaysBounceVertical = true
    scrollView.backgroundColor = .systemBackground
    scrollView.delegate = self
    // FIX: Tắt delay để UITextView nhận touch ngay – cần thiết cho text selection/highlight.
    scrollView.delaysContentTouches = false

    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.spacing = 14
    stackView.isLayoutMarginsRelativeArrangement = true
    stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 28, trailing: 18)

    scrollView.addSubview(stackView)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])

    pdfTextScrollView = scrollView
    pdfTextStackView = stackView
    embedChildView(scrollView)

    let indicator = UIActivityIndicatorView(style: .large)
    indicator.startAnimating()
    _view.addSubview(indicator)
    indicator.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      indicator.centerXAnchor.constraint(equalTo: _view.centerXAnchor),
      indicator.centerYAnchor.constraint(equalTo: _view.centerYAnchor),
    ])

    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        guard let self = self else { return }
        let pages = try await self.extractPdfTextPages(publication: publication)
        await MainActor.run {
          indicator.removeFromSuperview()
          self.populatePdfTextPages(pages, initialPage: self.pdfTextCurrentPageIndex)
        }
      } catch {
        await MainActor.run {
          indicator.removeFromSuperview()
          print(TAG, "::initPdfTextReader - Loi parse text PDF: \(error)")
          emitReaderStatusChanged(status: ReadiumReaderStatusError)
          FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(
            FlutterReadiumError(message: "Loi parse text PDF: \(error.localizedDescription)", code: "pdf_text_parse_error", data: nil)
          )
        }
      }
    }
  }

  private func populatePdfTextPages(_ pages: [PdfTextPage], initialPage: Int) {
    guard let stackView = pdfTextStackView, let scrollView = pdfTextScrollView else { return }

    pdfTextPageViews.removeAll()
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    pdfTextPageCount = pages.first?.totalPages ?? 0

    if pages.isEmpty || pdfTextPageCount == 0 {
      emitReaderStatusChanged(status: ReadiumReaderStatusError)
      FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(
        FlutterReadiumError(message: "PDF khong co trang nao de parse text.", code: "pdf_no_pages", data: nil)
      )
      return
    }

    for page in pages {
      let pageView = makePdfTextPageView(page)
      pdfTextPageViews.append(pageView)
      stackView.addArrangedSubview(pageView)
    }

    let targetPage = min(max(initialPage, 0), max(pdfTextPageCount - 1, 0))
    pdfTextCurrentPageIndex = targetPage
    scrollView.layoutIfNeeded()
    scrollToPdfTextPage(targetPage, animated: false)
    emitPdfTextPageChanged(pageIndex: targetPage)
  }

  private func makePdfTextPageView(_ page: PdfTextPage) -> UIView {
    let container = UIStackView()
    container.axis = .vertical
    container.spacing = 8
    container.isLayoutMarginsRelativeArrangement = true
    container.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 12, trailing: 0)

    let header = UILabel()
    header.text = "Trang \(page.pageIndex + 1) / \(page.totalPages)"
    header.font = .preferredFont(forTextStyle: .footnote)
    header.textColor = .secondaryLabel

    let textView = UITextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isUserInteractionEnabled = true
    textView.isScrollEnabled = false
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.textColor = .label
    textView.text = page.text.isEmpty ? "" : page.text

    container.addArrangedSubview(header)
    container.addArrangedSubview(textView)
    return container
  }

  private enum PdfTextReaderError: LocalizedError {
    case noPdfLink
    case invalidURL(String)
    case cannotOpenPdf(String)

    var errorDescription: String? {
      switch self {
      case .noPdfLink:
        return "Khong tim thay link PDF trong publication readingOrder"
      case .invalidURL(let url):
        return "URL PDF khong hop le: \(url)"
      case .cannotOpenPdf(let path):
        return "Khong the mo file PDF: \(path)"
      }
    }
  }

  private func extractPdfTextPages(publication: Publication) async throws -> [PdfTextPage] {
    guard let pdfLink = publication.readingOrder.first else {
      throw PdfTextReaderError.noPdfLink
    }

    // Lấy URL trực tiếp (Foundation URL) – tránh roundtrip qua absoluteString
    // vì URL(string:) có thể fail khi tên file chứa ký tự đặc biệt / tiếng Việt.
    let linkURL = pdfLink.url()
    let pdfURL: URL

    if linkURL.isFileURL {
      pdfURL = linkURL
    } else if linkURL.scheme == "http" || linkURL.scheme == "https" {
      pdfURL = try await downloadPdfToTemp(url: linkURL)
    } else {
      throw PdfTextReaderError.invalidURL(linkURL.absoluteString)
    }

    // Thử load từ cache trước – tránh parse lại mỗi lần mở.
    if let cached = PdfTextCache.load(for: pdfURL) {
      return cached.map { PdfTextPage(pageIndex: $0.pageIndex, totalPages: $0.totalPages, text: $0.text) }
    }

    // Cache miss → extract từ PDFKit.
    let pages = try await Task.detached(priority: .userInitiated) {
      guard let document = PDFDocument(url: pdfURL) else {
        throw PdfTextReaderError.cannotOpenPdf(pdfURL.path)
      }

      let totalPages = document.pageCount
      return (0 ..< totalPages).map { pageIndex in
        let pageText = document.page(at: pageIndex)?.string ?? ""
        return PdfTextPage(
          pageIndex: pageIndex,
          totalPages: totalPages,
          text: pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
    }.value

    // Lưu cache để lần sau mở không cần parse lại.
    let toCache = pages.map { PdfTextCache.CachedPage(pageIndex: $0.pageIndex, totalPages: $0.totalPages, text: $0.text) }
    PdfTextCache.save(toCache, for: pdfURL)

    return pages
  }

  private func downloadPdfToTemp(url: URL) async throws -> URL {
    let (localURL, _) = try await URLSession.shared.download(from: url)
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".pdf")
    try FileManager.default.moveItem(at: localURL, to: tempURL)
    return tempURL
  }

  private func scrollToPdfTextPage(_ pageIndex: Int, animated: Bool) {
    guard let scrollView = pdfTextScrollView,
          let stackView = pdfTextStackView,
          pageIndex >= 0,
          pageIndex < pdfTextPageViews.count
    else { return }

    let pageView = pdfTextPageViews[pageIndex]
    let frame = pageView.convert(pageView.bounds, to: stackView)
    let minOffsetY = -scrollView.adjustedContentInset.top
    let maxOffsetY = max(
      minOffsetY,
      scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    )
    let offsetY = min(max(stackView.frame.minY + frame.minY - 8, minOffsetY), maxOffsetY)

    pdfTextIsProgrammaticScroll = animated
    scrollView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: animated)
    if !animated {
      pdfTextIsProgrammaticScroll = false
    }
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === pdfTextScrollView, !pdfTextIsProgrammaticScroll else { return }
    updatePdfTextCurrentPageFromScroll()
  }

  public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    guard scrollView === pdfTextScrollView else { return }
    pdfTextIsProgrammaticScroll = false
    updatePdfTextCurrentPageFromScroll()
  }

  private func updatePdfTextCurrentPageFromScroll() {
    guard let scrollView = pdfTextScrollView,
          let stackView = pdfTextStackView,
          !pdfTextPageViews.isEmpty else { return }

    let markerY = scrollView.contentOffset.y + (scrollView.bounds.height * 0.25)
    var visiblePage = pdfTextCurrentPageIndex

    for (index, pageView) in pdfTextPageViews.enumerated() {
      let frame = pageView.convert(pageView.bounds, to: stackView)
      if markerY >= stackView.frame.minY + frame.minY {
        visiblePage = index
      } else {
        break
      }
    }

    if visiblePage != pdfTextCurrentPageIndex {
      pdfTextCurrentPageIndex = visiblePage
      emitPdfTextPageChanged(pageIndex: visiblePage)
    }
  }

  private func emitPdfTextPageChanged(pageIndex: Int) {
    guard let locator = buildPdfTextLocator(pageIndex: pageIndex) else { return }

    cacheLocator(locator)

    if !hasSentReady {
      emitReaderStatusChanged(status: ReadiumReaderStatusReady)
      hasSentReady = true
    }

    channel.onPageChanged(locator: locator)
    FlutterReadiumPlugin.instance?.textLocatorStreamHandler?
      .sendEvent(locator.jsonString)
  }

  private func buildPdfTextLocator(pageIndex: Int) -> Locator? {
    guard let publication = pdfTextPublication,
          let link = publication.readingOrder.first else {
      return nil
    }

    let page = min(max(pageIndex, 0), max(pdfTextPageCount - 1, 0))
    let progression = pdfTextPageCount > 0 ? Double(page) / Double(pdfTextPageCount) : 0.0

    return Locator(
      href: link.url(),
      mediaType: link.mediaType ?? .pdf,
      locations: .init(
        fragments: pdfTextMetricFragments(pageIndex: page),
        progression: progression,
        totalProgression: progression,
        position: page + 1
      )
    )
  }

  private func pdfTextMetricFragments(pageIndex: Int) -> [String] {
    let page = min(max(pageIndex, 0), max(pdfTextPageCount - 1, 0))
    var fragments = [
      "page=\(page + 1)",
      "totalPages=\(pdfTextPageCount)",
    ]

    guard let scrollView = pdfTextScrollView,
          let stackView = pdfTextStackView,
          page >= 0,
          page < pdfTextPageViews.count else {
      return fragments
    }

    scrollView.layoutIfNeeded()
    stackView.layoutIfNeeded()

    let pageView = pdfTextPageViews[page]
    let pageFrame = pageView.convert(pageView.bounds, to: stackView)
    let pageTop = stackView.frame.minY + pageFrame.minY

    fragments.append("textHeight=\(Int(scrollView.contentSize.height.rounded()))")
    fragments.append("heightText=\(Int(scrollView.contentSize.height.rounded()))")
    fragments.append("viewportHeight=\(Int(scrollView.bounds.height.rounded()))")
    fragments.append("scrollY=\(Int(scrollView.contentOffset.y.rounded()))")
    fragments.append("pageTop=\(Int(pageTop.rounded()))")
    fragments.append("pageHeight=\(Int(pageFrame.height.rounded()))")

    return fragments
  }

  private func clearPdfTextReader() {
    pdfTextScrollView?.delegate = nil
    pdfTextScrollView?.removeFromSuperview()
    pdfTextScrollView = nil
    pdfTextStackView = nil
    pdfTextPageViews.removeAll()
    pdfTextPublication = nil
    pdfTextPageCount = 0
    pdfTextCurrentPageIndex = 0
    pdfTextIsProgrammaticScroll = false
  }

  // ── Helper: Nhúng view của navigator vào _view ──────────────────────────────

  private func embedChildView(_ child: UIView) {
    let view = _view
    view.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      child.topAnchor.constraint(equalTo: view.topAnchor),
      child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  // ── Helper: Kiểm tra PDF publication ───────────────────────────────────────

  /// Kiểm tra publication có phải PDF không qua readingOrder media type.
  private func isPdfPublication(_ publication: Publication) -> Bool {
    let firstItemType = publication.readingOrder.first?.mediaType?.string ?? ""
    return firstItemType.lowercased().contains("pdf")
  }

  private func cacheLocator(_ locator: Locator) {
    cachedLocator = locator
  }

  private func isMeaningfullyPastStart(_ locator: Locator?) -> Bool {
    guard let locator = locator else { return false }
    let locations = locator.locations

    if (locations.progression ?? 0.0) > 0.0001 {
      return true
    }
    if (locations.totalProgression ?? 0.0) > 0.0001 {
      return true
    }
    if (locations.position ?? 1) > 1 {
      return true
    }

    return !locations.fragments.isEmpty
  }

  private func isAtPublicationStart(_ locator: Locator) -> Bool {
    let locations = locator.locations
    return (locations.progression ?? 0.0) <= 0.0001
      && (locations.totalProgression ?? 0.0) <= 0.0001
      && (locations.position ?? 1) <= 1
      && locations.fragments.isEmpty
  }

  private func sameRestoreTarget(_ locator: Locator, _ restoreLocator: Locator) -> Bool {
    guard locator.href == restoreLocator.href else { return false }

    if let position = locator.locations.position,
       let restorePosition = restoreLocator.locations.position,
       position == restorePosition {
      return true
    }

    if let progression = locator.locations.progression,
       let restoreProgression = restoreLocator.locations.progression,
       abs(progression - restoreProgression) <= 0.001 {
      return true
    }

    if let totalProgression = locator.locations.totalProgression,
       let restoreTotalProgression = restoreLocator.locations.totalProgression,
       abs(totalProgression - restoreTotalProgression) <= 0.001 {
      return true
    }

    let locatorFragments = Set(locator.locations.fragments)
    let restoreFragments = Set(restoreLocator.locations.fragments)
    return !locatorFragments.isEmpty && !locatorFragments.isDisjoint(with: restoreFragments)
  }

  private func shouldIgnoreStartupLocator(_ locator: Locator) -> Bool {
    guard !hasAcceptedEpubLocator,
          let restoreLocator = initialLocatorForRestore else {
      return false
    }

    // Chỉ áp dụng bộ lọc khi restore target nằm xa đầu publication,
    // hoặc khi chapter hiện tại khác chapter cần restore.
    let restoreLooksPastStart = isMeaningfullyPastStart(restoreLocator) || locator.href != restoreLocator.href
    guard restoreLooksPastStart else { return false }

    // Nếu locator trùng với restore target → không phải noise.
    guard !sameRestoreTarget(locator, restoreLocator) else { return false }

    // Trường hợp 1: Locator ở đầu toàn bộ publication (chapter 1, totalProgression≈0).
    // Navigator render chapter đầu trước khi nhảy đến đúng chapter.
    if isAtPublicationStart(locator) { return true }

    // Trường hợp 2 (phổ biến trên iOS): Locator ở đúng chapter cần restore nhưng
    // progression≈0.0 — EPUBNavigatorViewController đã load đúng chapter nhưng CHƯA
    // scroll đến vị trí saved (scrollToLocations() chưa hoàn tất).
    // Readium sẽ bắn locationDidChange lần thứ 2 sau khi scroll xong (~300-500ms).
    // Nếu không lọc, event sai này sẽ được cache và emit lên Flutter stream.
    if locator.href == restoreLocator.href,
       (locator.locations.progression ?? 0.0) <= 0.0001 {
      return true
    }

    return false
  }

  @objc public func onCustomEditingAction() {
    print(TAG, "EditingAction::NOTA")
    // NOTE: This method will not actually be hit. It will try to find an "onCustomEditingAction" function in the Responder chain!
    // Because of how Flutter generates its responder chain, we need to implement this func in the client AppDelegate.swift and then call the plugin again.
    // see https://github.com/readium/swift-toolkit/issues/466

    if let epub = epubNavigatorViewController, let selection = epub.currentSelection {
      let selectionLocator = selection.locator
      epub.apply(decorations: [Decoration(id: "highlight", locator: selectionLocator, style: .highlight(), userInfo: [:])], in: "user-highlight")
      epub.clearSelection()
    }
  }

  // override EPUBNavigatorDelegate::navigator:setupUserScripts
  public func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
    print(TAG, "setupUserScripts: adding \(userScripts.count) scripts")
    for script in userScripts {
      userContentController.addUserScript(script)
    }
  }

  // override EPUBNavigatorDelegate::middleTapHandler
  func middleTapHandler() {
  }

  public func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
    // All margin & safe-area is handled on the Flutter side.
    return .init(top: 0, left: 0, bottom: 0, right: 0)
  }

  // override EPUBNavigatorDelegate::navigator:presentError
  public func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
    print(TAG, "presentError: \(error)")
  }

  // override EPUBNavigatorDelegate::navigator:didFailToLoadResourceAt
  public func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: ReadiumShared.RelativeURL, withError error: ReadiumShared.ReadError) {
    print(TAG, "didFailToLoadResourceAt: \(href). err: \(error)")

    // TODO: Should we send resource-load error like this?
    emitReaderStatusChanged(status: ReadiumReaderStatusError)

    let error = FlutterReadiumError(message: error.localizedDescription, code: "DidFailToLoadResource", data: href.string)
    FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(error)
  }

  // override NavigatorDelegate::navigator:locationDidChange
  public func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    print(TAG, "onPageChanged: \(locator)")
    if shouldIgnoreStartupLocator(locator) {
      print(TAG, "Ignoring startup locator noise while restoring previous EPUB location: \(locator)")
      if (!hasSentReady) {
        emitReaderStatusChanged(status: ReadiumReaderStatusReady)
        hasSentReady = true
      }
      return
    }

    hasAcceptedEpubLocator = true
    cacheLocator(locator)

    if (!hasSentReady) {
      emitReaderStatusChanged(status: ReadiumReaderStatusReady)
      hasSentReady = true
    }
    emitOnPageChanged(locator: locator)
  }

  public func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      print(TAG, "skipped non-http external URL: \(url)")
      return
    }
    emitOnExternalLinkActivated(url: url)
  }

  func applyDecorations(_ decorations: [Decoration], forGroup groupIdentifier: String) {
    print(TAG, "onMethodApplyDecorations: \(decorations) identifier: \(groupIdentifier)")
    // Decorations chỉ áp dụng cho EPUB navigator; PDF dùng native UITextView selection.
    epubNavigatorViewController?.apply(decorations: decorations, in: groupIdentifier)
  }

  func getFirstVisibleLocator() async -> Locator? {
    if let epub = epubNavigatorViewController {
      return await epub.firstVisibleElementLocator()
    }
    return buildPdfTextLocator(pageIndex: pdfTextCurrentPageIndex)
  }

  func getCurrentLocation() -> Locator? {
    return cachedLocator
      ?? epubNavigatorViewController?.currentLocation
      ?? buildPdfTextLocator(pageIndex: pdfTextCurrentPageIndex)
  }

  func getCurrentSelection() -> Locator? {
    return epubNavigatorViewController?.currentSelection?.locator
  }

  private func evaluateJavascript(_ code: String) async -> Result<Any, Error> {
    guard let epub = epubNavigatorViewController else {
      // PDF không hỗ trợ JavaScript
      return .failure(NSError(domain: "ReadiumReaderView", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "JavaScript khong kha dung cho PDF text reader"]))
    }
    return await epub.evaluateJavaScript(code)
  }

  private func evaluateJSReturnResult(_ code: String, result: @escaping FlutterResult) {
    Task.detached(priority: .high) {
      do {
        let data = try await self.evaluateJavascript(code).get()
        print(TAG, "evaluateJSReturnResult result: \(data)")
        await MainActor.run() {
          return result(data)
        }
      } catch (let err) {
        print(TAG, "evaluateJSReturnResult error: \(err)")
        await MainActor.run() {
          return result(nil)
        }
      }
    }
  }

  private func setUserPreferences(preferences: EPUBPreferences) {
    isVerticalScroll = preferences.scroll ?? false
    epubNavigatorViewController?.submitPreferences(preferences)
  }

  private func emitOnPageChanged(locator: Locator) -> Void {
    let json = locator.jsonString ?? "null"

    print(TAG, "emitOnPageChanged:locator=\(String(describing: locator))")

    Task.detached(priority: .high) { [isVerticalScroll] in
      let locatorToEmit = await self.getLocatorFragments(json, isVerticalScroll) ?? locator
      await MainActor.run() {
        self.cacheLocator(locatorToEmit)
        self.channel.onPageChanged(locator: locatorToEmit)
        FlutterReadiumPlugin.instance?.textLocatorStreamHandler?
          .sendEvent(locatorToEmit.jsonString)
      }
    }
  }

  private func emitOnExternalLinkActivated(url: URL) {
    print(TAG, "emitOnExternalLinkActivated: \(url)")
    Task.detached(priority: .high) {
      await MainActor.run() {
        self.channel.onExternalLinkActivated(url: url)
      }
    }
  }

  internal func getLocatorFragments(_ locatorJson: String, _ isVerticalScroll: Bool) async -> Locator? {
    switch await self.evaluateJavascript("window.epubPage.getLocatorFragments(\(locatorJson), \(isVerticalScroll));") {
      case .success(let jresult):
        do {
          guard let json = jresult as? Dictionary<String, Any?> else {
            print(TAG, "getLocatorFragments failed: invalid JS result \(jresult)")
            return nil
          }
          return try Locator(json: json, warnings: readiumBugLogger)
        } catch (let err) {
          print(TAG, "getLocatorFragments failed to parse locator: \(err)")
          return nil
        }
      case .failure(let err):
        print(TAG, "getLocatorFragments failed! \(err)")
        return nil
      }
  }

  private func scrollTo(locations: Locator.Locations, toStart: Bool) async -> Void {
    let json = locations.jsonString ?? "null"
    print(TAG, "scrollTo: Go to locations \(json), toStart: \(toStart)")

    let _ = await evaluateJavascript("window.epubPage.scrollToLocations(\(json),\(isVerticalScroll),\(toStart));")
  }

  @MainActor
  private func goToPdfTextLocator(locator: Locator, animated: Bool) -> Bool {
    guard pdfTextScrollView != nil, pdfTextPageCount > 0 else { return false }

    let pageIndex = min(max((locator.locations.position ?? 1) - 1, 0), pdfTextPageCount - 1)
    pdfTextCurrentPageIndex = pageIndex
    scrollToPdfTextPage(pageIndex, animated: animated)
    emitPdfTextPageChanged(pageIndex: pageIndex)
    return true
  }

  @MainActor
  private func goToPdfTextPageOffset(_ offset: Int, animated: Bool) -> Bool {
    guard pdfTextScrollView != nil, pdfTextPageCount > 0 else { return false }

    let pageIndex = min(max(pdfTextCurrentPageIndex + offset, 0), pdfTextPageCount - 1)
    pdfTextCurrentPageIndex = pageIndex
    scrollToPdfTextPage(pageIndex, animated: animated)
    emitPdfTextPageChanged(pageIndex: pageIndex)
    return true
  }

  func goToLocator(locator: Locator, animated: Bool) async -> Void {
    print(TAG, "goToLocator: Navigating to \(locator.href)")

    if let epub = epubNavigatorViewController {
      // EPUB: Sử dụng Readium native go() để navigation chính xác
      let success = await epub.go(to: locator, options: NavigatorGoOptions(animated: animated))
      if !success {
        print(TAG, "goToLocator: EPUB navigation failed for \(locator.href)")
      }
    } else if pdfTextScrollView != nil {
      let success = await goToPdfTextLocator(locator: locator, animated: animated)
      if !success {
        print(TAG, "goToLocator: PDF text navigation failed for \(locator.href)")
      }
    }
  }

  func justGoToLocator(_ locator: Locator, animated: Bool) async -> Bool {
    if let epub = epubNavigatorViewController {
      return await epub.go(to: locator, options: NavigatorGoOptions(animated: animated))
    } else if pdfTextScrollView != nil {
      return await goToPdfTextLocator(locator: locator, animated: animated)
    }
    return false
  }

  private func setLocation(locator: Locator, isAudioBookWithText: Bool) async -> Result<Any, Error> {
    if pdfTextScrollView != nil {
      let success = await goToPdfTextLocator(locator: locator, animated: false)
      return .success(success)
    }

    let json = locator.jsonString ?? "null"

    return await evaluateJavascript("window.epubPage.setLocation(\(json), \(isAudioBookWithText));")
  }

  private func emitOnPageChanged() {
    if let epub = epubNavigatorViewController, let locator = epub.currentLocation {
      print(TAG, "emitOnPageChanged: Calling navigator:locationDidChange.")
      navigator(epub, locationDidChange: locator)
      return
    }

    if pdfTextScrollView != nil {
      emitPdfTextPageChanged(pageIndex: pdfTextCurrentPageIndex)
      return
    }

    guard let locator = getCurrentLocation() else {
      print(TAG, "emitOnPageChanged: currentLocation = nil!")
      return
    }
    print(TAG, "emitOnPageChanged: locator=\(locator)")
  }

  func onMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "go":
      let args = call.arguments as! [Any?]
      print(TAG, "onMethodCall[go] locator = \(args[0] as! String)")
      let locator = try! Locator(jsonString: args[0] as! String, warnings: readiumBugLogger)!
      let animated = args[1] as! Bool
      let isAudioBookWithText = args[2] as? Bool ?? false

      Task.detached(priority: .high) {
        await self.goToLocator(locator: locator, animated: animated)
        let _ = await self.setLocation(locator: locator, isAudioBookWithText: isAudioBookWithText)
        await MainActor.run() {
          result(true)
        }
      }
      break
    case "goLeft":
      let animated = call.arguments as! Bool
      Task.detached(priority: .high) {
        var success = false
        if let epub = self.epubNavigatorViewController {
          success = await epub.goLeft(options: NavigatorGoOptions(animated: animated))
        } else if self.pdfTextScrollView != nil {
          success = await self.goToPdfTextPageOffset(-1, animated: animated)
        }
        await MainActor.run() { result(success) }
      }
      break
    case "goRight":
      let animated = call.arguments as! Bool
      Task.detached(priority: .high) {
        var success = false
        if let epub = self.epubNavigatorViewController {
          success = await epub.goRight(options: NavigatorGoOptions(animated: animated))
        } else if self.pdfTextScrollView != nil {
          success = await self.goToPdfTextPageOffset(1, animated: animated)
        }
        await MainActor.run() { result(success) }
      }
      break
    case "setLocation":
      let args = call.arguments as! [Any]
      print(TAG, "onMethodCall[setLocation] locator = \(args[0] as! String)")
      let locator = try! Locator(jsonString: args[0] as! String, warnings: readiumBugLogger)!
      let isAudioBookWithText = args[1] as? Bool ?? false
      Task.detached(priority: .high) {
        let _ = await self.setLocation(locator: locator, isAudioBookWithText: isAudioBookWithText)
        return await MainActor.run() {
          result(true)
        }
      }
      break
    case "getLocatorFragments":
      let args = call.arguments as? String ?? "null"
      if pdfTextScrollView != nil {
        let locator = try? Locator(jsonString: args, warnings: readiumBugLogger)
        let pageIndex = min(max((locator?.locations.position ?? pdfTextCurrentPageIndex + 1) - 1, 0), max(pdfTextPageCount - 1, 0))
        result(buildPdfTextLocator(pageIndex: pageIndex)?.jsonString ?? args)
        break
      }
      Task.detached(priority: .high) {
        do {
          let data = try await self.evaluateJavascript("window.epubPage.getLocatorFragments(\(args), true);").get()
          await MainActor.run() {
            return result(data)
          }
        } catch (let err) {
          print(TAG, "getLocatorFragments error \(err)")
          await MainActor.run() {
            return result(false)
          }
        }
      }
      break
    case "getCurrentLocator":
      let args = call.arguments as? String ?? "null"
      print(TAG, "onMethodCall[currentLocator] args = \(args)")
      if pdfTextScrollView != nil {
        result(buildPdfTextLocator(pageIndex: pdfTextCurrentPageIndex)?.jsonString)
        return
      }
      result((cachedLocator ?? epubNavigatorViewController?.currentLocation)?.jsonString)
      break
    case "isLocatorVisible":
      let args = call.arguments as! String
      print(TAG, "onMethodCall[isLocatorVisible] locator = \(args)")
      if pdfTextScrollView != nil {
        let locator = try! Locator(jsonString: args, warnings: readiumBugLogger)!
        let visible = locator.locations.position == pdfTextCurrentPageIndex + 1
        result(visible)
        return
      }
      // EPUB: kiểm tra qua JS
      let locator = try! Locator(jsonString: args, warnings: readiumBugLogger)!
      if locator.href != self.epubNavigatorViewController?.currentLocation?.href {
        result(false)
        return
      }
      evaluateJSReturnResult("window.epubPage.isLocatorVisible(\(args));", result: result)
      break
    case "setPreferences":
      let args = call.arguments as! [String: String]
      print(TAG, "onMethodCall[setPreferences] args = \(args)")
      let preferences = EPUBPreferences.init(fromMap: args)
      setUserPreferences(preferences: preferences)
      break
    case "applyDecorations":
      let args = call.arguments as! [Any?]
      let identifier = args[0] as! String
      let decorationsStr = args[1] as! [String]

      guard let decorations = try? decorationsStr.map({ try Decoration(fromJson: $0) }) else {
        return result(FlutterError.init(
          code: "JSON mapping error",
          message: "Could not map decorations from JSON: \(decorationsStr)",
          details: nil))
      }

      print(TAG, "onMethodCall[setPreferences] args = \(args)")
      applyDecorations(decorations, forGroup: identifier)
      break
    case "dispose":
      print(TAG, "Disposing navigator view controllers")
      epubNavigatorViewController?.view.removeFromSuperview()
      epubNavigatorViewController?.delegate = nil
      epubNavigatorViewController = nil
      clearPdfTextReader()
      emitReaderStatusChanged(status: ReadiumReaderStatusClosed)
      result(nil)
      break
    default:
      print(TAG, "Unhandled call \(call.method)")
      result(FlutterMethodNotImplemented)
      break
    }
  }
}

func initUserScripts(registrar: FlutterPluginRegistrar) {
  let comicJsKey = registrar.lookupKey(forAsset: "assets/helpers/comics.js", fromPackage: "flutter_readium")
  let comicCssKey = registrar.lookupKey(forAsset: "assets/helpers/comics.css", fromPackage: "flutter_readium")
  let epubJsKey = registrar.lookupKey(forAsset: "assets/helpers/epub.js", fromPackage: "flutter_readium")
  let epubCssKey = registrar.lookupKey(forAsset: "assets/helpers/epub.css", fromPackage: "flutter_readium")
  let jsScripts = [comicJsKey, epubJsKey].map { sourceFile -> String in
    let path = Bundle.main.path(forResource: sourceFile, ofType: nil)!
    let data = FileManager().contents(atPath: path)!
    return String(data: data, encoding: .utf8)!
  }
  let addCssScripts = [comicCssKey, epubCssKey].map { sourceFile -> String in
    let path = Bundle.main.path(forResource: sourceFile, ofType: nil)!
    let data = FileManager().contents(atPath: path)!.base64EncodedString()
    return """
      (function() {
      var parent = document.getElementsByTagName('head').item(0);
      var style = document.createElement('style');
      style.type = 'text/css';
      style.innerHTML = window.atob('\(data)');
      parent.appendChild(style)})();
    """
  }
  /// Add JS scripts right away, before loading the rest of the document.
  for jsScript in jsScripts {
    userScripts.append(WKUserScript(source: jsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }
  /// Add css injection scripts after primary document finished loading.
  for addCssScript in addCssScripts {
    userScripts.append(WKUserScript(source: addCssScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
  }
  /// Add simple script used by our JS to detect OS
  userScripts.append(WKUserScript(source: "const isAndroid=false,isIos=true;", injectionTime: .atDocumentStart, forMainFrameOnly: false))
}

private func canScroll(locations: Locator.Locations?) -> Bool {
  guard let locations = locations else { return false }
  return locations.domRange != nil || locations.cssSelector != nil || locations.progression != nil
}

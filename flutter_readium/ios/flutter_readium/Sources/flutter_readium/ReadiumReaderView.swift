import ReadiumNavigator
import ReadiumAdapterGCDWebServer
import ReadiumShared
import Flutter
import UIKit
import WebKit
import PDFKit

private let ReadiumReaderStatusReady = "ready"
private let ReadiumReaderStatusLoading = "loading"
private let ReadiumReaderStatusClosed = "closed"
private let ReadiumReaderStatusError = "error"

let readiumReaderViewType = "dk.nota.flutter_readium/ReadiumReaderWidget"
private let allowedInitialFragments = ["id", "t", "viewrect", "xywh"]

class ReadiumBugLogger: ReadiumShared.WarningLogger {
  func log(_ warning: Warning) {
    Log.reader.error("Error in Readium while deserializing: \(warning)")
  }
}

private let readiumBugLogger = ReadiumBugLogger()
private var userScripts: [WKUserScript] = []
private let jsonEncoder = JSONEncoder()

private func emitReaderStatusChanged(status: String) {
  if let jsonData = try? jsonEncoder.encode(status),
     let jsonString = String(data: jsonData, encoding: .utf8) {
    FlutterReadiumPlugin.instance?.readerStatusStreamHandler?.sendEvent(jsonString)
  }
}

public class ReadiumReaderView: NSObject, FlutterPlatformView, EPUBNavigatorDelegate, VisualNavigatorDelegate, UIScrollViewDelegate {

  private let channel: ReadiumReaderChannel
  private let _view: UIView

  /// EPUB navigator, initialized for EPUB/WebPub publications.
  private var epubNavigatorViewController: EPUBNavigatorViewController?

  /// PDF text reader, initialized for PDF publications.
  private var pdfTextScrollView: UIScrollView?
  private var pdfTextStackView: UIStackView?
  private var pdfTextPageViews: [UIView] = []
  private var pdfTextPublication: Publication?
  private var pdfTextPageCount = 0
  private var pdfTextCurrentPageIndex = 0
  private var pdfTextIsProgrammaticScroll = false

  private var isVerticalScroll = false
  private var hasSentReady = false
  private var isJumpingToLocator = false
  private var lastHrefLocation: String?
  private var preferences: FlutterEPUBPreferences?
  private let publication: Publication

  var publicationIdentifier: String?

  public func view() -> UIView {
    Log.reader.debug("getView")
    return _view
  }

  deinit {
    Log.reader.info("dispose")
    epubNavigatorViewController?.view.removeFromSuperview()
    epubNavigatorViewController?.delegate = nil
    channel.setMethodCallHandler(nil)
    FlutterReadiumPlugin.instance?.setCurrentReadiumReaderView(nil)
  }

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    registrar: FlutterPluginRegistrar
  ) {
    Log.reader.info("init")
    let creationParams = args as! Dictionary<String, Any?>

    let publication = FlutterReadiumPlugin.instance!.getCurrentPublication()!
    self.publication = publication
    self.publicationIdentifier = publication.metadata.identifier

    let preferencesMap = creationParams["preferences"] as? Dictionary<String, Any>?
    self.preferences = preferencesMap == nil ? FlutterEPUBPreferences.init() : FlutterEPUBPreferences.init(fromMap: preferencesMap!!)

    let locatorStr = creationParams["initialLocator"] as? String
    var locator = locatorStr == nil ? nil : try! Locator.init(jsonString: locatorStr!)
    Log.reader.debug("publication = \(publication)")

    // TODO: Our custom fragments (particularly page=x) messes up the in-chapter location.
    // only allow whitelist from https://readium.org/architecture/models/locators/best-practices/format.html
    locator?.locations.fragments.removeAll(where: { !allowedInitialFragments.contains(String($0.split(separator: "=").first ?? "none")) })

    channel = ReadiumReaderChannel(
      name: "\(readiumReaderViewType):\(viewId)", binaryMessenger: registrar.messenger())

    emitReaderStatusChanged(status: ReadiumReaderStatusLoading)

    Log.reader.info("Publication: (identifier=\(String(describing: publication.metadata.identifier)),title=\(String(describing: publication.metadata.title)))")
    Log.reader.info("Added publication at \(String(describing: publication.baseURL))")

    _view = UIView()
    super.init()

    channel.setMethodCallHandler(onMethodCall)

    // ── Phân nhánh theo loại publication ──────────────────────────────────────
    // Dùng isPdfPublication() để kiểm tra qua mediaType (không phụ thuộc vào Publication.Profile.pdf)
    if isPdfPublication(publication) {
      Log.reader.debug("init - PDF publication, using text reader")
      initPdfTextReader(publication: publication, locator: locator)
    } else {
      Log.reader.debug("init - EPUB/WebPub publication, using EPUBNavigatorViewController")
      initEpubNavigator(
        publication: publication,
        locator: locator,
        registrar: registrar
      )
    }

    FlutterReadiumPlugin.instance?.setCurrentReadiumReaderView(self)
    Log.reader.debug("init success")
  }

  // ── Khởi tạo EPUB Navigator ─────────────────────────────────────────────────

  private func initEpubNavigator(
    publication: Publication,
    locator: Locator?,
    registrar: FlutterPluginRegistrar
  ) {
    // Remove undocumented Readium default 20dp or 44dp top/bottom padding.
    var config = EPUBNavigatorViewController.Configuration()

    // TODO: Use config.readiumCSSRSProperties.overrides to add custom CSS variables
    //config.readiumCSSRSProperties.overrides = [:]

    config.contentInset = [
      .compact: (top: 0, bottom: 0),
      .regular: (top: 0, bottom: 0),
    ]
    config.preloadPreviousPositionCount = 2
    config.preloadNextPositionCount = 4
    config.debugState = false

    // TODO: Use experimentalPositioning for now. It places highlights on z-index -1 behind text, instead of on top.
    config.decorationTemplates = HTMLDecorationTemplate.defaultTemplates(alpha: 1.0, experimentalPositioning: true)

    // TODO: This is a PoC for adding custom editing actions, like user highlights. It should be configurable from Flutter.
    //       See onCustomEditingAction for notes about "catching" this callback on the responder chain.
    //config.editingActions = [.lookup, .translate, EditingAction(title: "Custom Highlight Action", action: #selector(onCustomEditingAction))]

    if let readiumPreferences = self.preferences?.readium {
      config.preferences = readiumPreferences
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
          Log.reader.error("initPdfTextReader failed: \(error)")
          emitReaderStatusChanged(status: ReadiumReaderStatusError)
          let payload = FlutterReadiumError(message: "Loi parse text PDF: \(error.localizedDescription)", code: "pdf_text_parse_error", data: nil)
          FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(
            payload.toJsonString()
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
      let payload = FlutterReadiumError(message: "PDF khong co trang nao de parse text.", code: "pdf_no_pages", data: nil)
      FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(
        payload.toJsonString()
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
    let linkURLString = pdfLink.url().string
    let pdfURL: URL

    if let linkURL = URL(string: linkURLString), linkURL.isFileURL {
      pdfURL = linkURL
    } else if let linkURL = URL(string: linkURLString),
              ["http", "https"].contains(linkURL.scheme?.lowercased() ?? "") {
      pdfURL = try await downloadPdfToTemp(url: linkURL)
    } else if linkURLString.hasPrefix("/") {
      pdfURL = URL(fileURLWithPath: linkURLString)
    } else {
      throw PdfTextReaderError.invalidURL(linkURLString)
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

  @objc public func onCustomEditingAction() {
    Log.reader.debug("EditingAction::NOTA")
    // NOTE: This method will not actually be hit. It will try to find an "onCustomEditingAction" function in the Responder chain!
    // Because of how Flutter generates its responder chain, we need to implement this func in the client AppDelegate.swift and then call back into the plugin from there.
    // see https://github.com/readium/swift-toolkit/issues/466

    if let epub = epubNavigatorViewController, let selection = epub.currentSelection {
      let selectionLocator = selection.locator
      epub.apply(decorations: [Decoration(id: "highlight", locator: selectionLocator, style: .highlight(), userInfo: [:])], in: "user-highlight")
      epub.clearSelection()
    }
  }

  // implements EPUBNavigatorDelegate::navigator:setupUserScripts
  public func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
    Log.reader.debug("setupUserScripts: adding \(userScripts.count) scripts")
    for script in userScripts {
      userContentController.addUserScript(script)
    }

    /// Custom preferences added dynamically for each WebView, to make sure changes to preferences are respected.
    if let preferencesStylesheet = self.preferences?.toInjectableStyleSheet() {
      let source = """
        (function() {
        var parent = document.getElementsByTagName('head').item(0);
        var style = document.createElement('style');
        style.type = 'text/css';
        style.innerHTML = '\(preferencesStylesheet)';
        parent.appendChild(style)})();
      """
      userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }
  }

  func middleTapHandler() {
    Log.reader.debug("EPUBNavigatorDelegate.middleTapHandler")
  }

  public func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
    // All margin & safe-area is handled on the Flutter side.
    return .init(top: 0, left: 0, bottom: 0, right: 0)
  }

  // implements EPUBNavigatorDelegate::navigator:presentError
  public func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
    Log.reader.error("Should present error: \(error)")
  }

  // implements EPUBNavigatorDelegate::navigator:didFailToLoadResourceAt
  public func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: ReadiumShared.RelativeURL, withError error: ReadiumShared.ReadError) {
    Log.reader.warn("didFailToLoadResourceAt: \(href). err: \(error)")

    // TODO: Should we send resource-load error like this?
    emitReaderStatusChanged(status: ReadiumReaderStatusError)

    let payload = FlutterReadiumError(message: error.localizedDescription, code: "DidFailToLoadResource", data: href.string)
    FlutterReadiumPlugin.instance?.errorStreamHandler?.sendEvent(payload.toJsonString())
  }
  
  public func navigator(_ navigator: any Navigator, didJumpTo locator: Locator) {
    Log.reader.debug("didJumpTo: \(locator)")
    isJumpingToLocator = false
  }

  // implements NavigatorDelegate::navigator:locationDidChange
  public func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    Log.reader.debug("onPageChanged: \(locator)")
    if (!hasSentReady) {
      emitReaderStatusChanged(status: ReadiumReaderStatusReady)
      hasSentReady = true
    }
    if (lastHrefLocation != locator.href.string) {
      lastHrefLocation = locator.href.string
      /// Ensure that custom preference CSS variables are set, when changing resources.
      if let preferences = self.preferences {
        updateCustomPreferences(preferences)
      }
    }
    emitOnPageChanged(locator: locator)
  }

  public func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      Log.reader.warn("skipped non-http external URL: \(url)")
      return
    }
    emitOnExternalLinkActivated(url: url)
  }

  /// Called when the user taps on a link referring to a note.
  ///
  /// Return `true` to navigate to the note, or `false` if you intend to present the
  /// note yourself, using its `content`. `link.type` contains information about the
  /// format of `content` and `referrer`, such as `text/html`.
  public func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: Link, content: String, referrer: String?) -> Bool {
    Log.reader.info("user tapped on note: \(content)")
    return true
  }

  func applyDecorations(_ decorations: [Decoration], forGroup groupIdentifier: String) {
    Log.reader.debug("applyDecorations: \(decorations) identifier: \(groupIdentifier)")
    epubNavigatorViewController?.apply(decorations: decorations, in: groupIdentifier)
  }

  func getFirstVisibleLocator() async -> Locator? {
    if let epub = epubNavigatorViewController {
      return await epub.firstVisibleElementLocator()
    }
    return buildPdfTextLocator(pageIndex: pdfTextCurrentPageIndex)
  }

  func getCurrentLocation() -> Locator? {
    return epubNavigatorViewController?.currentLocation
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
        Log.reader.debug("evaluateJavascript result: \(data)")
        await MainActor.run() {
          return result(data)
        }
      } catch (let err) {
        Log.reader.error("evaluateJavascript error: \(err)")
        await MainActor.run() {
          return result(nil)
        }
      }
    }
  }

  private func setUserPreferences(preferences: FlutterEPUBPreferences) {
    isVerticalScroll = preferences.readium.scroll ?? false
    epubNavigatorViewController?.submitPreferences(preferences.readium)
    self.updateCustomPreferences(preferences)
  }

  private func updateCustomPreferences(_ preferences: FlutterEPUBPreferences) {
    let cssVariables = preferences.toCustomCssVariables()
    if cssVariables.isEmpty == false,
       let jsonData = try? jsonEncoder.encode(cssVariables),
       let jsonString = String(data: jsonData, encoding: .utf8) {
      Task.detached(priority: .high) { [jsonString] in
        let result = await self.epubNavigatorViewController?.evaluateJavaScript("readium.setCSSProperties(\(jsonString));")
        Log.reader.info("updated custom preferences: \(result)")
      }
    }
  }

  private func emitOnPageChanged(locator: Locator) -> Void {
    Log.reader.debug("emitOnPageChanged, locator: \(locator)")

    Task.detached(priority: .high) { [locator] in
      /// Enrich Locator with PageInformation and ToC.
      var resultLocator = locator
      if let pageInfo = await self.getPageInformation() {
        resultLocator.locations.otherLocations.merge(pageInfo.otherLocations, uniquingKeysWith: { lhs, rhs in lhs })
      }
      if let tocLink = try? await FlutterReadiumPlugin.instance?.currentTocLinkFromLocator(resultLocator) {
        resultLocator.title = tocLink.title
        resultLocator.locations.otherLocations["tocHref"] = tocLink.href
      }

      /// Immutable ref, so that we can use it on the main thread
      let finalLocator = resultLocator
      await MainActor.run() {
        self.channel.onPageChanged(locator: finalLocator)
        FlutterReadiumPlugin.instance?.textLocatorStreamHandler?.sendEvent(finalLocator.jsonString)
      }
    }
  }

  private func emitOnExternalLinkActivated(url: URL) {
    Log.reader.info("emitOnExternalLinkActivated: \(url)")
    Task.detached(priority: .high) {
      await MainActor.run() {
        self.channel.onExternalLinkActivated(url: url)
      }
    }
  }

  internal func getPageInformation() async -> PageInformation? {
    switch await self.evaluateJavascript("window.flutterReadium.getPageInformation();") {
    case .success(let jresult):
      let pageInfo = PageInformation.fromJson(jresult as? Dictionary<String, Any> ?? Dictionary())
      return pageInfo
    case .failure(let err):
      Log.reader.error("getPageInformation failed! \(err)")
      return nil
    }
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

  func goToLocator(_ locator: Locator, animated: Bool) async -> Bool {
    Log.reader.debug("goToLocator: \(locator)")
    if let epub = epubNavigatorViewController {
      isJumpingToLocator = true
      return await epub.go(to: locator, options: NavigatorGoOptions(animated: animated))
    }
    if pdfTextScrollView != nil {
      return await goToPdfTextLocator(locator: locator, animated: animated)
    }
    return false
  }

  func goToProgression(_ progression: Double, animated: Bool) async -> Bool {
    Log.reader.debug("goToProgression:\(progression)")
    if let epub = epubNavigatorViewController {
      guard let locator = epub.currentLocation ?? getCurrentLocation() else {
        return false
      }
      let newLocator = locator.copyWithProgressionLocations(progression: progression)
      return await epub.go(to: newLocator, options: NavigatorGoOptions(animated: animated))
    }
    if pdfTextScrollView != nil {
      let targetPage = Int((Double(max(pdfTextPageCount - 1, 0)) * progression).rounded())
      return await goToPdfTextPageOffset(targetPage - pdfTextCurrentPageIndex, animated: animated)
    }
    return false
  }


  func syncToLocator(_ locator: Locator, animated: Bool, segmentDuration: TimeInterval? = nil) async -> Bool {
    if (isJumpingToLocator || preferences?.disableSync == true) {
      Log.reader.debug("syncToLocator: skipped")
      return false
    }
    Log.reader.debug("syncToLocator: \(locator)")
    if let duration = segmentDuration {
      let segmentDurationMs = duration * 1000.0
      await epubNavigatorViewController?.evaluateJavaScript("window.flutterReadium.setSegmentDuration(\(segmentDurationMs));");
    }
    return await goToLocator(locator, animated: animated)
  }

  private func emitOnPageChanged() {
    if let epub = epubNavigatorViewController, let locator = epub.currentLocation {
      Log.reader.debug("emitOnPageChanged: Calling navigator:locationDidChange.")
      navigator(epub, locationDidChange: locator)
      return
    }

    if pdfTextScrollView != nil {
      emitPdfTextPageChanged(pageIndex: pdfTextCurrentPageIndex)
      return
    }

    guard let locator = getCurrentLocation() else {
      Log.reader.warn("emitOnPageChanged: currentLocation was nil!")
      return
    }
    Log.reader.debug("emitOnPageChanged: locator=\(locator)")
  }

  func onMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    Log.reader.debug("onMethodCall: \(call.method)")
    switch call.method {
    case "go":
      let args = call.arguments as! [Any?]
      let locator = try! Locator(jsonString: args[0] as! String, warnings: readiumBugLogger)!
      let animated = args[1] as! Bool

      Task.detached(priority: .high) {
        let success = await self.goToLocator(locator, animated: animated)
        await MainActor.run() {
          result(success)
        }
      }
      break
    case "goBackward":
      let animated = call.arguments as! Bool
      let navOptions = NavigatorGoOptions(animated: animated)
      let epub = self.epubNavigatorViewController
      let scrollMode = epub?.presentation.scroll
      let hasPdfTextReader = self.pdfTextScrollView != nil

      Task.detached(priority: .high) {
        var success = false
        if let epub = epub {
          let layoutMode = await epub.publication.metadata.layout ?? Layout.reflowable
          if (layoutMode == .reflowable && scrollMode == true) {
            success = await self.goBackwardInScrollMode(options: navOptions)
          } else {
            success = await epub.goBackward(options: navOptions)
          }
        } else if hasPdfTextReader {
          success = await self.goToPdfTextPageOffset(-1, animated: animated)
        }
        await MainActor.run() { result(success) }
      }
      break
    case "goForward":
      let animated = call.arguments as! Bool
      let navOptions = NavigatorGoOptions(animated: animated)
      let epub = self.epubNavigatorViewController
      let scrollMode = epub?.presentation.scroll
      let hasPdfTextReader = self.pdfTextScrollView != nil

      Task.detached(priority: .high) {
        var success = false
        if let epub = epub {
          let layoutMode = await epub.publication.metadata.layout ?? Layout.reflowable
          if (layoutMode == .reflowable && scrollMode == true) {
            success = await self.goForwardInScrollMode(options: navOptions)
          } else {
            success = await epub.goForward(options: navOptions)
          }
        } else if hasPdfTextReader {
          success = await self.goToPdfTextPageOffset(1, animated: animated)
        }
        await MainActor.run() { result(success) }
      }
      break
    case "setPreferences":
      let args = call.arguments as! [String: Any]
      Log.reader.debug("onMethodCall[setPreferences] args = \(args)")
      let preferences = FlutterEPUBPreferences.init(fromMap: args)
      setUserPreferences(preferences: preferences)
      self.preferences = preferences
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

      applyDecorations(decorations, forGroup: identifier)
      break
    case "dispose":
      Log.reader.info("Disposing navigator view controllers")
      epubNavigatorViewController?.view.removeFromSuperview()
      epubNavigatorViewController?.delegate = nil
      epubNavigatorViewController = nil
      clearPdfTextReader()
      emitReaderStatusChanged(status: ReadiumReaderStatusClosed)
      result(nil)
      break
    default:
      Log.reader.warn("Unhandled call: \(call.method)")
      result(FlutterMethodNotImplemented)
      break
    }
  }

  func initUserScripts(registrar: FlutterPluginRegistrar) {
    let flutterReadiumJsKey = registrar.lookupKey(forAsset: "assets/helpers/flutterReadiumTools.js", fromPackage: "flutter_readium")
    let flutterReadiumCssKey = registrar.lookupKey(forAsset: "assets/helpers/flutterReadiumTools.css", fromPackage: "flutter_readium")
    let jsScripts = [flutterReadiumJsKey].map { sourceFile -> String in
      let path = Bundle.main.path(forResource: sourceFile, ofType: nil)!
      let data = FileManager().contents(atPath: path)!
      return String(data: data, encoding: .utf8)!
    }
    let addCssScripts = [flutterReadiumCssKey].map { sourceFile -> String in
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

    /// INJECTED AT DOCUMENT START

    /// Add JS scripts right away, before loading the rest of the document.
    for jsScript in jsScripts {
      userScripts.append(WKUserScript(source: jsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    /// Add simple script used by our JS to detect OS
    userScripts.append(WKUserScript(source: "const isAndroid=false,isIos=true;", injectionTime: .atDocumentStart, forMainFrameOnly: false))

    /// Add all known ToC IDs for this publication to a global javascript array.
    do {
      let tocFragments = self.publication.getFlattenedToC().compactMap(\.fragment)
      let data = try jsonEncoder.encode(tocFragments)
      if let tocFragmentsJSON = String(data: data, encoding: String.Encoding.utf8) {
        let tocScript = "window.readiumTocIDs = \(tocFragmentsJSON);"
        userScripts.append(WKUserScript(source: tocScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
      }
    } catch (let err) {
      Log.readium.error("Failed to inject ToC IDs in webview: \(err)")
    }

    /// INJECTED AT DOCUMENT END

    /// Add css injection scripts after primary document finished loading.
    for addCssScript in addCssScripts {
      userScripts.append(WKUserScript(source: addCssScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }
  }

  func goBackwardInScrollMode(options: NavigatorGoOptions) async -> Bool {
    guard let epub = epubNavigatorViewController else {
      return false
    }
    guard var locator = getCurrentLocation(),
          let currentProgression = locator.locations.progression else {
      Log.reader.error("no current location or progression")
      return false
    }
    let jsResult = await self.evaluateJavascript("window.flutterReadium.getViewPortSize();")
    guard case .success(let viewPortResult) = jsResult,
          let viewPortMap = viewPortResult as? Dictionary<String, Any> else {
      Log.reader.error("getViewPortSize JS eval failed – \(jsResult.getOrNil() ?? "nil")")
      return false
    }
    let viewPort = ViewPortSize.fromJson(viewPortMap, scrollMode: true)
    let progression = viewPort.progression
    let prevProgression = viewPort.prevProgression
    if (progression == 0.0 && prevProgression <= 0.0) {
      // Current progress is already at the top and prevProgression is <= 0.0,
      // We need to go to the previous file in the readingOrder.
      Log.reader.debug("at beginning, use default goBackward")
      return await epub.goBackward(options: options)
    }

    Log.reader.debug("goBackward from progression:\(currentProgression) to \(prevProgression)")
    locator.locations.progression = clamp(prevProgression, minValue: 0.0, maxValue: 1.0)
    return await epub.go(to: locator, options: options)
  }

  func goForwardInScrollMode(options: NavigatorGoOptions) async -> Bool {
    guard let epub = epubNavigatorViewController else {
      return false
    }
    guard var locator = getCurrentLocation(),
          let currentProgression = locator.locations.progression else {
      Log.reader.error("no current location or progression")
      return false
    }
    let jsResult = await self.evaluateJavascript("window.flutterReadium.getViewPortSize();")
    guard case .success(let viewPortResult) = jsResult,
          let viewPortMap = viewPortResult as? Dictionary<String, Any> else {
      Log.reader.error("getViewPortSize JS eval failed – \(jsResult.getOrNil() ?? "nil")")
      return false
    }
    let viewPort = ViewPortSize.fromJson(viewPortMap, scrollMode: true)

    let endProgression = viewPort.endProgression
    let nextProgression = viewPort.nextProgression
    if (nextProgression >= 1.0 && endProgression == 1.0) {
      // Current progress is already at the top and prevProgression is <= 0.0,
      // We need to go to the previous file in the readingOrder.
      Log.reader.debug("at end, use default goForward")
      return await epub.goForward(options: options)
    }

    Log.reader.debug("goForward from progression:\(currentProgression) to \(nextProgression)")
    locator.locations.progression = clamp(nextProgression, minValue: 0.0, maxValue: 1.0)
    return await epub.go(to: locator, options: options)
  }
}

import 'dart:async';
import 'dart:convert' show json;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_readium_platform_interface/flutter_readium_platform_interface.dart';
export 'package:flutter_readium_platform_interface/flutter_readium_platform_interface.dart';

class FlutterReadium {
  /// Constructs a singleton instance of [FlutterReadium].
  factory FlutterReadium() {
    _singleton ??= FlutterReadium._();
    return _singleton!;
  }

  FlutterReadium._();

  static FlutterReadium? _singleton;

  static FlutterReadiumPlatform get _platform {
    return FlutterReadiumPlatform.instance;
  }

  Future<Publication> openPublication(String pubUrl) {
    return _platform.openPublication(pubUrl);
  }

  Future<void> closePublication(String pubUrl) {
    return _platform.closePublication(pubUrl);
  }

  SyncMediaNarration? _findDepthFirstTextAudioPair(SyncMediaNarration node) {
    if (isTextAudioPair(node)) {
      return node;
    } else if (node.narration != null) {
      // Check children (depth first).
      for (final n in node.narration!) {
        return _findDepthFirstTextAudioPair(n);
      }
    }
    return null;
  }

  Iterable<SyncMediaNarration> toFlatTextAudioPairs(SyncMediaNarration node) =>
      node.recursiveNarrations.where(isTextAudioPair);

  bool isTextAudioPair(SyncMediaNarration node) => node.audio != null && node.text != null;

  Future<void> playOverlayAudiobook(Publication publication) async {
    // Online resources:
    // https://github.com/edrlab/thorium-reader/wiki/Implementation-notes:-EPUB3-Media-Overlays,-Readium-WebPub-Manifest-and-W3C-%22Sync-Narration%22
    // https://github.com/edrlab/r2-shared-js/blob/develop/src/parser/epub.ts#L398
    // https://github.com/edrlab/r2-navigator-js/blob/develop/src/electron/renderer/media-overlays.ts#L91
    // https://github.com/edrlab/r2-navigator-js/blob/develop/src/electron/renderer/media-overlays.ts#L1031
    // https://github.com/edrlab/r2-navigator-js/blob/develop/src/electron/renderer/media-overlays.ts#L419
    // https://github.com/readium/go-toolkit/blob/develop/pkg/parser/epub/media_overlay_service.go#L77

    final pubType = publication.metadata.type;
    final hasMediaOverlays = publication.hasMediaOverlays;

    // Test if the book has media-overlays to play.
    if (!hasMediaOverlays) {
      return;
    }

    // Load all media-overlays from publication.
    // TODO: Do we go through resources or readingOrder.alternate?
    // TODO: Also support SMIL
    // TODO: Convert to Guided Navigation?
    final readingOrderNarrationLinks = publication.readingOrder
        .map((l) => l.alternate?.firstWhereOrNull((final link) => link.type == MediaType.syncMediaNarration.value))
        .nonNulls;

    if (readingOrderNarrationLinks.isEmpty) {
      R2Log.d('No narration resources. Not an audio book?');
    }

    Iterable<Future<String?>> syncNarrationFileFutures =
        readingOrderNarrationLinks.map((link) => _platform.getLinkContent(publication.identifier, link));

    final syncNarrationFiles = await Future.wait(syncNarrationFileFutures);
    final syncMediaNarrations = syncNarrationFiles.nonNulls
        .map((n) => SyncMediaNarration.fromJson(json.decode(n) as Map<String, dynamic>))
        .toList();

    if (kDebugMode) {
      debugPrint('Retrieved ${syncMediaNarrations.length} synchronized media narration files');
    }

    // Flatten into a text/audio pair playlist
    final flatTextAudioPlaylist = syncMediaNarrations.map(toFlatTextAudioPairs).flattened.toList();

    // Check total duration from both playlist and original links.
    final totalDurationFromPlaylist = flatTextAudioPlaylist.map((n) => n.duration).nonNulls.reduce((a, b) => a + b);
    final totalDurationFromLinks = readingOrderNarrationLinks.map((l) => l.duration).nonNulls.reduce((a, b) => a + b);

    return Future.value();
  }

  Future<String?> getLinkContent(final String pubIdentifier, final Link link) {
    return _platform.getLinkContent(pubIdentifier, link);
  }

  Stream<ReadiumReaderStatus> get onReaderStatusChanged => _platform.onReaderStatusChanged;

  Stream<Locator> get onTextLocatorChanged {
    return _platform.onTextLocatorChanged;
  }

  Stream<Locator> get onAudioLocatorChanged {
    return _platform.onAudioLocatorChanged;
  }

  Future<void> goLeft() {
    return _platform.goLeft();
  }

  Future<void> goRight() {
    return _platform.goRight();
  }

  Future<void> skipToNext() {
    return _platform.skipToNext();
  }

  Future<void> skipToPrevious() {
    return _platform.skipToPrevious();
  }

  Future<void> setEPUBPreferences(EPUBPreferences preferences) => _platform.setEPUBPreferences(preferences);

  Future<void> applyDecorations(String id, List<ReaderDecoration> decorations) =>
      _platform.applyDecorations(id, decorations);

  Future<void> ttsEnable(TTSPreferences? preferences) => _platform.ttsEnable(preferences);
  Future<void> ttsStart(Locator? fromLocator) => _platform.ttsStart(fromLocator);
  Future<void> ttsStop() => _platform.ttsStop();
  Future<void> ttsPause() => _platform.ttsPause();
  Future<void> ttsResume() => _platform.ttsResume();
  Future<void> ttsNext() => _platform.ttsNext();
  Future<void> ttsPrevious() => _platform.ttsPrevious();
  Future<void> ttsSetPreferences(TTSPreferences preferences) => _platform.ttsSetPreferences(preferences);
  Future<void> ttsSetDecorationStyle(
          ReaderDecorationStyle? utteranceDecoration, ReaderDecorationStyle? rangeDecoration) =>
      _platform.ttsSetDecorationStyle(utteranceDecoration, rangeDecoration);
  Future<List<ReaderTTSVoice>> ttsGetAvailableVoices() => _platform.ttsGetAvailableVoices();
  Future<void> ttsSetVoice(String voiceIdentifier, String? forLanguage) =>
      _platform.ttsSetVoice(voiceIdentifier, forLanguage);
}

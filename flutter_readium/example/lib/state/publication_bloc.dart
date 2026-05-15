import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_readium/flutter_readium.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:rxdart/rxdart.dart';

const _locatorSaveDebounce = Duration(milliseconds: 350);

final Map<String, Locator> savedLocators = {};

abstract class PublicationEvent {}

class ClosePublication extends PublicationEvent {}

class OpenPublication extends PublicationEvent {
  OpenPublication({
    required this.publicationUrl,
    this.initialLocator,
    this.autoPlay,
  });
  final String publicationUrl;
  final Locator? initialLocator;
  final bool? autoPlay;
}

class SavePublicationLocator extends PublicationEvent {
  SavePublicationLocator({
    required this.publicationIdentifier,
    required this.locator,
  });

  final String publicationIdentifier;
  final Locator locator;
}

class PublicationState {
  PublicationState({
    this.publication,
    this.initialLocator,
    this.error,
    this.isLoading = false,
    this.savedLocatorRevision = 0,
  });
  final Publication? publication;
  final Locator? initialLocator;
  final dynamic error;
  final bool isLoading;
  final int savedLocatorRevision;

  PublicationState copyWith({
    final Publication? publication,
    final Locator? initialLocator,
    final dynamic error,
    final bool? isLoading,
    final int? savedLocatorRevision,
  }) => PublicationState(
    publication: publication ?? this.publication,
    initialLocator: initialLocator ?? this.initialLocator,
    error: error ?? this.error,
    isLoading: isLoading ?? this.isLoading,
    savedLocatorRevision: savedLocatorRevision ?? this.savedLocatorRevision,
  );

  PublicationState openPublicationSuccess(
    final Publication publication,
    Locator? initialLocator,
  ) => PublicationState(
    publication: publication,
    initialLocator: initialLocator,
    isLoading: false,
    error: null,
    savedLocatorRevision: savedLocatorRevision,
  );

  PublicationState openPublicationFail(final dynamic error) =>
      copyWith(publication: publication, error: error, isLoading: false);

  PublicationState loading(Locator? initialLocator) =>
      copyWith(isLoading: true, initialLocator: initialLocator);

  String errorDebugDescription() {
    if (error is ReadiumException) {
      ReadiumException re = error as ReadiumException;
      return '${re.type}: ${re.message}';
    } else {
      return error.toString();
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'publication': publication?.toJson(),
      'initialLocator': initialLocator?.toJson(),
      'error': error?.toString(),
      'isLoading': isLoading,
      'savedLocatorRevision': savedLocatorRevision,
      'savedLocators': _savedLocatorsToJson(),
    };
  }

  static PublicationState? fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return null;
    }

    final jsonObject = Map<String, dynamic>.of(json);

    final publication = Publication.fromJson(
      jsonObject.optNullableMap('publication', remove: true),
    );
    final initialLocator = Locator.fromJson(
      jsonObject.optNullableMap('initialLocator', remove: true),
    );
    final error = jsonObject.opt('error', remove: true);
    final isLoading = jsonObject.optBoolean(
      'isLoading',
      fallback: false,
      remove: true,
    );
    final savedLocatorRevision =
        jsonObject.optNullableInt('savedLocatorRevision', remove: true) ?? 0;
    _restoreSavedLocators(
      jsonObject.optNullableMap('savedLocators', remove: true),
    );

    return PublicationState(
      publication: publication,
      initialLocator: initialLocator,
      error: error,
      isLoading: isLoading,
      savedLocatorRevision: savedLocatorRevision,
    );
  }
}

class PublicationBloc extends HydratedBloc<PublicationEvent, PublicationState> {
  StreamSubscription? timebasedStateSub;
  StreamSubscription? textLocatorSub;
  StreamSubscription? errorEventSub;
  Timer? _locatorSaveDebounceTimer;
  String? _pendingPublicationIdentifier;
  Locator? _pendingLocator;

  PublicationBloc() : super(PublicationState()) {
    on<OpenPublication>((final event, final emit) async {
      _persistPendingLocator(emit);
      await _cancelSubscriptions();

      emit(state.loading(event.initialLocator));
      try {
        final instance = FlutterReadium();
        final publication = await instance.openPublication(
          event.publicationUrl,
        );

        emit(state.openPublicationSuccess(publication, event.initialLocator));

        // Listen to timebased player state changes to log current locator for debugging purposes.
        timebasedStateSub = instance.onTimebasedPlayerStateChanged
            .where((state) => state.currentLocator != null)
            .map((state) => state.currentLocator)
            .distinct()
            .throttleTime(const Duration(milliseconds: 100), trailing: true)
            .listen((locator) {
              debugPrint('onTimebasedPlayerState.currentLocator: $locator');
              _scheduleLocatorSave(publication.identifier, locator!);
            });

        var hasAcceptedTextLocator = false;
        textLocatorSub = instance.onTextLocatorChanged
            .where((locator) {
              final shouldSave = _shouldSaveTextLocator(
                locator: locator,
                restoreLocator: event.initialLocator,
                hasAcceptedLocator: hasAcceptedTextLocator,
              );
              if (shouldSave) {
                hasAcceptedTextLocator = true;
              }
              return shouldSave;
            })
            .distinct()
            .listen((locator) {
              debugPrint('onTextLocatorChanged: $locator');
              _scheduleLocatorSave(publication.identifier, locator);
            });

        errorEventSub = instance.onErrorEvent.listen((error) {
          debugPrint('onFlutterReadiumErrorEvent: $error');
        });
      } on Exception catch (error) {
        if (error is ReadiumException) {
          debugPrint(
            'ReadiumException on opening publication: ${error.type} - ${error.message}',
          );
        } else {
          debugPrint(
            'Unknown exception on opening publication: ${error.toString()}',
          );
        }
        emit(state.openPublicationFail(error));
      }
    });

    on<ClosePublication>((final event, final emit) async {
      _persistPendingLocator(emit);
      try {
        await FlutterReadium().closePublication();
        await _cancelSubscriptions();
      } on Exception catch (error) {
        debugPrint('Exception while closing publication: ${error.toString()}');
      }
      emit(PublicationState(savedLocatorRevision: state.savedLocatorRevision));
    });

    on<SavePublicationLocator>((final event, final emit) {
      _persistLocator(event.publicationIdentifier, event.locator, emit);
    });
  }

  @override
  PublicationState? fromJson(Map<String, dynamic> json) {
    return PublicationState.fromJson(json);
  }

  @override
  Map<String, dynamic>? toJson(PublicationState state) {
    return state.toJson();
  }

  @override
  Future<void> close() async {
    _locatorSaveDebounceTimer?.cancel();
    await _cancelSubscriptions();
    return super.close();
  }

  Future<void> _cancelSubscriptions() async {
    await timebasedStateSub?.cancel();
    await textLocatorSub?.cancel();
    await errorEventSub?.cancel();

    timebasedStateSub = null;
    textLocatorSub = null;
    errorEventSub = null;
  }

  void _scheduleLocatorSave(String publicationIdentifier, Locator locator) {
    if (!_isUsableLocator(locator)) {
      return;
    }

    _pendingPublicationIdentifier = publicationIdentifier;
    _pendingLocator = locator;
    _locatorSaveDebounceTimer?.cancel();
    _locatorSaveDebounceTimer = Timer(_locatorSaveDebounce, () {
      final pendingIdentifier = _pendingPublicationIdentifier;
      final pendingLocator = _pendingLocator;
      _pendingPublicationIdentifier = null;
      _pendingLocator = null;

      if (!isClosed && pendingIdentifier != null && pendingLocator != null) {
        add(
          SavePublicationLocator(
            publicationIdentifier: pendingIdentifier,
            locator: pendingLocator,
          ),
        );
      }
    });
  }

  void _persistPendingLocator(Emitter<PublicationState> emit) {
    final pendingIdentifier = _pendingPublicationIdentifier;
    final pendingLocator = _pendingLocator;

    _locatorSaveDebounceTimer?.cancel();
    _locatorSaveDebounceTimer = null;
    _pendingPublicationIdentifier = null;
    _pendingLocator = null;

    if (pendingIdentifier != null && pendingLocator != null) {
      _persistLocator(pendingIdentifier, pendingLocator, emit);
    }
  }

  void _persistLocator(
    String publicationIdentifier,
    Locator locator,
    Emitter<PublicationState> emit,
  ) {
    if (!_isUsableLocator(locator) ||
        savedLocators[publicationIdentifier] == locator) {
      return;
    }

    savedLocators[publicationIdentifier] = locator;
    emit(state.copyWith(savedLocatorRevision: state.savedLocatorRevision + 1));
  }
}

Map<String, dynamic> _savedLocatorsToJson() => savedLocators.map(
  (identifier, locator) => MapEntry(identifier, locator.toJson()),
);

void _restoreSavedLocators(Map<String, dynamic>? locatorsJson) {
  if (locatorsJson == null) {
    return;
  }

  savedLocators
    ..clear()
    ..addEntries(
      locatorsJson.entries.map((entry) {
        final locatorJson = entry.value;
        if (locatorJson is! Map) {
          return null;
        }

        final locator = Locator.fromJson(
          Map<String, dynamic>.from(locatorJson),
        );
        if (locator == null) {
          return null;
        }

        return MapEntry(entry.key, locator);
      }).nonNulls,
    );
}

bool _shouldSaveTextLocator({
  required Locator locator,
  required Locator? restoreLocator,
  required bool hasAcceptedLocator,
}) {
  if (!_isUsableLocator(locator)) {
    return false;
  }

  if (hasAcceptedLocator) {
    return true;
  }

  if (_isStartupNoise(locator, restoreLocator)) {
    debugPrint(
      'Ignoring startup text locator noise while restoring previous position: $locator',
    );
    return false;
  }

  return true;
}

bool _isUsableLocator(Locator locator) =>
    locator.href.isNotEmpty && locator.type.isNotEmpty;

bool _isStartupNoise(Locator locator, Locator? restoreLocator) {
  if (restoreLocator == null) {
    return false;
  }

  // Chỉ áp dụng bộ lọc khi đang restore đến vị trí có nghĩa (past start)
  // hoặc khi chapter hiện tại khác chapter cần restore.
  final restoreLooksPastStart =
      _isMeaningfullyPastStart(restoreLocator) ||
      locator.href != restoreLocator.href;
  if (!restoreLooksPastStart) {
    return false;
  }

  // Nếu locator trùng với restore target → không phải noise.
  if (_sameRestoreTarget(locator, restoreLocator)) {
    return false;
  }

  // Trường hợp 1: Locator ở đầu toàn bộ publication (chapter 1, totalProgression≈0).
  // Xảy ra khi navigator render chapter đầu trước khi nhảy đến đúng chapter.
  if (_isAtPublicationStart(locator)) {
    return true;
  }

  // Trường hợp 2 (phổ biến trên iOS): Locator ở đúng chapter cần restore nhưng
  // progression≈0.0 — navigator đã load đúng chapter nhưng CHƯA scroll đến vị trí saved.
  // Readium sau đó scroll và bắn event thứ 2 với progression chính xác (~500ms sau).
  // Nếu không lọc, debounce 350ms sẽ kịp fire event sai này trước khi event đúng đến.
  if (locator.href == restoreLocator.href && _isAtChapterStart(locator)) {
    return true;
  }

  return false;
}

/// Locator đang ở đầu chapter (progression≈0 trong chapter hiện tại).
/// Khác với [_isAtPublicationStart] — không kiểm tra totalProgression.
bool _isAtChapterStart(Locator locator) =>
    (locator.locations?.progression ?? 0.0) <= 0.0001;

bool _isMeaningfullyPastStart(Locator? locator) {
  final locations = locator?.locations;
  if (locations == null) {
    return false;
  }

  return (locations.progression ?? 0.0) > 0.0001 ||
      (locations.totalProgression ?? 0.0) > 0.0001 ||
      (locations.position ?? 1) > 1 ||
      locations.fragments.isNotEmpty;
}

bool _isAtPublicationStart(Locator locator) {
  final locations = locator.locations;
  return (locations?.progression ?? 0.0) <= 0.0001 &&
      (locations?.totalProgression ?? 0.0) <= 0.0001 &&
      (locations?.position ?? 1) <= 1 &&
      (locations?.fragments.isEmpty ?? true);
}

bool _sameRestoreTarget(Locator locator, Locator restoreLocator) {
  if (locator.href != restoreLocator.href) {
    return false;
  }

  final position = locator.locations?.position;
  final restorePosition = restoreLocator.locations?.position;
  if (position != null &&
      restorePosition != null &&
      position == restorePosition) {
    return true;
  }

  final progression = locator.locations?.progression;
  final restoreProgression = restoreLocator.locations?.progression;
  if (progression != null &&
      restoreProgression != null &&
      (progression - restoreProgression).abs() <= 0.001) {
    return true;
  }

  final totalProgression = locator.locations?.totalProgression;
  final restoreTotalProgression = restoreLocator.locations?.totalProgression;
  if (totalProgression != null &&
      restoreTotalProgression != null &&
      (totalProgression - restoreTotalProgression).abs() <= 0.001) {
    return true;
  }

  final fragments = locator.locations?.fragments.toSet() ?? {};
  final restoreFragments = restoreLocator.locations?.fragments.toSet() ?? {};
  return fragments.intersection(restoreFragments).isNotEmpty;
}

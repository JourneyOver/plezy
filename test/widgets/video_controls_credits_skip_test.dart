import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/skip_marker_button.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

const _duration = Duration(minutes: 45);

/// Skip Credits on a marker that runs to the end of the file used to start the
/// next episode outright. It now follows the end-of-episode settings (#2537):
/// with the Play Next prompt hidden and auto-play off the completion flow owns
/// the finish, so the viewer leaves instead of advancing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late ValueNotifier<bool> hasFirstFrame;
  late SettingsService settings;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    chrome = PlayerChromeController(initiallyVisible: false);
    toast = PlayerToastController();
    hasFirstFrame = ValueNotifier<bool>(true);
  });

  tearDown(() async {
    hasFirstFrame.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await database.close();
  });

  /// Mounts the controls over a credits marker that ends with the file, then
  /// taps the skip button. [next] counts straight advances, [reachedEnd] the
  /// hand-off to the completion flow.
  Future<({int next, int reachedEnd, bool? countdownWaived})> tapSkipCredits(
    WidgetTester tester, {
    required bool autoPlay,
    required bool prompt,
    required String expectedLabel,
  }) async {
    await settings.write(SettingsService.autoPlayNextEpisode, autoPlay);
    await settings.write(SettingsService.showPlayNextPrompt, prompt);

    final player = _CreditsPlayer();
    addTearDown(player.dispose);
    final volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    addTearDown(volume.dispose);

    var next = 0;
    var reachedEnd = 0;
    bool? countdownWaived;

    await tester.pumpWidget(
      InputModeTracker(
        child: MultiProvider(
          providers: [
            Provider<AppDatabase>.value(value: database),
            ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows, extensions: const [testMonoTokens]),
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 720,
                child: PlexVideoControls(
                  player: player,
                  volumeController: volume,
                  metadata: testMediaItem(id: 'credits-skip'),
                  initialMarkers: [
                    MediaMarker(
                      id: 1,
                      type: 'credits',
                      startTimeOffset: 2400000,
                      endTimeOffset: _duration.inMilliseconds,
                    ),
                  ],
                  toastController: toast,
                  chromeController: chrome,
                  hasFirstFrame: hasFirstFrame,
                  canNavigateMediaItems: false,
                  onNext: () => next++,
                  onReachedEnd: ({required skipAutoPlayCountdown}) {
                    reachedEnd++;
                    countdownWaived = skipAutoPlayCountdown;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Marker detection rides the position stream; one tick inside the credits
    // puts the skip button on screen.
    player.emitPosition(const Duration(minutes: 41));
    await tester.pumpAndSettle();
    expect(find.byType(SkipMarkerButton), findsOneWidget);
    expect(find.text(expectedLabel), findsOneWidget, reason: 'the pill must name what tapping it actually does');

    await tester.tap(find.byType(SkipMarkerButton));
    await tester.pumpAndSettle();

    chrome.cancelAutoHide();
    await tester.pumpWidget(const SizedBox.shrink());
    return (next: next, reachedEnd: reachedEnd, countdownWaived: countdownWaived);
  }

  testWidgets('auto-play on keeps the straight advance to the next episode', (tester) async {
    final result = await tapSkipCredits(tester, autoPlay: true, prompt: true, expectedLabel: 'Next Episode');

    expect(result.next, 1);
    expect(result.reachedEnd, 0);
  });

  testWidgets('auto-play on with the prompt hidden still advances', (tester) async {
    final result = await tapSkipCredits(tester, autoPlay: true, prompt: false, expectedLabel: 'Next Episode');

    expect(result.next, 1);
    expect(result.reachedEnd, 0);
  });

  testWidgets('auto-play off with the prompt on still advances', (tester) async {
    final result = await tapSkipCredits(tester, autoPlay: false, prompt: true, expectedLabel: 'Next Episode');

    expect(result.next, 1);
    expect(result.reachedEnd, 0);
  });

  testWidgets('auto-play off with the prompt hidden keeps the Skip Credits label and hands off', (tester) async {
    final result = await tapSkipCredits(tester, autoPlay: false, prompt: false, expectedLabel: 'Skip Credits');

    expect(result.next, 0, reason: 'the next episode must not start');
    expect(result.reachedEnd, 1);
    expect(result.countdownWaived, isFalse);
  });
}

/// A player parked inside the credits marker, with a position stream the way a
/// real player drives marker detection.
class _CreditsPlayer implements Player {
  Duration _position = const Duration(minutes: 40);
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();

  void emitPosition(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) => _positionController.close();

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(playing: true, position: _position, duration: _duration, seekable: true);

  /// A real player announces the new playhead right after a seek.
  @override
  Future<void> seek(Duration position) async => emitPosition(position);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

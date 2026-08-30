import '../../database/app_database.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../media/media_source_info.dart';
import '../../services/cached_playback_metadata_service.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/global_key_utils.dart';
import '../../services/the_intro_db_service.dart';

class VideoControlsPlaybackExtrasLoader {
  final MediaItem metadata;
  final MediaServerClient? client;
  final AppDatabase database;

  const VideoControlsPlaybackExtrasLoader({required this.metadata, required this.database, required this.client});

  Future<PlaybackExtras?> load({bool forceRefresh = false}) async {
    PlaybackExtras? extras;

    if (client == null) {
      extras = await _loadFromCacheOnly(cacheServerId: await _resolveCacheServerId());
    } else {
      try {
        appLogger.d('_loadPlaybackExtras: starting for ${metadata.id} (forceRefresh=$forceRefresh)');
        final settings = await SettingsService.getInstance();
        extras = await client!.fetchPlaybackExtras(
          metadata.id,
          introPattern: settings.read(SettingsService.introPattern),
          creditsPattern: settings.read(SettingsService.creditsPattern),
          forceChapterFallback: settings.read(SettingsService.forceSkipMarkerFallback),
          forceRefresh: forceRefresh,
        );
        appLogger.d('_loadPlaybackExtras: got ${_describe(extras)}');
      } catch (e, stack) {
        appLogger.d('_loadPlaybackExtras: network path failed, trying cache fallback');
        extras = await _loadFromCacheOnly(cacheServerId: client!.serverId);
        if (extras == null) {
          appLogger.e('_loadPlaybackExtras failed', error: e, stackTrace: stack);
        }
      }
    }

    // When the server and chapter titles leave intro or credits undetected,
    // query TheIntroDB and merge its markers in, deduped against the existing
    // markers within a 5 s start-offset window.
    final fileHasIntro = extras?.markers.any((m) => m.type == 'intro') ?? false;
    final fileHasCredits = extras?.markers.any((m) => m.isCredits) ?? false;
    if (!fileHasIntro || !fileHasCredits) {
      try {
        final baseExtras = extras ?? PlaybackExtras(chapters: const [], markers: const []);
        final introDbMarkers = await TheIntroDbService.instance.fetchMarkers(metadata, client: client);
        if (introDbMarkers.isNotEmpty) {
          final mergedMarkers = List<MediaMarker>.from(baseExtras.markers);
          for (final m in introDbMarkers) {
            final exists = mergedMarkers.any(
              (existing) => existing.type == m.type && (existing.startTimeOffset - m.startTimeOffset).abs() < 5000,
            );
            if (!exists) {
              mergedMarkers.add(m);
            }
          }
          extras = PlaybackExtras(chapters: baseExtras.chapters, markers: mergedMarkers);
          appLogger.i('TheIntroDB: Merged ${introDbMarkers.length} markers for ${metadata.displayTitle}');
        }
      } catch (e) {
        appLogger.w('Failed to merge TheIntroDB markers', error: e);
      }
    }

    return extras;
  }

  Future<PlaybackExtras?> _loadFromCacheOnly({required String? cacheServerId}) async {
    if (cacheServerId == null) {
      appLogger.w('_loadPlaybackExtras: no client or cache scope for server ${metadata.serverId}');
      return null;
    }
    try {
      final settings = await SettingsService.getInstance();
      final extras = await CachedPlaybackMetadataService.fetchPlaybackExtras(
        backend: metadata.backend,
        cacheServerId: cacheServerId,
        itemId: metadata.id,
        introPattern: settings.read(SettingsService.introPattern),
        creditsPattern: settings.read(SettingsService.creditsPattern),
        forceChapterFallback: settings.read(SettingsService.forceSkipMarkerFallback),
      );
      appLogger.d(
        extras == null
            ? '_loadPlaybackExtras: no cached extras for ${metadata.id}'
            : '_loadPlaybackExtras: cache-only ${_describe(extras)}',
      );
      return extras;
    } catch (e) {
      appLogger.d('_loadPlaybackExtras: cache-only path failed', error: e);
      return null;
    }
  }

  /// Marker counts are the difference between "the server has no intro data"
  /// and "auto-skip never fired", which is otherwise indistinguishable in a
  /// user-supplied log.
  static String _describe(PlaybackExtras extras) {
    final markerTypes = extras.markers.map((m) => m.type).join(',');
    return '${extras.chapters.length} chapters, ${extras.markers.length} markers'
        '${markerTypes.isEmpty ? '' : ' ($markerTypes)'}';
  }

  Future<String?> _resolveCacheServerId() async {
    final serverId = metadata.serverId;
    if (serverId == null) return null;
    try {
      final row = await (database.select(
        database.downloadedMedia,
      )..where((tbl) => tbl.globalKey.equals(buildGlobalKey(ServerId(serverId), metadata.id)))).getSingleOrNull();
      return row?.clientScopeId ?? serverId;
    } catch (_) {
      return serverId;
    }
  }
}

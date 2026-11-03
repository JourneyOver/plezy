import 'dart:convert';
import 'package:http/http.dart' as http;
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/media_source_info.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';

/// Service integration for The Intro DB API v4 (theintrodb.org)
/// Fetches intro, recap, credits, and preview timestamps for movies and TV episodes.
///
/// v4 is keyed by TVDB and addresses a media by `tvdb_id` → `tmdb_id` →
/// `imdb_id`, so requests prefer the TVDB id whenever the server knows it.
class TheIntroDbService {
  static final TheIntroDbService instance = TheIntroDbService._();
  TheIntroDbService._();

  static const String _baseUrl = 'https://api.theintrodb.org/v4/media';

  /// Current-user account endpoint. `GET /media` accepts (and ignores) an
  /// invalid key, so only `/me` can tell a working key from a dead one.
  static const String _accountUrl = 'https://api.theintrodb.org/v4/me';

  static const Duration _timeout = Duration(seconds: 4);

  /// Segment properties `GET /media` may carry. Each is an array, and one
  /// segment type may hold several ranges.
  static const List<String> _segmentTypes = ['intro', 'recap', 'credits', 'preview'];

  /// Segments that sit at the end of the file, whose `end_ms: null` means "runs
  /// to the end of the media".
  static const Set<String> _trailingTypes = {'credits', 'preview'};

  /// End used for a segment the API left open ended when the file duration is
  /// unknown. Roughly one credits roll; harmless if it lands short.
  static const int _openEndFallbackMs = 90000;

  /// Tests connection to The Intro DB using specified [apiKey] or configured settings.
  ///
  /// A configured key is checked against the account endpoint, which is the
  /// only place an invalid key is refused. Without a key the check is a public
  /// media request, which is what unauthenticated playback will use.
  Future<bool> testConnection([String? apiKey]) async {
    final key = (apiKey ?? SettingsService.instance.read(SettingsService.theIntroDbApiKey))?.trim();
    try {
      if (key != null && key.isNotEmpty) {
        final me = await http.get(Uri.parse(_accountUrl), headers: _headers(key)).timeout(_timeout);
        if (me.statusCode == 200) return true;
        if (me.statusCode == 401 || me.statusCode == 403) {
          appLogger.d('TheIntroDbService: API key rejected (${me.statusCode})');
          return false;
        }
        appLogger.d('TheIntroDbService: /me answered ${me.statusCode}, probing /media instead');
      }
      final response = await http
          .get(Uri.parse('$_baseUrl?tvdb_id=81189&season=1&episode=1'), headers: _headers(null))
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetches media timestamps from The Intro DB and maps them to [MediaMarker] instances.
  Future<List<MediaMarker>> fetchMarkers(
    MediaItem metadata, {
    MediaServerClient? client,
    int? durationMs,
    String? apiKey,
  }) async {
    final key = (apiKey ?? SettingsService.instance.read(SettingsService.theIntroDbApiKey))?.trim();
    final effectiveDuration = durationMs ?? metadata.durationMs;
    try {
      final ids = await _resolveExternalIds(metadata, client: client);
      final identities = _identityParams(ids);
      if (identities.isEmpty) {
        appLogger.d('TheIntroDbService: No external IDs available for ${metadata.displayTitle}');
        return const [];
      }

      final params = <String, String>{};
      // `season` and `episode` are only meaningful together: v4 rejects one
      // without the other.
      if (metadata.kind == MediaKind.episode) {
        final season = metadata.parentIndex;
        final episode = metadata.index;
        if (season != null && episode != null) {
          params['season'] = season.toString();
          params['episode'] = episode.toString();
        }
      }
      // v4 picks the release version closest to this duration (theatrical,
      // extended, …) within 5 minutes.
      if (effectiveDuration != null && effectiveDuration > 0) {
        params['duration_ms'] = effectiveDuration.toString();
      }

      http.Response? response;
      for (final identity in identities) {
        response = await _fetch({...identity, ...params}, key);
        if (response.statusCode != 404) break;
        appLogger.d('TheIntroDbService: no timestamps addressed by $identity, trying another id');
      }
      if (response == null) return const [];

      if (response.statusCode != 200) {
        final body = response.body.length > 300 ? response.body.substring(0, 300) : response.body;
        appLogger.w('TheIntroDbService HTTP ${response.statusCode}: $body');
        return const [];
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];

      final markers = parseMarkers(decoded, durationMs: effectiveDuration);
      appLogger.i('TheIntroDbService: Fetched ${markers.length} markers for ${metadata.displayTitle}');
      return markers;
    } catch (e) {
      appLogger.w('TheIntroDbService: Failed to fetch markers: $e');
    }
    return const [];
  }

  /// Maps a `GET /media` body to markers.
  ///
  /// v4 writes `0` where a segment does not exist (a credits or preview start,
  /// any type's end) and `null` where the value means "beginning of the media"
  /// (intro/recap start) or "end of the media" (credits/preview end). The two
  /// are not interchangeable: a `0` read as a start would make a credits marker
  /// cover the whole file.
  static List<MediaMarker> parseMarkers(Map<String, dynamic> body, {int? durationMs, int firstMarkerId = 9000}) {
    final markers = <MediaMarker>[];
    var nextId = firstMarkerId;

    for (final type in _segmentTypes) {
      final segments = body[type];
      if (segments is! List) continue;

      for (final segment in segments) {
        if (segment is! Map) continue;

        final rawStart = segment['start_ms'];
        final rawEnd = segment['end_ms'];
        final startMs = rawStart is num ? rawStart.toInt() : null;
        final endMs = rawEnd is num ? rawEnd.toInt() : null;

        final start = (startMs == null || startMs <= 0) ? 0 : startMs;

        if (start == 0 && _trailingTypes.contains(type)) continue;
        if (endMs != null && endMs <= 0) continue;

        final end = endMs ?? _openEnd(type, start, durationMs);
        if (end <= start) continue;

        markers.add(MediaMarker(id: nextId++, type: type, startTimeOffset: start, endTimeOffset: end));
      }
    }
    return markers;
  }

  static int _openEnd(String type, int startMs, int? durationMs) {
    // Skip Credits hands the finish to the completion flow only when the marker
    // ends with the file, so trailing segments need the real duration.
    if (_trailingTypes.contains(type) && durationMs != null && durationMs > startMs) return durationMs;
    return startMs + _openEndFallbackMs;
  }

  static Map<String, String> _headers(String? key) => {
    'Accept': 'application/json',
    if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
  };

  Future<http.Response> _fetch(Map<String, String> params, String? key) {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: params);
    appLogger.d('TheIntroDbService: Fetching $uri');
    return http.get(uri, headers: _headers(key)).timeout(_timeout);
  }

  /// Identity query params in v4's resolution order: TVDB first, because it is
  /// the stored identity and the other two are resolved server-side.
  static List<Map<String, String>> _identityParams(ExternalIds? ids) {
    if (ids == null) return const [];
    return [
      if (ids.tvdb != null) {'tvdb_id': ids.tvdb.toString()},
      if (ids.tmdb != null) {'tmdb_id': ids.tmdb.toString()},
      if (ids.imdb != null && ids.imdb!.isNotEmpty) {'imdb_id': ids.imdb!},
    ];
  }

  Future<ExternalIds?> _resolveExternalIds(MediaItem metadata, {MediaServerClient? client}) async {
    ExternalIds? ids;

    if (metadata.kind == MediaKind.episode) {
      // 1. Check if raw has SeriesProviderIds (Emby / Jellyfin)
      if (metadata.raw != null && metadata.raw!['SeriesProviderIds'] is Map) {
        final pMap = (metadata.raw!['SeriesProviderIds'] as Map).cast<String, Object?>();
        ids = ExternalIds.fromJellyfinProviderIds(pMap);
      }

      // 2. Fetch show external IDs via client using grandparentId / parentId / SeriesId
      if ((ids == null || !ids.hasAny) && client != null) {
        final showId =
            metadata.grandparentId ??
            metadata.parentId ??
            (metadata.raw != null ? metadata.raw!['SeriesId'] as String? : null);
        if (showId != null && showId.isNotEmpty) {
          try {
            ids = await client.fetchExternalIds(showId);
          } catch (_) {}
        }
      }
    } else {
      // For Movies & Shows
      if (metadata.guid != null) {
        ids = ExternalIds.fromGuids([metadata.guid!]);
      }
      if ((ids == null || !ids.hasAny) && metadata.raw != null) {
        final rawMap = metadata.raw!;
        if (rawMap['ProviderIds'] is Map) {
          final pMap = (rawMap['ProviderIds'] as Map).cast<String, Object?>();
          ids = ExternalIds.fromJellyfinProviderIds(pMap);
        }
      }
      if ((ids == null || !ids.hasAny) && client != null) {
        try {
          ids = await client.fetchExternalIds(metadata.id);
        } catch (_) {}
      }
    }

    // 3. Fallback to TMDB Search API if still no IDs
    if (ids == null || !ids.hasAny) {
      try {
        final tmdbId = await _findTmdbId(metadata);
        if (tmdbId != null) {
          ids = ExternalIds(tmdb: int.parse(tmdbId));
          appLogger.i('TheIntroDbService: Found TMDB ID $tmdbId via search for ${metadata.displayTitle}');
        }
      } catch (e) {
        appLogger.d('TheIntroDbService: Failed to search TMDB for ${metadata.displayTitle}: $e');
      }
    }

    return ids;
  }

  Future<String?> _findTmdbId(MediaItem metadata) async {
    try {
      final isTv =
          metadata.kind == MediaKind.episode || metadata.kind == MediaKind.season || metadata.kind == MediaKind.show;
      final type = isTv ? 'tv' : 'movie';

      String? queryTitle;
      String? queryYear;

      if (isTv) {
        queryTitle = metadata.grandparentTitle ?? metadata.parentTitle ?? metadata.title;
      } else {
        queryTitle = metadata.title;
        queryYear = metadata.year?.toString();
      }

      if (queryTitle == null || queryTitle.isEmpty) return null;

      final yearParam = queryYear != null ? '&primary_release_year=$queryYear' : '';
      final url = Uri.parse(
        'https://api.themoviedb.org/3/search/$type?api_key=3aec63790d50f3b9fc2efb4c15a8cf99&query=${Uri.encodeQueryComponent(queryTitle)}$yearParam',
      );

      final res = await http.get(url).timeout(_timeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>? ?? [];
        if (results.isNotEmpty) {
          final first = results.first as Map<String, dynamic>;
          return first['id']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }
}

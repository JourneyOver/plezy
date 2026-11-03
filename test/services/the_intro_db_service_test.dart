import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/services/the_intro_db_service.dart';

/// v4 writes `0` where a segment does not exist and `null` where a time means
/// "beginning of the media" / "end of the media". Reading the two the same way
/// turns a "no credits" placeholder into a marker that starts at 0:00, and an
/// open-ended credits marker into one that stops 90 s into the credits roll.
void main() {
  List<MediaMarker> parse(Map<String, dynamic> body, {int? durationMs}) =>
      TheIntroDbService.parseMarkers(body, durationMs: durationMs);

  test('null intro start means the beginning of the media', () {
    final markers = parse({
      'tvdb_id': 169,
      'type': 'movie',
      'intro': [
        {'start_ms': null, 'end_ms': 40000},
      ],
    });

    expect(markers, hasLength(1));
    expect(markers.single.type, 'intro');
    expect(markers.single.startTimeOffset, 0);
    expect(markers.single.endTimeOffset, 40000);
  });

  test('null credits end runs to the file duration', () {
    final markers = parse({
      'tvdb_id': 81189,
      'type': 'tv',
      'season': 1,
      'episode': 1,
      'credits': [
        {'start_ms': 3431000, 'end_ms': null},
      ],
    }, durationMs: 3500192);

    expect(markers.single.type, 'credits');
    expect(markers.single.endTimeOffset, 3500192);
    expect(markers.single.containsPosition(const Duration(seconds: 3490)), isTrue);
  });

  test('open-ended credits fall back to a short tail when the duration is unknown', () {
    final markers = parse({
      'credits': [
        {'start_ms': 3431000, 'end_ms': null},
      ],
    });

    expect(markers.single.endTimeOffset, 3431000 + 90000);
  });

  test('an all-zero segment is a placeholder, not a marker', () {
    final markers = parse({
      'credits': [
        {'start_ms': 0, 'end_ms': 0},
      ],
      'preview': [
        {'start_ms': 0, 'end_ms': null},
      ],
      'intro': [
        {'start_ms': 0, 'end_ms': 0},
      ],
    }, durationMs: 3500000);

    expect(markers, isEmpty);
  });

  test('a credits segment starting at zero never becomes a whole-file marker', () {
    final markers = parse({
      'credits': [
        {'start_ms': null, 'end_ms': null},
      ],
    }, durationMs: 3500000);

    expect(markers, isEmpty);
  });

  test('a recap starting at zero is kept, since a recap really starts the file', () {
    final markers = parse({
      'recap': [
        {'start_ms': null, 'end_ms': 60000},
      ],
    });

    expect(markers.single.type, 'recap');
    expect(markers.single.startTimeOffset, 0);
  });

  test('every range of a repeated segment type is kept', () {
    final markers = parse({
      'intro': [
        {'start_ms': 30000, 'end_ms': 90000},
        {'start_ms': 120000, 'end_ms': 150000},
      ],
    });

    expect(markers.map((m) => m.startTimeOffset), [30000, 120000]);
    expect(markers.map((m) => m.id).toSet(), hasLength(2));
  });

  test('inverted or empty ranges are dropped', () {
    final markers = parse({
      'intro': [
        {'start_ms': 60000, 'end_ms': 60000},
        {'start_ms': 90000, 'end_ms': 30000},
      ],
    });

    expect(markers, isEmpty);
  });

  test('a missing or non-list segment property is not a marker', () {
    expect(parse({'tvdb_id': 1, 'type': 'movie'}), isEmpty);
    expect(parse({'intro': 'nope'}), isEmpty);
    expect(
      parse({
        'intro': [42, 'x'],
      }),
      isEmpty,
    );
  });

  test('segments across all four types keep their own kinds', () {
    final markers = parse({
      'intro': [
        {'start_ms': 30000, 'end_ms': 90000},
      ],
      'recap': [
        {'start_ms': null, 'end_ms': 25000},
      ],
      'credits': [
        {'start_ms': 3400000, 'end_ms': null},
      ],
      'preview': [
        {'start_ms': 3480000, 'end_ms': null},
      ],
    }, durationMs: 3500000);

    expect(markers.map((m) => m.type), ['intro', 'recap', 'credits', 'preview']);
    expect(markers.last.endTimeOffset, 3500000);
  });

  group('episode ordering to v4 mapping', () {
    String? mapping(String? ordering) => TheIntroDbService.introDbMappingForEpisodeOrdering(ordering);

    test('Plex showOrdering values', () {
      expect(mapping('tvdbAbsolute'), 'absolute');
      expect(mapping('tvdbDvd'), 'dvd');
      expect(mapping('tvdbAiring'), isNull);
      expect(mapping('tmdbAiring'), isNull);
      expect(mapping(''), isNull);
      expect(mapping(null), isNull);
    });

    test('Jellyfin and Emby DisplayOrder values', () {
      expect(mapping('absolute'), 'absolute');
      expect(mapping('dvd'), 'dvd');
      expect(mapping('originalAirDate'), isNull);
      expect(mapping('aired'), isNull);
      expect(mapping('tv'), isNull);
      // Valid Jellyfin orders with no TVDB equivalent stay in the default order.
      expect(mapping('digital'), isNull);
      expect(mapping('storyArc'), isNull);
    });

    test('the v4 alias spellings resolve to their canonical order', () {
      expect(mapping('altdvd'), 'dvd');
      expect(mapping('dvdorder'), 'dvd');
      expect(mapping('abso'), 'absolute');
      expect(mapping('absoluteorder'), 'absolute');
      expect(mapping('alttwo'), 'alternate');
      expect(mapping('streaming'), 'alternate');
      expect(mapping('production'), 'regional');
      expect(mapping('regionalorder'), 'regional');
    });

    test('casing, dashes, underscores and padding do not matter', () {
      expect(mapping(' TVDB-Absolute '), 'absolute');
      expect(mapping('Aired_Order'), isNull);
      expect(mapping('ALTERNATE'), 'alternate');
    });

    test('an unknown value is the default order, not a guess', () {
      expect(mapping('sideways'), isNull);
      expect(mapping('   '), isNull);
    });
  });
}

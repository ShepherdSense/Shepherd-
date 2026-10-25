import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shepherd/services/offline_map_source.dart';

/// 1x1 transparent PNG.
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Uint8List _bytes(int length, int fill) =>
    Uint8List.fromList(List.filled(length, fill));

void main() {
  group('keyless-only source definitions', () {
    test('default source is OpenStreetMap standard', () {
      expect(defaultTileSource.id, 'osm_standard');
      expect(defaultTileSource.urlTemplate,
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
    });

    test('all built-in templates carry no key parameter', () {
      for (final source in defaultTileSources) {
        final lower = source.urlTemplate.toLowerCase();
        expect(lower, isNot(contains('key=')));
        expect(lower, isNot(contains('api_key')));
        expect(lower, isNot(contains('token=')));
      }
      expect(
        defaultTileSources.map((s) => s.id),
        ['osm_standard', 'usgs_imagery', 'usgs_topo'],
      );
    });

    test('keyed template is refused', () {
      expect(
        () => TileSource.keyless(
          id: 'keyed',
          displayName: 'Keyed',
          urlTemplate: 'https://example.com/{z}/{x}/{y}.png?key=SECRET',
          attribution: 'x',
        ),
        throwsArgumentError,
      );
      expect(
        () => TileSource.keyless(
          id: 'keyed2',
          displayName: 'Keyed',
          urlTemplate: 'https://example.com/{z}/{x}/{y}.png?access_token=SECRET',
          attribution: 'x',
        ),
        throwsArgumentError,
      );
    });

    test('template missing a placeholder is refused', () {
      expect(
        () => TileSource.keyless(
          id: 'bad',
          displayName: 'Bad',
          urlTemplate: 'https://example.com/{z}/{x}.png',
          attribution: 'x',
        ),
        throwsArgumentError,
      );
    });

    test('selectTileSource falls back to default for unknown ids', () {
      expect(selectTileSource(null), defaultTileSource);
      expect(selectTileSource('esri'), defaultTileSource);
      expect(selectTileSource('usgs_topo').id, 'usgs_topo');
    });

    test('urlFor expands placeholders, USGS in z/y/x order', () {
      expect(
        kOsmStandard.urlFor(const TileCoord(3, 5, 2)),
        'https://tile.openstreetmap.org/3/5/2.png',
      );
      expect(
        kUsgsImagery.urlFor(const TileCoord(3, 5, 2)),
        'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/3/2/5',
      );
      expect(
        () => kOsmStandard.urlFor(const TileCoord(1, 5, 0)),
        throwsArgumentError,
      );
    });
  });

  group('tile math', () {
    test('latLonToTile at the origin', () {
      expect(latLonToTile(0, 0, 1), const TileCoord(1, 1, 1));
      expect(latLonToTile(0, 0, 0), const TileCoord(0, 0, 0));
    });

    test('tileBounds of the world tile covers the world', () {
      final bounds = tileBounds(const TileCoord(0, 0, 0));
      expect(bounds.west, closeTo(-180.0, 1e-9));
      expect(bounds.east, closeTo(180.0, 1e-9));
      expect(bounds.north, closeTo(kMaxMercatorLat, 1e-6));
      expect(bounds.south, closeTo(-kMaxMercatorLat, 1e-6));
    });

    test('tilesForBounds covers a small box and rejects inverted boxes', () {
      final tiles = tilesForBounds(10, -10, -10, 10, 1);
      expect(tiles, hasLength(4));
      expect(tilesForBounds(-10, 10, -10, 10, 1), isEmpty);
      // v0.26.0 fix-pass: west > east is an antimeridian-crossing
      // box, not an inverted one — it covers both sides.
      final anti = tilesForBounds(10, -10, 10, -10, 1);
      expect(anti, isNotEmpty);
      expect(anti.map((t) => t.x).toSet(), containsAll([0, 1]));
    });
  });

  group('TileCache', () {
    late Directory temp;
    late TileCache cache;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('shepherd_tiles_test_');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('cache hit serves without a network request', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response.bytes(_tinyPng, 200);
      });
      cache = TileCache(client: client, cacheDir: temp);
      const coord = TileCoord(5, 10, 12);
      final first = await cache.fetch(kOsmStandard, coord);
      expect(first.status, TileFetchStatus.network);
      expect(first.bytes, _tinyPng);
      expect(calls, 1);
      // Second fetch with a client that would explode: cache must win.
      final failing = TileCache(
        client: MockClient((_) async => throw http.ClientException('offline')),
        cacheDir: temp,
      );
      final second = await failing.fetch(kOsmStandard, coord);
      expect(second.status, TileFetchStatus.cacheHit);
      expect(second.bytes, _tinyPng);
      expect(calls, 1);
    });

    test('cache miss with no network is missing, never an exception', () async {
      cache = TileCache(
        client: MockClient((_) async => throw http.ClientException('offline')),
        cacheDir: temp,
      );
      final result = await cache.fetch(kOsmStandard, const TileCoord(5, 1, 1));
      expect(result.status, TileFetchStatus.missing);
      expect(result.bytes, isNull);
      expect(result.hasBytes, isFalse);
    });

    test('refresh falls back to stale cache on network failure', () async {
      final good = TileCache(
        client: MockClient((_) async => http.Response.bytes(_tinyPng, 200)),
        cacheDir: temp,
      );
      const coord = TileCoord(5, 3, 3);
      expect((await good.fetch(kOsmStandard, coord)).status,
          TileFetchStatus.network);
      final failing = TileCache(
        client: MockClient((_) async => http.Response('error', 500)),
        cacheDir: temp,
      );
      final stale = await failing.refresh(kOsmStandard, coord);
      expect(stale.status, TileFetchStatus.staleCache);
      expect(stale.bytes, _tinyPng);
      expect(stale.isStale, isTrue);
      // Nothing cached + network down -> missing, not stale.
      final missing =
          await failing.refresh(kOsmStandard, const TileCoord(5, 9, 9));
      expect(missing.status, TileFetchStatus.missing);
    });

    test('bounded eviction drops least-recently-used tiles', () async {
      final client = MockClient((request) async {
        final segments = request.url.pathSegments;
        final fill = int.parse(segments.last.split('.').first);
        return http.Response.bytes(_bytes(60, fill), 200);
      });
      // OSM template ends in {y}.png, so y doubles as the fill byte.
      cache = TileCache(client: client, cacheDir: temp, maxBytes: 100);
      await cache.fetch(kOsmStandard, const TileCoord(5, 0, 1));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.fetch(kOsmStandard, const TileCoord(5, 0, 2));
      expect(cache.cachedTiles, 1);
      expect(cache.cachedBytes, lessThanOrEqualTo(100));
      // The surviving tile is the newer one.
      final failing = TileCache(
        client: MockClient((_) async => throw http.ClientException('offline')),
        cacheDir: temp,
      );
      expect((await failing.fetch(kOsmStandard, const TileCoord(5, 0, 1))).status,
          TileFetchStatus.missing);
      expect((await failing.fetch(kOsmStandard, const TileCoord(5, 0, 2))).status,
          TileFetchStatus.cacheHit);
    });

    test('oversized tile is served but not stored', () async {
      cache = TileCache(
        client: MockClient((_) async => http.Response.bytes(_bytes(60, 7), 200)),
        cacheDir: temp,
        maxBytes: 10,
      );
      const coord = TileCoord(5, 0, 4);
      final first = await cache.fetch(kOsmStandard, coord);
      expect(first.status, TileFetchStatus.network);
      expect(cache.cachedTiles, 0);
      final failing = TileCache(
        client: MockClient((_) async => throw http.ClientException('offline')),
        cacheDir: temp,
      );
      expect((await failing.fetch(kOsmStandard, coord)).status,
          TileFetchStatus.missing);
    });

    test('invalid coord is missing, never a crash', () async {
      cache = TileCache(client: MockClient((_) async => http.Response.bytes(_tinyPng, 200)), cacheDir: temp);
      final result = await cache.fetch(kOsmStandard, const TileCoord(1, 9, 0));
      expect(result.status, TileFetchStatus.missing);
    });
  });

  group('TileBackgroundPainter', () {
    test('missing tiles paint as a labeled blank grid without throwing', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      TileBackgroundPainter(
        placements: const [
          TilePlacement(
            rect: Rect.fromLTWH(0, 0, 200, 200),
            coord: TileCoord(5, 1, 1),
          ),
        ],
      ).paint(canvas, const Size(200, 200));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
      picture.dispose();
    });

    test('a decoded tile image paints without throwing', () async {
      final codec = await ui.instantiateImageCodec(_tinyPng);
      final frame = await codec.getNextFrame();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      TileBackgroundPainter(
        placements: [
          TilePlacement(
            rect: const Rect.fromLTWH(0, 0, 256, 256),
            coord: const TileCoord(5, 1, 1),
            image: frame.image,
          ),
        ],
      ).paint(canvas, const Size(256, 256));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
      picture.dispose();
      frame.image.dispose();
    });

    test('shouldRepaint tracks placements', () {
      const placement = TilePlacement(
        rect: Rect.fromLTWH(0, 0, 100, 100),
        coord: TileCoord(5, 1, 1),
      );
      final a = TileBackgroundPainter(placements: const [placement]);
      final same = TileBackgroundPainter(placements: const [placement]);
      final different = TileBackgroundPainter(placements: const [
        TilePlacement(
          rect: Rect.fromLTWH(0, 0, 200, 200),
          coord: TileCoord(5, 1, 1),
        ),
      ]);
      expect(a.shouldRepaint(same), isFalse);
      expect(a.shouldRepaint(different), isTrue);
    });
  });
}

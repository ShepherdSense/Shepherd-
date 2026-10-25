/// Offline maps pattern (Shepherd v0.26.0, Fieldwatch-borrow item 5).
///
/// Concept adapted from Fieldwatch (MIT): OpenStreetMap and USGS
/// layers work out of the box, with no account and no key.
///
/// KEYLESS ONLY: the built-in sources are OpenStreetMap Standard,
/// USGS Imagery, and USGS Topo — URL templates only. Esri,
/// MapTiler, Stadia, Thunderforest, and any other keyed provider
/// are NOT built in, and [TileSource.keyless] refuses any template
/// carrying a key/token parameter, so a keyed source cannot slip
/// in silently. No paid dependencies are added.
///
/// OFFLINE BEHAVIOR: [TileCache] is cache-first — a cached tile
/// renders without connectivity. A network refresh that fails
/// falls back to the cached tile and reports it stale. A tile with
/// no cache and no network renders through [TileBackgroundPainter]
/// as an honestly-labeled blank grid — never an invented map.
///
/// Tile math ([latLonToTile], [tileBounds], [tilesForBounds]) is
/// pure Dart Web-Mercator math. The cache uses `http` +
/// `path_provider`; the painter is CustomPaint-compatible, matching
/// the app's existing CustomPaint map rendering. Cache and network
/// errors never throw out of [TileCache.fetch]/[TileCache.refresh]:
/// they degrade to missing/stale results.
///
/// Receive-only. Nothing here transmits anything except the tile
/// HTTP GETs themselves (ordinary map-tile downloads).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// One map tile coordinate (slippy-map scheme).
class TileCoord {
  const TileCoord(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  bool get isValid =>
      z >= 0 &&
      z <= 22 &&
      x >= 0 &&
      y >= 0 &&
      x < (1 << z) &&
      y < (1 << z);

  @override
  bool operator ==(Object other) =>
      other is TileCoord && z == other.z && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// A keyless tile source definition: a URL template plus
/// attribution. Templates use `{z}`, `{x}`, `{y}` placeholders
/// (order is the provider's own; USGS ArcGIS templates use
/// `{z}/{y}/{x}`).
class TileSource {
  TileSource.keyless({
    required this.id,
    required this.displayName,
    required this.urlTemplate,
    required this.attribution,
    this.minZoom = 0,
    this.maxZoom = 19,
  }) {
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError('TileSource id must be [a-z0-9_-]: $id');
    }
    for (final placeholder in ['{z}', '{x}', '{y}']) {
      if (!urlTemplate.contains(placeholder)) {
        throw ArgumentError(
          'TileSource template must contain $placeholder: $urlTemplate',
        );
      }
    }
    final lower = urlTemplate.toLowerCase();
    for (final banned in ['key=', 'api_key', 'apikey', 'access_token', 'token=']) {
      if (lower.contains(banned)) {
        throw ArgumentError(
          'Keyless-only: template must not carry a key parameter ($banned): '
          '$urlTemplate',
        );
      }
    }
  }

  final String id;
  final String displayName;
  final String urlTemplate;
  final String attribution;
  final int minZoom;
  final int maxZoom;

  /// Expands the template for [coord]. Throws [ArgumentError] for
  /// an invalid coordinate or an out-of-range zoom.
  String urlFor(TileCoord coord) {
    if (!coord.isValid) throw ArgumentError('Invalid tile coord: $coord');
    if (coord.z < minZoom || coord.z > maxZoom) {
      throw ArgumentError('Zoom ${coord.z} outside $minZoom..$maxZoom');
    }
    return urlTemplate
        .replaceAll('{z}', coord.z.toString())
        .replaceAll('{x}', coord.x.toString())
        .replaceAll('{y}', coord.y.toString());
  }
}

/// OpenStreetMap Standard layer (keyless, OSM tile usage policy
/// applies to the caller).
final TileSource kOsmStandard = TileSource.keyless(
  id: 'osm_standard',
  displayName: 'OpenStreetMap Standard',
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  attribution: '© OpenStreetMap contributors',
  maxZoom: 19,
);

/// USGS Imagery Only (National Map, keyless ArcGIS tile service).
final TileSource kUsgsImagery = TileSource.keyless(
  id: 'usgs_imagery',
  displayName: 'USGS Imagery',
  urlTemplate:
      'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}',
  attribution: 'USGS National Map',
  maxZoom: 19,
);

/// USGS Topo (National Map, keyless ArcGIS tile service).
final TileSource kUsgsTopo = TileSource.keyless(
  id: 'usgs_topo',
  displayName: 'USGS Topo',
  urlTemplate:
      'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}',
  attribution: 'USGS National Map',
  maxZoom: 19,
);

/// All built-in sources. Keyless only, by construction.
List<TileSource> get defaultTileSources => [kOsmStandard, kUsgsImagery, kUsgsTopo];

/// Default source: OpenStreetMap Standard.
TileSource get defaultTileSource => kOsmStandard;

/// Selects a built-in source by id. Unknown or null ids fall back
/// to the default (fail-safe: never a crash, never a keyed source).
TileSource selectTileSource(String? id) {
  if (id == null) return defaultTileSource;
  for (final source in defaultTileSources) {
    if (source.id == id) return source;
  }
  return defaultTileSource;
}

/// Web-Mercator latitude clamp (tiles are undefined past this).
const double kMaxMercatorLat = 85.05112878;

/// Identifying User-Agent for tile HTTP requests, per the OSM
/// tile usage policy (requests must identify the application).
/// Sent on every fetch/refresh; no contact address is baked in
/// because none is configured for this app — the application name
/// and version are the identification.
const String kTileUserAgent = 'Shepherd/0.26.0 (offline tile cache)';

/// WGS84 -> slippy tile at [zoom]. Pure Dart.
///
/// v0.26.0 fix-pass: zoom is CLAMPED to 0..22 (fail-safe, never
/// throws) — a negative zoom previously fed a negative shift and
/// a huge zoom an overflowing `1 << zoom`, both producing invalid
/// coordinates instead of a usable tile.
TileCoord latLonToTile(double lat, double lon, int zoom) {
  zoom = zoom.clamp(0, 22);
  final clampedLat = lat.clamp(-kMaxMercatorLat, kMaxMercatorLat);
  final clampedLon = lon.clamp(-180.0, 180.0);
  final n = 1 << zoom;
  final x = ((clampedLon + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
  final latRad = clampedLat * math.pi / 180.0;
  final y = ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
              2.0 *
              n)
          .floor()
          .clamp(0, n - 1);
  return TileCoord(zoom, x, y);
}

/// Tile -> WGS84 bounds (north, south, west, east degrees).
({double north, double south, double west, double east}) tileBounds(
  TileCoord coord,
) {
  final n = 1 << coord.z;
  double lon(int x) => x / n * 360.0 - 180.0;
  double lat(int y) {
    final s = math.pi * (1.0 - 2.0 * y / n);
    return math.atan(math.exp(s)) * 180.0 / math.pi * 2.0 - 90.0;
    // Note: atan(sinh(s)) equivalent; exp form avoids a sinh import.
  }

  return (
    north: lat(coord.y),
    south: lat(coord.y + 1),
    west: lon(coord.x),
    east: lon(coord.x + 1),
  );
}

/// All tiles covering a WGS84 bounding box at [zoom]. Empty for an
/// inverted north/south box (fail-safe, never an exception).
/// v0.26.0 fix-pass: west > east is NOT inverted — it is a
/// legitimate antimeridian-crossing box (e.g. west 170, east -170),
/// covered as two ranges, west..180 plus -180..east. Zoom is
/// clamped by [latLonToTile].
List<TileCoord> tilesForBounds(
  double north,
  double south,
  double west,
  double east,
  int zoom,
) {
  if (north < south) return [];
  zoom = zoom.clamp(0, 22);
  final ranges = east < west
      ? [
          (west, 180.0),
          (-180.0, east),
        ]
      : [
          (west, east),
        ];
  final out = <TileCoord>[];
  for (final (w, e) in ranges) {
    final topLeft = latLonToTile(north, w, zoom);
    final bottomRight = latLonToTile(south, e, zoom);
    for (var x = topLeft.x; x <= bottomRight.x; x++) {
      for (var y = topLeft.y; y <= bottomRight.y; y++) {
        final coord = TileCoord(zoom, x, y);
        if (!out.contains(coord)) out.add(coord);
      }
    }
  }
  return out;
}

/// Destination rect for a tile image inside a placement rect:
/// the image's native aspect, centered, fitted inside the rect —
/// never stretched to fill it (v0.26.0 fix-pass: the old painter
/// stretched the origin tile to the full canvas). Pure function
/// so the geometry is unit-testable without a canvas.
Rect tileDestRect(Rect placement, Size imageSize) {
  if (imageSize.width <= 0 || imageSize.height <= 0) return placement;
  final scale = math.min(
    placement.width / imageSize.width,
    placement.height / imageSize.height,
  );
  final w = imageSize.width * scale;
  final h = imageSize.height * scale;
  return Rect.fromLTWH(
    placement.left + (placement.width - w) / 2,
    placement.top + (placement.height - h) / 2,
    w,
    h,
  );
}

enum TileFetchStatus {
  /// Served from the disk cache without a network request.
  cacheHit,

  /// Downloaded from the network and stored in the cache.
  network,

  /// Network failed; a cached tile was served instead (possibly
  /// outdated — the caller should label it stale if it surfaces).
  staleCache,

  /// No cache and no network tile.
  missing,
}

/// Result of a [TileCache] fetch or refresh. Never throws; [bytes]
/// is null exactly when [status] is [TileFetchStatus.missing].
///
/// NOTE (v0.26.0 fix-pass): no tile AGE is carried here, deliberately
/// — the manifest tracks last-USED time for LRU eviction, not
/// download time, so any age derived from it would be a lie (a
/// freshly re-read stale tile would look fresh). Staleness is
/// bounded instead by the Hunt screen's opportunistic refresh on
/// open (see hunt_screen.dart) plus the staleCache status on
/// refresh failure.
class TileFetchResult {
  const TileFetchResult(this.status, this.bytes);

  final TileFetchStatus status;
  final Uint8List? bytes;

  bool get hasBytes => bytes != null;
  bool get isStale => status == TileFetchStatus.staleCache;
}

class _ManifestEntry {
  _ManifestEntry({required this.bytes, required this.lastUsedMs});

  int bytes;
  int lastUsedMs;

  Map<String, Object> toJson() => {'bytes': bytes, 'lastUsedMs': lastUsedMs};

  static _ManifestEntry fromJson(Map<String, Object?> json) => _ManifestEntry(
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        lastUsedMs: (json['lastUsedMs'] as num?)?.toInt() ?? 0,
      );
}

/// Bounded disk cache for map tiles: cache-first, stale-on-error.
///
/// [cacheDir] is injected in tests; in the app it defaults to a
/// `offline_tiles` directory under the application cache directory
/// (via `path_provider`). [maxBytes] bounds total stored bytes;
/// least-recently-used tiles are evicted on insert. A single tile
/// larger than [maxBytes] is served but not stored, so the bound
/// always holds.
class TileCache {
  TileCache({
    http.Client? client,
    Directory? cacheDir,
    Future<Directory> Function()? cacheDirResolver,
    this.maxBytes = 50 * 1024 * 1024,
  })  : _client = client ?? http.Client(),
        _injectedDir = cacheDir,
        _cacheDirResolver = cacheDirResolver;

  final http.Client _client;
  final Directory? _injectedDir;
  final Future<Directory> Function()? _cacheDirResolver;

  /// Default 50 MB bound.
  final int maxBytes;

  Directory? _dir;
  Map<String, _ManifestEntry> _manifest = {};
  bool _initialized = false;

  int get cachedTiles => _manifest.length;

  int get cachedBytes =>
      _manifest.values.fold(0, (sum, entry) => sum + entry.bytes);

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    final base = _injectedDir ??
        await (_cacheDirResolver?.call() ?? getApplicationCacheDirectory());
    _dir = Directory('${base.path}/offline_tiles');
    await _dir!.create(recursive: true);
    await _loadManifest();
    _initialized = true;
  }

  String _key(TileSource source, TileCoord coord) =>
      '${source.id}_${coord.z}_${coord.x}_${coord.y}';

  File _fileFor(String key) => File('${_dir!.path}/$key.bin');

  File get _manifestFile => File('${_dir!.path}/_manifest.json');

  /// Deletes orphaned tile files left behind by a corrupt or
  /// missing manifest index, so the 50 MB bound holds on bytes
  /// actually on disk — not just on bytes the manifest knows
  /// about. v0.26.0 fix-pass: the old corrupt-manifest path reset
  /// the index but left the files, silently breaking the bound.
  Future<void> _deleteOrphanedTileFiles() async {
    try {
      if (_dir == null || !await _dir!.exists()) return;
      await for (final entity in _dir!.list()) {
        if (entity is File && entity.path.endsWith('.bin')) {
          try {
            await entity.delete();
          } catch (_) {
            // Best-effort; a later clear() retries.
          }
        }
      }
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _loadManifest() async {
    try {
      if (!await _manifestFile.exists()) {
        _manifest = {};
        return;
      }
      final decoded = jsonDecode(await _manifestFile.readAsString());
      if (decoded is! Map<String, Object?>) {
        _manifest = {};
        await _deleteOrphanedTileFiles();
        return;
      }
      final parsed = <String, _ManifestEntry>{};
      for (final entry in decoded.entries) {
        if (entry.value is Map<String, Object?>) {
          parsed[entry.key] =
              _ManifestEntry.fromJson(entry.value as Map<String, Object?>);
        }
      }
      _manifest = parsed;
    } catch (_) {
      // Corrupt manifest degrades to an empty index, and orphaned
      // tile files are deleted so the size bound still holds.
      _manifest = {};
      await _deleteOrphanedTileFiles();
    }
  }

  /// Single tile GET with the identifying User-Agent (OSM tile
  /// policy). Shared by fetch and refresh so neither path can
  /// silently drop the header.
  Future<http.Response> _getTile(TileSource source, TileCoord coord) =>
      _client.get(
        Uri.parse(source.urlFor(coord)),
        headers: {'User-Agent': kTileUserAgent},
      );

  Future<void> _saveManifest() async {
    try {
      final json = {
        for (final entry in _manifest.entries) entry.key: entry.value.toJson(),
      };
      await _manifestFile.writeAsString(jsonEncode(json));
    } catch (_) {
      // Best-effort only: losing the manifest costs LRU order, not tiles.
    }
  }

  Future<TileFetchResult?> _readCached(String key) async {
    final entry = _manifest[key];
    if (entry == null) return null;
    try {
      final file = _fileFor(key);
      if (!await file.exists()) {
        _manifest.remove(key);
        return null;
      }
      final bytes = await file.readAsBytes();
      entry.lastUsedMs = DateTime.now().millisecondsSinceEpoch;
      await _saveManifest();
      return TileFetchResult(TileFetchStatus.cacheHit, bytes);
    } catch (_) {
      _manifest.remove(key);
      return null;
    }
  }

  Future<TileFetchResult> _store(
    String key,
    Uint8List bytes,
    TileFetchStatus status,
  ) async {
    if (bytes.length > maxBytes) {
      // Oversized tile: serve it, never store it — the bound holds.
      return TileFetchResult(status, bytes);
    }
    try {
      await _fileFor(key).writeAsBytes(bytes, flush: true);
      _manifest[key] = _ManifestEntry(
        bytes: bytes.length,
        lastUsedMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _evictIfNeeded(exceptKey: key);
      await _saveManifest();
    } catch (_) {
      // Storage failure degrades to serving the bytes uncached.
    }
    return TileFetchResult(status, bytes);
  }

  Future<void> _evictIfNeeded({required String exceptKey}) async {
    var total = cachedBytes;
    if (total <= maxBytes) return;
    final lru = _manifest.entries.toList()
      ..sort((a, b) => a.value.lastUsedMs.compareTo(b.value.lastUsedMs));
    for (final entry in lru) {
      if (total <= maxBytes) break;
      if (entry.key == exceptKey) continue;
      try {
        await _fileFor(entry.key).delete();
      } catch (_) {
        // Already gone; dropping the index entry is enough.
      }
      total -= entry.value.bytes;
      _manifest.remove(entry.key);
    }
  }

  /// Cache-first fetch: cached tile wins without a network request.
  /// On a miss, tries the network once; on network failure returns
  /// [TileFetchStatus.missing]. Never throws.
  Future<TileFetchResult> fetch(TileSource source, TileCoord coord) async {
    try {
      await ensureInitialized();
      if (!coord.isValid) {
        return const TileFetchResult(TileFetchStatus.missing, null);
      }
      final key = _key(source, coord);
      final cached = await _readCached(key);
      if (cached != null) return cached;
      try {
        final response = await _getTile(source, coord);
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          return const TileFetchResult(TileFetchStatus.missing, null);
        }
        return await _store(key, response.bodyBytes, TileFetchStatus.network);
      } catch (_) {
        return const TileFetchResult(TileFetchStatus.missing, null);
      }
    } catch (_) {
      return const TileFetchResult(TileFetchStatus.missing, null);
    }
  }

  /// Network-first refresh: on success stores and returns the fresh
  /// tile; on failure serves the cached tile as
  /// [TileFetchStatus.staleCache], or missing when nothing is cached.
  /// Never throws.
  Future<TileFetchResult> refresh(TileSource source, TileCoord coord) async {
    try {
      await ensureInitialized();
      if (!coord.isValid) {
        return const TileFetchResult(TileFetchStatus.missing, null);
      }
      final key = _key(source, coord);
      try {
        final response = await _getTile(source, coord);
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          throw const HttpException('Tile download failed');
        }
        return await _store(key, response.bodyBytes, TileFetchStatus.network);
      } catch (_) {
        final cached = await _readCached(key);
        if (cached != null) {
          return TileFetchResult(TileFetchStatus.staleCache, cached.bytes);
        }
        return const TileFetchResult(TileFetchStatus.missing, null);
      }
    } catch (_) {
      return const TileFetchResult(TileFetchStatus.missing, null);
    }
  }

  /// Deletes all cached tiles and the manifest. Best-effort.
  Future<void> clear() async {
    try {
      await ensureInitialized();
      if (await _dir!.exists()) {
        await _dir!.delete(recursive: true);
      }
      _manifest = {};
      _initialized = false;
    } catch (_) {
      // Clear failure leaves stale files; a later fetch re-indexes.
    }
  }
}

/// One tile placed on a CustomPaint canvas. The coordinator computes
/// [rect] from its own projector (the same projector the Hunt /
/// phone-tier views already use); this painter only draws. A null
/// [image] means "no cached tile" and renders the honest blank grid.
class TilePlacement {
  const TilePlacement({
    required this.rect,
    required this.coord,
    this.image,
  });

  final Rect rect;
  final TileCoord coord;
  final ui.Image? image;

  @override
  bool operator ==(Object other) =>
      other is TilePlacement &&
      rect == other.rect &&
      coord == other.coord &&
      identical(image, other.image);

  @override
  int get hashCode => Object.hash(rect, coord, image);
}

/// CustomPaint-compatible tile background: draws each placed tile
/// image, and draws missing tiles as a labeled blank grid — never
/// an invented map. Pair with the view's own overlays (Hunt heat
/// cells, phone-tier markers) painted above it.
class TileBackgroundPainter extends CustomPainter {
  TileBackgroundPainter({
    required this.placements,
    this.gridColor = const Color(0xFF3A3A4A),
    this.labelColor = const Color(0xFF9A9AB0),
    this.showMissingLabels = true,
  });

  final List<TilePlacement> placements;
  final Color gridColor;
  final Color labelColor;
  final bool showMissingLabels;

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (final placement in placements) {
      final image = placement.image;
      if (image != null) {
        // Correct aspect, centered, fitted inside the placement
        // rect — never stretched to fill it (v0.26.0 fix-pass).
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          tileDestRect(
            placement.rect,
            Size(image.width.toDouble(), image.height.toDouble()),
          ),
          Paint(),
        );
      } else {
        canvas.drawRect(placement.rect, borderPaint);
        if (showMissingLabels && placement.rect.width > 40) {
          final textPainter = TextPainter(
            text: TextSpan(
              text: 'NO CACHED TILE',
              style: TextStyle(color: labelColor, fontSize: 10),
            ),
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
          )..layout(maxWidth: placement.rect.width);
          final offset = Offset(
            placement.rect.left +
                (placement.rect.width - textPainter.width) / 2,
            placement.rect.top +
                (placement.rect.height - textPainter.height) / 2,
          );
          textPainter.paint(canvas, offset);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant TileBackgroundPainter oldDelegate) {
    if (placements.length != oldDelegate.placements.length) return true;
    for (var i = 0; i < placements.length; i++) {
      if (placements[i] != oldDelegate.placements[i]) return true;
    }
    return gridColor != oldDelegate.gridColor ||
        labelColor != oldDelegate.labelColor ||
        showMissingLabels != oldDelegate.showMissingLabels;
  }
}

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class CachedTileProvider extends TileProvider {
  CachedTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return CachedTileImageProvider(url);
  }
}

class CachedTileImageProvider extends ImageProvider<CachedTileImageProvider> {
  final String url;
  CachedTileImageProvider(this.url);

  @override
  Future<CachedTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedTileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(CachedTileImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedTileImageProvider>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(CachedTileImageProvider key, ImageDecoderCallback decode) async {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      // Sanitize path to be used as a filename
      final path = uri.path.replaceAll('/', '_').replaceAll(RegExp(r'[^\w\.-]'), '_');
      final filename = '${host}_$path';

      final cacheDir = await getTemporaryDirectory();
      final mapCacheDir = Directory('${cacheDir.path}/map_tiles');
      if (!mapCacheDir.existsSync()) {
        mapCacheDir.createSync(recursive: true);
      }
      final file = File('${mapCacheDir.path}/$filename');

      if (file.existsSync() && file.lengthSync() > 0) {
        final bytes = await file.readAsBytes();
        final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      }

      // Download and cache
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        await file.writeAsBytes(bytes);
        final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      }
    } catch (e) {
      debugPrint('Error loading/caching tile $url: $e');
    }

    // Fallback: return transparent 1x1 png to avoid breaking UI/errors
    final transparentBytes = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ]);
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(transparentBytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is CachedTileImageProvider && other.url == url;
  }

  @override
  int get hashCode => url.hashCode;
}

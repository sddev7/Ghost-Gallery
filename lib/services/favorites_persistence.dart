import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FavoritesPersistence {
  static Future<File> _getFavFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/favorites.txt');
  }

  static Future<Set<String>> loadFavorites() async {
    try {
      final file = await _getFavFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        return content.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      }
    } catch (_) {}
    return {};
  }

  static Future<void> saveFavorites(Set<String> favorites) async {
    try {
      final file = await _getFavFile();
      await file.writeAsString(favorites.join('\n'));
    } catch (_) {}
  }
}

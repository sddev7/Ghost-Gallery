import 'dart:io';
import 'package:path_provider/path_provider.dart';

class GridPreferences {
  static Future<File> _getPrefFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/grid_pref.txt');
  }

  static Future<int> loadGridColumns() async {
    try {
      final file = await _getPrefFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        return int.tryParse(content.trim()) ?? 3;
      }
    } catch (_) {}
    return 3; // Default to 3 columns
  }

  static Future<void> saveGridColumns(int columns) async {
    try {
      final file = await _getPrefFile();
      await file.writeAsString(columns.toString());
    } catch (_) {}
  }
}

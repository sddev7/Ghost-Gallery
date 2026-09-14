import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/media_vector.dart';
import '../objectbox.g.dart';

class ObjectBoxService {
  static Store? _store;
  static Box<MediaVector>? _box;

  static Future<Store?> getStore() async {
    if (_store != null) return _store;

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(docsDir.path, "objectbox");

      if (Store.isOpen(dbPath)) {
        debugPrint("ObjectBoxService: Store is already open. Attaching...");
        _store = Store.attach(getObjectBoxModel(), dbPath);
      } else {
        debugPrint("ObjectBoxService: Opening a new Store...");
        _store = await openStore(directory: dbPath);
      }
      
      if (_store != null) {
        _box = Box<MediaVector>(_store!);
      }
      return _store;
    } catch (e) {
      debugPrint("ObjectBoxService: Initialization error: $e");
      return null;
    }
  }

  static Future<Box<MediaVector>?> getBox() async {
    if (_box != null) return _box;
    await getStore();
    return _box;
  }
}

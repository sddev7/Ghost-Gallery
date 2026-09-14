import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'grid_preferences.dart';

class UIPreferenceProvider extends ChangeNotifier {
  static final UIPreferenceProvider instance = UIPreferenceProvider._internal();

  UIPreferenceProvider._internal();

  int _gridColumns = 3;
  String _mapStyleId = 'voyager';
  bool _isInitialized = false;

  int get gridColumns => _gridColumns;
  String get mapStyleId => _mapStyleId;
  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;
    
    // Load grid columns
    _gridColumns = await GridPreferences.loadGridColumns();
    
    // Load map style
    try {
      final prefs = await SharedPreferences.getInstance();
      _mapStyleId = prefs.getString('map_style_id') ?? 'voyager';
    } catch (_) {
      _mapStyleId = 'voyager';
    }
    
    _isInitialized = true;
    notifyListeners();
  }

  Future<void> setGridColumns(int columns) async {
    if (_gridColumns == columns) return;
    _gridColumns = columns;
    notifyListeners();
    await GridPreferences.saveGridColumns(columns);
  }

  Future<void> setMapStyleId(String styleId) async {
    if (_mapStyleId == styleId) return;
    _mapStyleId = styleId;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('map_style_id', styleId);
    } catch (_) {}
  }
}

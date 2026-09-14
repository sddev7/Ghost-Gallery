// ═══════════════════════════════════════════════════════════════════════════
// geocoding_service.dart
//
// Structured reverse geocoding for Ghost Gallery — inspired by Aves'
// AddressDetails model.
//
// Returns rich address fields (countryCode, countryName, adminArea, locality,
// subLocality, featureName) instead of a single opaque string.
//
// Caching strategy:
//   • In-memory session cache keyed by "lat1dp_lng1dp" (1 decimal place ≈ 11 km)
//   • This means all photos taken in the same ~11 km area share one geocoding
//     call — exactly what Aves does to avoid hitting the geocoder on every item.
//   • Cache survives for the lifetime of the app process.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as geo;

// ── Address model ─────────────────────────────────────────────────────────────

class AddressInfo {
  final String? countryCode;   // "IN", "US", "JP"
  final String? countryName;   // "India", "United States"
  final String? adminArea;     // state / province: "Odisha", "California"
  final String? locality;      // city/town: "Sonepur", "San Francisco"
  final String? subLocality;   // neighbourhood: "Connaught Place"
  final String? featureName;   // named place: "India Gate", "Golden Gate Park"
  final String? postalCode;
  final String? thoroughfare;  // street name

  const AddressInfo({
    this.countryCode,
    this.countryName,
    this.adminArea,
    this.locality,
    this.subLocality,
    this.featureName,
    this.postalCode,
    this.thoroughfare,
  });

  // ── Display helpers ─────────────────────────────────────────────────────
  /// "Sonepur, Odisha, IN"
  String get shortString {
    final parts = <String>[];
    final place = locality?.isNotEmpty == true ? locality : subLocality;
    if (place?.isNotEmpty == true)      parts.add(place!);
    if (adminArea?.isNotEmpty == true)  parts.add(adminArea!);
    if (countryCode?.isNotEmpty == true) parts.add(countryCode!);
    return parts.isNotEmpty ? parts.join(', ') : 'Unknown Location';
  }

  /// "Sonepur, Odisha, India"
  String get longString {
    final parts = <String>[];
    if (featureName?.isNotEmpty == true) parts.add(featureName!);
    final place = locality?.isNotEmpty == true ? locality : subLocality;
    if (place?.isNotEmpty == true)      parts.add(place!);
    if (adminArea?.isNotEmpty == true)  parts.add(adminArea!);
    if (countryName?.isNotEmpty == true) parts.add(countryName!);
    return parts.isNotEmpty ? parts.join(', ') : 'Unknown Location';
  }

  /// Returns the most descriptive place name available
  String get placeName =>
      featureName?.isNotEmpty == true ? featureName! :
      locality?.isNotEmpty    == true ? locality! :
      subLocality?.isNotEmpty == true ? subLocality! :
      adminArea?.isNotEmpty   == true ? adminArea! :
      countryName ?? 'Unknown';

  static const AddressInfo empty = AddressInfo();
}

// ── Service ───────────────────────────────────────────────────────────────────

class GhostGeocodingService {
  GhostGeocodingService._();
  static final GhostGeocodingService instance = GhostGeocodingService._();

  // Session cache: "lat1_lng1" → AddressInfo
  final Map<String, AddressInfo> _cache = {};

  /// Reverse-geocode [lat], [lng] to a rich AddressInfo.
  /// Results are cached at 0.1° resolution (~11 km) for the session.
  Future<AddressInfo> reverseGeocode(double lat, double lng) async {
    if (lat == 0.0 && lng == 0.0) return AddressInfo.empty;

    // ── Cache key at ~0.1° resolution ──────────────────────────────────────
    final key = '${(lat * 10).round()}_${(lng * 10).round()}';
    if (_cache.containsKey(key)) return _cache[key]!;

    try {
      final placemarks = await geo.placemarkFromCoordinates(
        lat, lng,
      );
      if (placemarks.isEmpty) {
        _cache[key] = AddressInfo.empty;
        return AddressInfo.empty;
      }
      final pm = placemarks.first;
      final info = AddressInfo(
        countryCode:  pm.isoCountryCode,
        countryName:  pm.country,
        adminArea:    pm.administrativeArea,
        locality:     pm.locality?.isNotEmpty == true
            ? pm.locality
            : pm.subAdministrativeArea,
        subLocality:  pm.subLocality,
        featureName:  pm.name != pm.street ? pm.name : null,
        postalCode:   pm.postalCode,
        thoroughfare: pm.thoroughfare,
      );
      _cache[key] = info;
      return info;
    } catch (e) {
      debugPrint('GhostGeocodingService: error [$lat, $lng] → $e');
      _cache[key] = AddressInfo.empty;
      return AddressInfo.empty;
    }
  }

  /// Batch reverse-geocode a list of (id, lat, lng) tuples.
  /// Respects the cache so already-known positions don't trigger extra calls.
  /// Returns a map of id → AddressInfo.
  Future<Map<String, AddressInfo>> reverseGeocodeAll(
    List<({String id, double lat, double lng})> items,
  ) async {
    final result = <String, AddressInfo>{};
    for (final item in items) {
      result[item.id] = await reverseGeocode(item.lat, item.lng);
    }
    return result;
  }

  void clearCache() => _cache.clear();

  int get cacheSize => _cache.length;
}

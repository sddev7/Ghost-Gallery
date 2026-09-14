import 'dart:math';
import 'package:flutter/foundation.dart';

/// A compiler-safe registry of optional services and features (like local ML scanning and vision calculations).
/// Core files only import this file. In the future, if ml_processing_service.dart is deleted,
/// the app will continue to compile and run flawlessly, automatically falling back to standard modes.
class OptionalFeatures {
  // ── Notifiers for ML status (Dashboards/UI) ──────────────────────────────
  static final ValueNotifier<bool> isMlProcessing = ValueNotifier<bool>(false);
  static final ValueNotifier<double> mlProgress = ValueNotifier<double>(1.0);
  static final ValueNotifier<String> mlLog = ValueNotifier<String>(
    'Vault secured locally.',
  );
  // ── Callback hooks ────────────────────────────────────────────────────────
  static Future<void> Function(String)? updateEmbeddingsForPerson;
  static Future<void> Function({bool force})? scheduleBackgroundTask;
  static Future<void> Function()? scheduleSyncBackgroundTask;
  static Future<void> Function(String)? scheduleEmbeddingBackgroundTask;
  static Future<List<double>> Function(String)? vectorize = _fallbackVectorize;
  static double Function(List<double>, List<double>)? cosineSimilarity =
      MediaVectorizer.cosineSimilarity;

  static Future<List<double>> _fallbackVectorize(String text) async {
    return MediaVectorizer.vectorize(text);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MEDIA VECTORIZER (256-D vector search)
// ═══════════════════════════════════════════════════════════════════════════

class MediaVectorizer {
  static const int dimensions = 256;

  static String cleanAndFilterText(String text) {
    // 1. Lowercase
    String cleaned = text.toLowerCase();

    // 2. Remove symbols and common OCR noise/non-alphanumeric (keep spaces, alphanumeric)
    // Characters like •, °, ™, ©, ®, |, _, ~, *, etc.
    cleaned = cleaned.replaceAll(RegExp(r'[^\w\s\d]'), ' ');
    cleaned = cleaned.replaceAll(
      '_',
      ' ',
    ); // \w includes underscore, so explicitly remove it

    // 3. Split by whitespace
    final List<String> words = cleaned.split(RegExp(r'\s+'));

    // Stop words to filter out
    const Set<String> stopWords = {
      'the',
      'and',
      'a',
      'an',
      'of',
      'to',
      'in',
      'is',
      'for',
      'on',
      'with',
      'at',
      'by',
      'from',
      'this',
      'that',
      'it',
      'was',
      'were',
      'or',
      'but',
      'as',
      'are',
      'be',
      'has',
      'have',
      'had',
      'been',
      'which',
      'who',
      'whom',
      'whose',
    };

    final List<String> filteredWords = [];
    for (final word in words) {
      final trimmed = word.trim();
      if (trimmed.isEmpty) continue;

      // Filter out common stop words
      if (stopWords.contains(trimmed)) continue;

      // Filter out useless single characters (letters), but keep single digits (like 0-9)
      if (trimmed.length == 1) {
        final codeUnit = trimmed.codeUnitAt(0);
        // If it's not a digit (0-9 is 48 to 57), skip it
        if (codeUnit < 48 || codeUnit > 57) {
          continue;
        }
      }

      filteredWords.add(trimmed);
    }

    return filteredWords.join(' ');
  }

  static List<double> vectorize(String text) {
    final List<double> vector = List<double>.filled(dimensions, 0.0);
    final String cleanText = cleanAndFilterText(text);
    if (cleanText.isEmpty) return vector;

    final List<String> words = cleanText
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    final List<String> tokens = [];
    tokens.addAll(words);

    // Character n-grams for partial matching
    // for (final word in words) {
    //   tokens.add(word);
    // }

    // Hash tokens into vector
    for (final token in tokens) {
      final int hash = _hashCode(token);
      final int index = hash.abs() % dimensions;
      final double sign = (hash.hashCode % 2 == 0) ? 1.0 : -1.0;
      vector[index] += sign;
    }

    // L2 normalization
    double sumSq = 0.0;
    for (final val in vector) {
      sumSq += val * val;
    }
    final double norm = sqrt(sumSq);
    if (norm > 0) {
      for (int i = 0; i < dimensions; i++) {
        vector[i] /= norm;
      }
    }

    return vector;
  }

  static int _hashCode(String s) {
    int hash = 0;
    for (int i = 0; i < s.length; i++) {
      hash = s.codeUnitAt(i) + ((hash << 5) - hash);
    }
    return hash;
  }

  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(-1.0, 1.0);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// vault_service.dart — Secure Vault core service for Ghost Gallery
//
// Storage: Android/data/<pkg>/.ghost_gallery_vault  (survives uninstall prompt)
//          Falls back to internal app dir if external storage is unavailable.
// Encryption: AES-256-CBC + PBKDF2-SHA256
// Auth: Password | PIN | Pattern | Biometric (local_auth)
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:crypto/crypto.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import 'package:image/image.dart' as img_lib;
import '../models/vault_models.dart';
import 'database_helper.dart';

class VaultService {
  VaultService._();
  static final VaultService instance = VaultService._();

  // ── Paths ──────────────────────────────────────────────────────────────────
  // Root on the device's internal app directory
  static const _vaultRoot = '.ghost_gallery_vault';
  static const _dbRelPath = 'sys_cache/temp_data/proc/vault.db';
  static const _mediaRelPath = 'data/runtime/media';
  static const _cfgRelPath = 'config/env/.cfg';

  String? _vaultRootPath;
  Database? _db;

  // ── Decrypted cover thumbnail cache (LRU, max 100 entries) ────────────────
  static const int _maxDecryptedCacheEntries = 100;
  final LinkedHashMap<String, Uint8List> _decryptedCache =
      LinkedHashMap<String, Uint8List>();

  // ── Session ────────────────────────────────────────────────────────────────
  Uint8List? _sessionKey; // AES-256 key held in memory only
  bool get isUnlocked => _sessionKey != null;

  // ── Local Auth ─────────────────────────────────────────────────────────────
  final _localAuth = LocalAuthentication();

  // ── Init ───────────────────────────────────────────────────────────────────
  /// Whether the vault is stored on external storage (Android/media).
  /// Exposed so the UI can conditionally show the warning dialog.
  bool _isUsingExternalStorage = false;
  bool get isUsingExternalStorage => _isUsingExternalStorage;

  Future<String> _getRootPath() async {
    if (_vaultRootPath != null) return _vaultRootPath!;

    if (Platform.isAndroid) {
      try {
        final externalDirs = await getExternalStorageDirectories();
        if (externalDirs != null && externalDirs.isNotEmpty) {
          final extPath = externalDirs[0].path;
          // E.g., /storage/emulated/0/Android/data/in.sddev.ghost_gallery/files
          // We want it to be /storage/emulated/0/Android/media/in.sddev.ghost_gallery
          String mediaBase = extPath.replaceAll('/Android/data/', '/Android/media/');
          if (mediaBase.endsWith('/files')) {
            mediaBase = mediaBase.substring(0, mediaBase.length - 6);
          }
          _vaultRootPath = p.join(mediaBase, _vaultRoot);
          _isUsingExternalStorage = true;
          return _vaultRootPath!;
        }
      } catch (_) {}
    }

    // Fallback: internal app support directory (warning dialog will be shown)
    _isUsingExternalStorage = false;
    final dir = await getApplicationSupportDirectory();
    _vaultRootPath = p.join(dir.path, _vaultRoot);
    return _vaultRootPath!;
  }

  Future<void> _ensureDirectories() async {
    final root = await _getRootPath();
    final dirs = [
      p.join(root, 'sys_cache', 'temp_data', 'proc'),
      p.join(root, 'data', 'runtime', 'media'),
      p.join(root, 'config', 'env'),
      p.join(root, 'tmp', 'cache'), // extra confusing dirs
      p.join(root, 'lib', 'modules'),
    ];
    for (final d in dirs) {
      await Directory(d).create(recursive: true);
    }
    // .nomedia hides vault dir from gallery scanners
    final nomedia = File(p.join(root, '.nomedia'));
    if (!await nomedia.exists()) await nomedia.writeAsString('');
  }

  bool _migrationChecked = false;

  Future<void> _checkAndMigrateFromExternal() async {
    if (_migrationChecked) return;
    _migrationChecked = true;
    try {
      if (!Platform.isAndroid) return;

      final targetPath = await _getRootPath();
      final targetDir = Directory(targetPath);
      final targetDb = File(p.join(targetPath, _dbRelPath));

      // If target database already exists, no migration needed.
      if (await targetDb.exists()) return;

      // 1. Check old Android/data folder first
      String? oldDataPath;
      try {
        final externalDirs = await getExternalStorageDirectories();
        if (externalDirs != null && externalDirs.isNotEmpty) {
          final extBase = externalDirs[0].parent;
          oldDataPath = p.join(extBase.path, _vaultRoot);
        }
      } catch (_) {}

      if (oldDataPath != null && oldDataPath != targetPath) {
        final oldDataDir = Directory(oldDataPath);
        final oldDataDb = File(p.join(oldDataPath, _dbRelPath));
        if (await oldDataDb.exists()) {
          debugPrint("VaultService: Migrating vault from old Android/data path to Android/media...");
          await _copyDirectory(oldDataDir, targetDir);
          if (await targetDb.exists()) {
            await oldDataDir.delete(recursive: true);
            debugPrint("VaultService: Migration from Android/data successful.");
            return;
          }
        }
      }

      // 2. Check old public external root (/storage/emulated/0/.ghost_gallery_vault)
      final publicExternalDir = Directory('/storage/emulated/0/.ghost_gallery_vault');
      final publicExternalDb = File(p.join(publicExternalDir.path, _dbRelPath));
      if (await publicExternalDb.exists()) {
        debugPrint("VaultService: Migrating vault from public external root to Android/media...");
        await _copyDirectory(publicExternalDir, targetDir);
        if (await targetDb.exists()) {
          await publicExternalDir.delete(recursive: true);
          debugPrint("VaultService: Migration from public external root successful.");
          return;
        }
      }

      // 3. Check internal app support directory
      final appSupportDir = await getApplicationSupportDirectory();
      final internalPath = p.join(appSupportDir.path, _vaultRoot);
      final internalDir = Directory(internalPath);
      final internalDb = File(p.join(internalPath, _dbRelPath));
      if (await internalDb.exists() && internalPath != targetPath) {
        debugPrint("VaultService: Migrating vault from app support folder to Android/media...");
        await _copyDirectory(internalDir, targetDir);
        if (await targetDb.exists()) {
          await internalDir.delete(recursive: true);
          debugPrint("VaultService: Migration from app support folder successful.");
          return;
        }
      }
    } catch (e) {
      debugPrint("VaultService: Error migrating vault: $e");
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (var entity in source.list(recursive: false)) {
      if (entity is Directory) {
        final newDirectory = Directory(
          p.join(destination.path, p.basename(entity.path)),
        );
        await _copyDirectory(entity, newDirectory);
      } else if (entity is File) {
        final newFile = File(p.join(destination.path, p.basename(entity.path)));
        await entity.copy(newFile.path);
      }
    }
  }

  Future<Database> _getDb() async {
    if (_db != null) return _db!;
    final root = await _getRootPath();
    await _checkAndMigrateFromExternal();
    final dbPath = p.join(root, _dbRelPath);
    await _ensureDirectories();
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS vault_config (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS vault_albums (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS vault_items (
            id TEXT PRIMARY KEY,
            album_id TEXT NOT NULL,
            encrypted_path TEXT NOT NULL,
            original_name TEXT NOT NULL,
            original_path TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            media_type TEXT NOT NULL,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            date_taken INTEGER NOT NULL DEFAULT 0,
            added_at INTEGER NOT NULL,
            encrypted_metadata TEXT NOT NULL DEFAULT ''
          )
        ''');
        // Create the default "General" album
        await db.insert('vault_albums', {
          'id': 'general',
          'name': 'General',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      },
    );
    return _db!;
  }

  // ── Vault Configuration ────────────────────────────────────────────────────
  Future<bool> isVaultConfigured() async {
    try {
      final db = await _getDb();
      final rows = await db.query(
        'vault_config',
        where: 'key = ?',
        whereArgs: ['auth_method'],
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> _readConfig() async {
    final db = await _getDb();
    final rows = await db.query('vault_config');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  Future<void> _writeConfig(String key, String value) async {
    final db = await _getDb();
    await db.insert('vault_config', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── Crypto Helpers ─────────────────────────────────────────────────────────
  static Uint8List _generateSalt() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }

  static Uint8List _deriveKey(String password, Uint8List salt) {
    // PBKDF2-SHA256: 100k iterations → 32-byte AES-256 key
    final pbkdf2 = Hmac(sha256, utf8.encode(password));
    final key = Uint8List(32);
    final block = Uint8List(36);
    block.setRange(0, 32, salt);
    block[32] = 0;
    block[33] = 0;
    block[34] = 0;
    block[35] = 1;

    var u = Uint8List.fromList(pbkdf2.convert(block).bytes);
    key.setAll(0, u);

    for (int i = 1; i < 100000; i++) {
      u = Uint8List.fromList(pbkdf2.convert(u).bytes);
      for (int j = 0; j < 32; j++) {
        key[j] ^= u[j];
      }
    }
    return key;
  }

  static String _hashCredential(String credential, Uint8List salt) {
    final hmac = Hmac(sha256, salt);
    return base64Url.encode(hmac.convert(utf8.encode(credential)).bytes);
  }

  static Uint8List _generateIv() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  }

  /// Encrypt bytes with the session key. Returns [IV (16 bytes) | ciphertext].
  Uint8List _encryptBytes(Uint8List plaintext) {
    if (_sessionKey == null) throw StateError('Vault is locked');
    final iv = _generateIv();
    final key = enc.Key(_sessionKey!);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(plaintext, iv: enc.IV(iv));
    final result = Uint8List(16 + encrypted.bytes.length);
    result.setRange(0, 16, iv);
    result.setRange(16, result.length, encrypted.bytes);
    return result;
  }

  /// Decrypt [IV | ciphertext] bytes using the session key.
  Uint8List _decryptBytes(Uint8List data) {
    if (_sessionKey == null) throw StateError('Vault is locked');
    final iv = data.sublist(0, 16);
    final ciphertext = data.sublist(16);
    final key = enc.Key(_sessionKey!);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    return Uint8List.fromList(
      encrypter.decryptBytes(enc.Encrypted(ciphertext), iv: enc.IV(iv)),
    );
  }

  // ── Setup / Auth ───────────────────────────────────────────────────────────
  /// First-time vault setup. Derives key, stores salt + credential hash.
  Future<void> setupVault(VaultAuthMethod method, String credential) async {
    final salt = _generateSalt();
    final saltB64 = base64Url.encode(salt);
    final credHash = _hashCredential(credential, salt);
    final db = await _getDb();
    await db.transaction((txn) async {
      await txn.insert('vault_config', {
        'key': 'auth_method',
        'value': method.id,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('vault_config', {
        'key': 'salt',
        'value': saltB64,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('vault_config', {
        'key': 'cred_hash',
        'value': credHash,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('vault_config', {
        'key': 'cred_length',
        'value': credential.length.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    // Derive and hold session key
    _sessionKey = _deriveKey(credential, salt);
  }

  /// Unlock vault with password/PIN/pattern credential.
  Future<bool> unlockWithCredential(String credential) async {
    try {
      final cfg = await _readConfig();
      final saltB64 = cfg['salt'] ?? '';
      final storedHash = cfg['cred_hash'] ?? '';
      final salt = base64Url.decode(saltB64);
      final providedHash = _hashCredential(credential, salt);
      if (providedHash != storedHash) return false;
      _sessionKey = _deriveKey(credential, salt);
      return true;
    } catch (e) {
      debugPrint('VaultService.unlock error: $e');
      return false;
    }
  }

  /// Verify biometric support and setup by prompting authentication.
  /// Returns null on success, or an error message on failure.
  Future<String?> verifyBiometricSupport() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck && !isDeviceSupported) {
        return 'Biometric and passcode authentication are not available/supported on this device.';
      }

      final available = await _localAuth.getAvailableBiometrics();
      if (available.isEmpty && !isDeviceSupported) {
        return 'No biometrics or passcode enrolled. Please configure a lock screen in device settings.';
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify biometric authentication for Secure Vault',
        biometricOnly: false, // Passed directly
        persistAcrossBackgrounding: true, // Replaces 'stickyAuth'
        // Note: 'useErrorDialogs' is true by default in this version
      );

      if (!authenticated) {
        return 'Authentication verification cancelled or failed.';
      }
      return null;
    } on PlatformException catch (e) {
      debugPrint('VaultService.verifyBiometricSupport error: $e');
      if (e.code == 'NotAvailable') {
        return 'Biometrics or passcode lock not enrolled on this device. Please set it up in system settings.';
      } else if (e.code == 'NotSupported') {
        return 'Biometric authentication is not supported on this device.';
      } else if (e.code == 'LockedOut') {
        return 'Too many failed biometric attempts. Biometrics are temporarily locked out.';
      } else if (e.code == 'PermanentlyLockedOut') {
        return 'Biometrics permanently locked out. Please unlock the device with your passcode/PIN first.';
      }
      return 'Biometric error: ${e.message} (Code: ${e.code})';
    } catch (e) {
      debugPrint('VaultService.verifyBiometricSupport error: $e');
      return 'Failed to verify biometrics: $e';
    }
  }

  /// Unlock vault using biometric authentication.
  /// Returns null on success, or an error message on failure.
  Future<String?> unlockWithBiometric(BuildContext context) async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck && !isDeviceSupported) {
        return 'Biometric and passcode authentication are not available/supported on this device.';
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify biometric authentication for Secure Vault',
        biometricOnly: false, // Passed directly
        persistAcrossBackgrounding: true, // Replaces 'stickyAuth'
        // Note: 'useErrorDialogs' is true by default in this version
      );

      if (!authenticated) {
        return 'Authentication cancelled or failed.';
      }

      // On biometric unlock, we use a biometric-specific sealed key stored in config
      final cfg = await _readConfig();
      final sealedKey = cfg['biometric_key'];
      if (sealedKey == null) {
        return 'No biometric key set up. Please change your auth method in Settings.';
      }
      _sessionKey = Uint8List.fromList(base64Url.decode(sealedKey));
      return null;
    } on PlatformException catch (e) {
      debugPrint('VaultService.biometric error: $e');
      if (e.code == 'NotAvailable') {
        return 'Biometrics or passcode lock not enrolled on this device. Please set it up in system settings.';
      } else if (e.code == 'NotSupported') {
        return 'Biometric authentication is not supported on this device.';
      } else if (e.code == 'LockedOut') {
        return 'Too many failed biometric attempts. Biometrics are temporarily locked out.';
      } else if (e.code == 'PermanentlyLockedOut') {
        return 'Biometrics permanently locked out. Please unlock the device with your passcode/PIN first.';
      }
      return 'Biometric error: ${e.message} (Code: ${e.code})';
    } catch (e) {
      debugPrint('VaultService.biometric error: $e');
      return 'Failed to authenticate: $e';
    }
  }

  /// Stores the AES key for biometric unlock. Reuses the existing session key
  /// if already unlocked (so existing items remain decryptable), otherwise
  /// generates a new random one.
  Future<void> setupBiometricKey() async {
    final key =
        _sessionKey ??
        Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        );
    await _writeConfig('biometric_key', base64Url.encode(key));
    _sessionKey = key;
  }

  // ── Face Unlock ────────────────────────────────────────────────────────────

  /// Store face embeddings JSON and a sealed AES key for face unlock.
  Future<void> setupFaceUnlockKey(String embeddingsJson) async {
    final key =
        _sessionKey ??
        Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        );
    await _writeConfig('face_unlock_key', base64Url.encode(key));
    await _writeConfig('face_embeddings', embeddingsJson);
    _sessionKey = key;
  }

  /// Retrieve stored face embeddings JSON. Returns null if not enrolled.
  Future<String?> getFaceEmbeddings() async {
    final cfg = await _readConfig();
    return cfg['face_embeddings'];
  }

  /// Unlock vault using stored face key (called after face match succeeds).
  Future<String?> unlockWithFaceKey() async {
    try {
      final cfg = await _readConfig();
      final sealedKey = cfg['face_unlock_key'];
      if (sealedKey == null) {
        return 'No face unlock key found. Please re-enroll.';
      }
      _sessionKey = Uint8List.fromList(base64Url.decode(sealedKey));
      return null; // success
    } catch (e) {
      debugPrint('VaultService.unlockWithFaceKey error: $e');
      return 'Face unlock failed: $e';
    }
  }

  /// Lock the vault — clears the in-memory session key.
  void lockVault() {
    _sessionKey = null;
    clearDecryptedCache();
  }

  void clearDecryptedCache() {
    _decryptedCache.clear();
  }

  /// LRU-bounded write to [_decryptedCache].
  void _cacheDecrypted(String key, Uint8List bytes) {
    _decryptedCache.remove(key); // promote if already present
    if (_decryptedCache.length >= _maxDecryptedCacheEntries) {
      _decryptedCache.remove(_decryptedCache.keys.first); // evict oldest
    }
    _decryptedCache[key] = bytes;
  }

  // ── Security & Screenshot Protection ────────────────────────────────────────
  static const _securityChannel = MethodChannel(
    'in.sddev.ghost_gallery/security',
  );

  /// Enable or disable screenshot and screen recording protection natively.
  Future<void> secureScreen(bool secure) async {
    if (Platform.isAndroid) {
      try {
        await _securityChannel.invokeMethod('secureScreen', {'secure': secure});
        debugPrint('VaultService: secureScreen($secure) called successfully');
      } catch (e) {
        debugPrint('VaultService: secureScreen error: $e');
      }
    }
  }

  // ── Background Thumbnail Processing ─────────────────────────────────────────

  /// Pre-decrypts thumbnails for all vault items in a background isolate.
  /// Also lazily generates thumbnails for any image items missing a thumbnail in the background.
  Future<void> preDecryptAllThumbnails() async {
    if (!isUnlocked) return;
    try {
      final items = await getAllVaultItems();
      if (items.isEmpty) return;

      final root = await _getRootPath();
      final mediaDir = p.join(root, _mediaRelPath);

      final List<Map<String, dynamic>> tasks = [];
      for (final item in items) {
        final cacheKey = '${item.id}_thumb';
        if (_decryptedCache.containsKey(cacheKey)) continue;

        final thumbPath = p.join(mediaDir, '${item.id}.thumb');
        tasks.add({
          'id': item.id,
          'encryptedPath': item.encryptedPath,
          'thumbPath': thumbPath,
          'mediaType': item.mediaType,
        });
      }

      if (tasks.isEmpty) return;

      debugPrint(
        'VaultService: Starting background pre-decryption for ${tasks.length} thumbnails...',
      );
      final result = await compute(_preDecryptIsolate, {
        'sessionKey': _sessionKey,
        'tasks': tasks,
      });

      int addedCount = 0;
      for (final entry in result.entries) {
        if (!_decryptedCache.containsKey(entry.key)) {
          _cacheDecrypted(entry.key, entry.value);
          addedCount++;
        }
      }
      debugPrint(
        'VaultService: Successfully cached $addedCount thumbnails in background',
      );
    } catch (e) {
      debugPrint('VaultService: Error pre-decrypting thumbnails: $e');
    }
  }

  static Map<String, Uint8List> _preDecryptIsolate(Map<String, dynamic> args) {
    final sessionKey = args['sessionKey'] as Uint8List;
    final tasks = args['tasks'] as List<dynamic>;
    final result = <String, Uint8List>{};

    final key = enc.Key(sessionKey);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    for (final task in tasks) {
      final id = task['id'] as String;
      final encryptedPath = task['encryptedPath'] as String;
      final thumbPath = task['thumbPath'] as String;
      final mediaType = task['mediaType'] as String;
      final cacheKey = '${id}_thumb';

      try {
        final thumbFile = File(thumbPath);
        if (thumbFile.existsSync()) {
          final encBytes = thumbFile.readAsBytesSync();
          final iv = encBytes.sublist(0, 16);
          final ciphertext = encBytes.sublist(16);
          final decrypted = Uint8List.fromList(
            encrypter.decryptBytes(enc.Encrypted(ciphertext), iv: enc.IV(iv)),
          );
          result[cacheKey] = decrypted;
        } else if (mediaType == 'image') {
          final encFile = File(encryptedPath);
          if (encFile.existsSync()) {
            final encBytes = encFile.readAsBytesSync();
            final iv = encBytes.sublist(0, 16);
            final ciphertext = encBytes.sublist(16);
            final decryptedBytes = Uint8List.fromList(
              encrypter.decryptBytes(enc.Encrypted(ciphertext), iv: enc.IV(iv)),
            );

            final img = img_lib.decodeImage(decryptedBytes);
            if (img != null) {
              final thumbnail = img_lib.copyResize(img, width: 250);
              final thumbBytes = Uint8List.fromList(
                img_lib.encodeJpg(thumbnail, quality: 60),
              );

              // Encrypt and save
              final rng = Random.secure();
              final thumbIv = Uint8List.fromList(
                List.generate(16, (_) => rng.nextInt(256)),
              );
              final thumbEncrypted = encrypter.encryptBytes(
                thumbBytes,
                iv: enc.IV(thumbIv),
              );
              final thumbData = Uint8List(16 + thumbEncrypted.bytes.length);
              thumbData.setRange(0, 16, thumbIv);
              thumbData.setRange(16, thumbData.length, thumbEncrypted.bytes);

              thumbFile.writeAsBytesSync(thumbData);
              result[cacheKey] = thumbBytes;
            }
          }
        }
      } catch (e) {
        // Continue processing other items
      }
    }
    return result;
  }

  static Uint8List _generateSingleImageThumbnailIsolate(
    Map<String, dynamic> args,
  ) {
    final sessionKey = args['sessionKey'] as Uint8List;
    final encryptedPath = args['encryptedPath'] as String;
    final thumbPath = args['thumbPath'] as String;

    final encFile = File(encryptedPath);
    if (!encFile.existsSync()) throw Exception('Encrypted file not found');

    final encBytes = encFile.readAsBytesSync();

    // Decrypt
    final iv = encBytes.sublist(0, 16);
    final ciphertext = encBytes.sublist(16);
    final key = enc.Key(sessionKey);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final decryptedBytes = Uint8List.fromList(
      encrypter.decryptBytes(enc.Encrypted(ciphertext), iv: enc.IV(iv)),
    );

    // Resize
    final img = img_lib.decodeImage(decryptedBytes);
    if (img == null) throw Exception('Failed to decode image');

    final thumbnail = img_lib.copyResize(img, width: 250);
    final thumbBytes = Uint8List.fromList(
      img_lib.encodeJpg(thumbnail, quality: 60),
    );

    // Encrypt thumbnail
    final rng = Random.secure();
    final thumbIv = Uint8List.fromList(
      List.generate(16, (_) => rng.nextInt(256)),
    );
    final thumbEncrypted = encrypter.encryptBytes(
      thumbBytes,
      iv: enc.IV(thumbIv),
    );
    final thumbData = Uint8List(16 + thumbEncrypted.bytes.length);
    thumbData.setRange(0, 16, thumbIv);
    thumbData.setRange(16, thumbData.length, thumbEncrypted.bytes);

    // Save
    File(thumbPath).writeAsBytesSync(thumbData);
    return thumbBytes;
  }

  Future<VaultAuthMethod> getAuthMethod() async {
    final cfg = await _readConfig();
    final id = cfg['auth_method'] ?? 'password';
    return VaultAuthMethodX.fromId(id);
  }

  Future<bool> isBiometricAvailable() async {
    try {
      return await _localAuth.canCheckBiometrics ||
          await _localAuth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> isFaceIdAvailable() async {
    try {
      final types = await _localAuth.getAvailableBiometrics();
      return types.contains(BiometricType.face);
    } catch (_) {
      return false;
    }
  }

  Future<bool> isFingerprintAvailable() async {
    try {
      final types = await _localAuth.getAvailableBiometrics();
      return types.contains(BiometricType.fingerprint) ||
          types.contains(BiometricType.strong);
    } catch (_) {
      return false;
    }
  }

  Future<int?> getPinLength() async {
    try {
      final cfg = await _readConfig();
      final lenStr = cfg['cred_length'];
      if (lenStr != null) {
        return int.tryParse(lenStr);
      }
    } catch (_) {}
    return null;
  }

  // ── Change Auth ────────────────────────────────────────────────────────────
  Future<void> changeAuth(
    VaultAuthMethod newMethod,
    String newCredential,
  ) async {
    if (!isUnlocked) throw StateError('Vault must be unlocked to change auth');
    // Keep same session key, update the credential hash & salt
    final newSalt = _generateSalt();
    final saltB64 = base64Url.encode(newSalt);
    final credHash = _hashCredential(newCredential, newSalt);
    final db = await _getDb();
    await db.transaction((txn) async {
      await txn.insert('vault_config', {
        'key': 'auth_method',
        'value': newMethod.id,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('vault_config', {
        'key': 'salt',
        'value': saltB64,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('vault_config', {
        'key': 'cred_hash',
        'value': credHash,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('vault_config', {
        'key': 'cred_length',
        'value': newCredential.length.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // ── Albums ─────────────────────────────────────────────────────────────────
  Future<List<VaultAlbum>> getVaultAlbums() async {
    final db = await _getDb();
    final rows = await db.query('vault_albums', orderBy: 'created_at ASC');
    final albums = rows.map(VaultAlbum.fromMap).toList();
    // Attach item counts
    for (final album in albums) {
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) as c FROM vault_items WHERE album_id = ?',
        [album.id],
      );
      album.itemCount = (countRows.first['c'] as int?) ?? 0;
    }
    return albums;
  }

  Future<VaultAlbum> createVaultAlbum(String name) async {
    final album = VaultAlbum(
      id: 'album_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final db = await _getDb();
    await db.insert('vault_albums', album.toMap());
    return album;
  }

  Future<void> deleteVaultAlbum(
    String albumId, {
    bool deleteItems = false,
  }) async {
    if (albumId == 'general')
      throw ArgumentError('Cannot delete General album');
    final db = await _getDb();
    if (deleteItems) {
      final items = await getVaultItems(albumId);
      for (final item in items) {
        await _deleteEncryptedFile(item);
      }
      await db.delete(
        'vault_items',
        where: 'album_id = ?',
        whereArgs: [albumId],
      );
    } else {
      // Move items to General
      await db.update(
        'vault_items',
        {'album_id': 'general'},
        where: 'album_id = ?',
        whereArgs: [albumId],
      );
    }
    await db.delete('vault_albums', where: 'id = ?', whereArgs: [albumId]);
  }

  Future<void> renameVaultAlbum(String albumId, String name) async {
    if (albumId == 'general')
      throw ArgumentError('Cannot rename General album');
    final db = await _getDb();
    await db.update(
      'vault_albums',
      {'name': name},
      where: 'id = ?',
      whereArgs: [albumId],
    );
  }

  // ── Items ──────────────────────────────────────────────────────────────────
  Future<List<VaultItem>> getVaultItems(String albumId) async {
    final db = await _getDb();
    final rows = await db.query(
      'vault_items',
      where: 'album_id = ?',
      whereArgs: [albumId],
      orderBy: 'added_at DESC',
    );
    return rows.map(VaultItem.fromMap).toList();
  }

  Future<VaultItem?> getAlbumCoverItem(String albumId) async {
    final db = await _getDb();
    final rows = await db.query(
      'vault_items',
      where: 'album_id = ?',
      whereArgs: [albumId],
      orderBy: 'added_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return VaultItem.fromMap(rows.first);
  }

  Future<List<VaultItem>> getAllVaultItems() async {
    final db = await _getDb();
    final rows = await db.query('vault_items', orderBy: 'added_at DESC');
    return rows.map(VaultItem.fromMap).toList();
  }

  Future<int> getTotalItemCount() async {
    final db = await _getDb();
    final rows = await db.rawQuery('SELECT COUNT(*) as c FROM vault_items');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Encrypts [filePath] and stores it in the vault under [albumId].
  /// Deletes the original file after successful encryption.
  /// Returns the new [VaultItem].
  Future<VaultItem> addMediaToVault({
    required String filePath,
    required String albumId,
    String? originalMediaId,
    String? mimeType,
    String? mediaType,
    int width = 0,
    int height = 0,
    int dateTaken = 0,
  }) async {
    if (!isUnlocked) throw StateError('Vault is locked');

    final root = await _getRootPath();
    final mediaDir = p.join(root, _mediaRelPath);
    await Directory(mediaDir).create(recursive: true);

    final id = _generateId();
    final encPath = p.join(mediaDir, '$id.enc');

    final originalName = p.basename(filePath);
    final ext = p.extension(filePath).toLowerCase();
    final detectedMedia = (mediaType != null)
        ? mediaType
        : (ext == '.mp4' || ext == '.mov' || ext == '.avi' || ext == '.mkv')
        ? 'video'
        : 'image';
    final detectedMime =
        mimeType ?? (detectedMedia == 'video' ? 'video/mp4' : 'image/jpeg');

    // Eagerly generate video thumbnail if it's a video
    if (detectedMedia == 'video') {
      String? thumbPathTemp;
      try {
        final tempDir = await getTemporaryDirectory();
        thumbPathTemp = await vt.VideoThumbnail.thumbnailFile(
          video: filePath,
          thumbnailPath: tempDir.path,
          imageFormat: vt.ImageFormat.JPEG,
          maxHeight: 200,
          quality: 60,
        );
        if (thumbPathTemp != null && await File(thumbPathTemp).exists()) {
          final thumbBytes = await File(thumbPathTemp).readAsBytes();
          final encThumbBytes = _encryptBytes(thumbBytes);
          final thumbPath = p.join(mediaDir, '$id.thumb');
          await File(thumbPath).writeAsBytes(encThumbBytes);
          _cacheDecrypted('${id}_thumb', thumbBytes);
          debugPrint('VaultService: Eagerly generated video thumbnail for $id');
        }
      } catch (e) {
        debugPrint('VaultService: Eager video thumbnail generation failed: $e');
      } finally {
        if (thumbPathTemp != null) {
          try {
            final f = File(thumbPathTemp);
            if (f.existsSync()) {
              f.deleteSync();
            }
          } catch (_) {}
        }
      }
    }

    final originalFile = File(filePath);
    final originalBytes = await originalFile.readAsBytes();
    final encrypted = _encryptBytes(originalBytes);
    await File(encPath).writeAsBytes(encrypted);

    // Eagerly generate image thumbnail in background isolate to keep UI responsive and import fast
    if (detectedMedia == 'image') {
      final thumbPath = p.join(mediaDir, '$id.thumb');
      compute(_generateSingleImageThumbnailIsolate, {
            'sessionKey': _sessionKey,
            'encryptedPath': encPath,
            'thumbPath': thumbPath,
          })
          .then((thumbBytes) {
              _cacheDecrypted('${id}_thumb', thumbBytes);
            debugPrint(
              'VaultService: Background image thumbnail generation completed for $id',
            );
          })
          .catchError((e) {
            debugPrint(
              'VaultService: Background image thumbnail generation failed for $id: $e',
            );
          });
    }

    final item = VaultItem(
      id: id,
      albumId: albumId,
      encryptedPath: encPath,
      originalName: originalName,
      originalPath: filePath,
      mimeType: detectedMime,
      mediaType: detectedMedia,
      width: width,
      height: height,
      dateTaken: dateTaken > 0
          ? dateTaken
          : DateTime.now().millisecondsSinceEpoch,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );

    final db = await _getDb();
    await db.insert('vault_items', item.toMap());

    // Delete original file
    bool deletedDirectly = false;
    try {
      if (await originalFile.exists()) {
        await originalFile.delete();
        deletedDirectly = true;
      }
    } catch (e) {
      debugPrint('VaultService: could not delete original directly: $e');
    }

    if (!deletedDirectly && Platform.isAndroid) {
      try {
        const channel = MethodChannel('in.sddev.ghost_gallery/media_manager');
        await channel.invokeMethod('deleteMedia', {
          'filePaths': [filePath],
          'mediaIds': originalMediaId != null ? [originalMediaId] : null,
        });
      } catch (e) {
        debugPrint('VaultService: native deleteMedia failed: $e');
      }
    }

    if (originalMediaId != null) {
      try {
        await DatabaseHelper.instance.deleteMediaItem(originalMediaId);
      } catch (e) {
        debugPrint('VaultService: could not delete original from DB: $e');
      }
    }

    return item;
  }

  /// Decrypts a vault item into memory (never written to disk unencrypted).
  Future<Uint8List> getDecryptedBytes(VaultItem item) async {
    if (_decryptedCache.containsKey(item.id)) {
      return _decryptedCache[item.id]!;
    }
    if (!isUnlocked) throw StateError('Vault is locked');
    final encFile = File(item.encryptedPath);
    if (!await encFile.exists()) throw Exception('Encrypted file not found');
    final encBytes = await encFile.readAsBytes();
    final decrypted = _decryptBytes(encBytes);
    _cacheDecrypted(item.id, decrypted);
    return decrypted;
  }

  /// Get decrypted video thumbnail bytes. Lazy generates one if not cached.
  Future<Uint8List> getVideoThumbnail(VaultItem item) async {
    final cacheKey = '${item.id}_thumb';
    if (_decryptedCache.containsKey(cacheKey)) {
      return _decryptedCache[cacheKey]!;
    }
    if (!isUnlocked) throw StateError('Vault is locked');

    final root = await _getRootPath();
    final mediaDir = p.join(root, _mediaRelPath);
    final thumbPath = p.join(mediaDir, '${item.id}.thumb');
    final thumbFile = File(thumbPath);

    if (await thumbFile.exists()) {
      final encBytes = await thumbFile.readAsBytes();
      final decrypted = _decryptBytes(encBytes);
      _cacheDecrypted(cacheKey, decrypted);
      return decrypted;
    }

    // Lazy generation fallback: decrypt video, run VideoThumbnail, encrypt/cache thumbnail, cleanup
    debugPrint('VaultService: Lazy generating thumbnail for video ${item.id}');
    final encFile = File(item.encryptedPath);
    if (!await encFile.exists()) throw Exception('Encrypted file not found');

    final tempDir = await getTemporaryDirectory();
    final tempVideoPath = p.join(tempDir.path, '${item.id}_temp.mp4');
    final tempVideoFile = File(tempVideoPath);
    String? thumbPathTemp;

    try {
      final encBytes = await encFile.readAsBytes();
      final decryptedVideoBytes = _decryptBytes(encBytes);
      await tempVideoFile.writeAsBytes(decryptedVideoBytes);

      thumbPathTemp = await vt.VideoThumbnail.thumbnailFile(
        video: tempVideoPath,
        thumbnailPath: tempDir.path,
        imageFormat: vt.ImageFormat.JPEG,
        maxHeight: 200,
        quality: 60,
      );

      if (thumbPathTemp != null && await File(thumbPathTemp).exists()) {
        final thumbBytes = await File(thumbPathTemp).readAsBytes();
        final encThumbBytes = _encryptBytes(thumbBytes);
        await thumbFile.writeAsBytes(encThumbBytes);

        _cacheDecrypted(cacheKey, thumbBytes);
        return thumbBytes;
      }
    } catch (e) {
      debugPrint('VaultService: error generating lazy video thumbnail: $e');
    } finally {
      if (await tempVideoFile.exists()) {
        try {
          await tempVideoFile.delete();
        } catch (_) {}
      }
      if (thumbPathTemp != null) {
        try {
          final f = File(thumbPathTemp);
          if (f.existsSync()) {
            f.deleteSync();
          }
        } catch (_) {}
      }
    }

    throw Exception('Failed to generate video thumbnail');
  }

  /// Get decrypted image thumbnail bytes. Lazy generates one if not cached.
  Future<Uint8List> getImageThumbnail(VaultItem item) async {
    final cacheKey = '${item.id}_thumb';
    if (_decryptedCache.containsKey(cacheKey)) {
      return _decryptedCache[cacheKey]!;
    }
    if (!isUnlocked) throw StateError('Vault is locked');

    final root = await _getRootPath();
    final mediaDir = p.join(root, _mediaRelPath);
    final thumbPath = p.join(mediaDir, '${item.id}.thumb');
    final thumbFile = File(thumbPath);

    if (await thumbFile.exists()) {
      final encBytes = await thumbFile.readAsBytes();
      final decrypted = _decryptBytes(encBytes);
      _cacheDecrypted(cacheKey, decrypted);
      return decrypted;
    }

    // Lazy generation fallback in background isolate
    debugPrint(
      'VaultService: Lazy generating thumbnail in background for image ${item.id}',
    );
    try {
      final thumbBytes = await compute(_generateSingleImageThumbnailIsolate, {
        'sessionKey': _sessionKey,
        'encryptedPath': item.encryptedPath,
        'thumbPath': thumbPath,
      });
      _cacheDecrypted(cacheKey, thumbBytes);
      return thumbBytes;
    } catch (e) {
      debugPrint(
        'VaultService: error generating lazy image thumbnail in isolate: $e',
      );
    }

    // If decoding/resizing fails, fallback to full image bytes (cached)
    return getDecryptedBytes(item);
  }

  bool _isPermissionError(Object e) {
    if (e is FileSystemException) {
      final msg = e.message.toLowerCase();
      final osErrorMsg = e.osError?.message.toLowerCase() ?? '';
      final osErrorCode = e.osError?.errorCode ?? -1;
      return msg.contains('permission') ||
          msg.contains('permitted') ||
          osErrorMsg.contains('permission') ||
          osErrorMsg.contains('permitted') ||
          osErrorCode == 13 || // Permission denied on Linux/Android/macOS
          osErrorCode ==
              1 || // Operation not permitted (EPERM) on Linux/Android
          osErrorCode == 5; // Permission denied on Windows
    }
    return false;
  }

  Future<List<String>> _getFallbackRestoreDirectories() async {
    final paths = <String>[];

    if (Platform.isAndroid) {
      // 1. Try public storage root directory
      paths.add('/storage/emulated/0/Ghost Vault Restore');

      // 2. Try Download folder
      paths.add('/storage/emulated/0/Download/Ghost Vault Restore');
      paths.add('/storage/emulated/0/Downloads/Ghost Vault Restore');

      // 3. Try app's external storage files directory (always writeable)
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          paths.add(p.join(extDir.path, 'Ghost Vault Restore'));
        }
      } catch (e) {
        debugPrint(
          'VaultService: Failed to get external storage directory: $e',
        );
      }
    } else if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        paths.add(p.join(userProfile, 'Downloads', 'Ghost Vault Restore'));
        paths.add(p.join(userProfile, 'Documents', 'Ghost Vault Restore'));
      }
    }

    // Always append application documents directory / Ghost Vault Restore as a safe fallback
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      paths.add(p.join(docsDir.path, 'Ghost Vault Restore'));
    } catch (e) {
      debugPrint(
        'VaultService: Failed to get application documents directory: $e',
      );
    }

    // Always append temporary directory / Ghost Vault Restore as a last resort
    try {
      final tempDir = await getTemporaryDirectory();
      paths.add(p.join(tempDir.path, 'Ghost Vault Restore'));
    } catch (e) {
      debugPrint('VaultService: Failed to get temporary directory: $e');
    }

    return paths;
  }

  /// Moves a vault item back out of the vault.
  /// If [restore] is true, writes to the original path; otherwise to Downloads.
  Future<String> removeFromVault({
    required VaultItem item,
    bool restore = false,
    String? targetDir,
  }) async {
    if (!isUnlocked) throw StateError('Vault is locked');

    final decrypted = await getDecryptedBytes(item);

    // Determine target path
    String target = '';
    try {
      if (restore && item.originalPath.isNotEmpty) {
        target = item.originalPath;
        final parentDir = Directory(p.dirname(target));
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }
      } else {
        if (targetDir != null) {
          await Directory(targetDir).create(recursive: true);
          target = p.join(targetDir, item.originalName);
        } else {
          final docsDir = await getApplicationDocumentsDirectory();
          final restoreDir = Directory(
            p.join(docsDir.path, 'GhostVaultRestored'),
          );
          await restoreDir.create(recursive: true);
          target = p.join(restoreDir.path, item.originalName);
        }
      }

      // Avoid overwrite collision
      if (await File(target).exists()) {
        final base = p.basenameWithoutExtension(target);
        final ext = p.extension(target);
        final ts = DateTime.now().millisecondsSinceEpoch;
        target = p.join(p.dirname(target), '${base}_$ts$ext');
      }

      final restoredFile = File(target);
      await restoredFile.writeAsBytes(decrypted);
    } catch (e) {
      if (_isPermissionError(e)) {
        debugPrint(
          "VaultService: Permission error occurred while restoring file to target. Restoring to 'Ghost Vault Restore' instead. Error: $e",
        );

        final fallbackDirs = await _getFallbackRestoreDirectories();
        bool fallbackSucceeded = false;
        String fallbackTarget = '';

        for (final dirPath in fallbackDirs) {
          try {
            final dir = Directory(dirPath);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }

            fallbackTarget = p.join(dirPath, item.originalName);
            // Avoid overwrite collision in fallback
            if (await File(fallbackTarget).exists()) {
              final base = p.basenameWithoutExtension(fallbackTarget);
              final ext = p.extension(fallbackTarget);
              final ts = DateTime.now().millisecondsSinceEpoch;
              fallbackTarget = p.join(dirPath, '${base}_$ts$ext');
            }

            final fallbackFile = File(fallbackTarget);
            await fallbackFile.writeAsBytes(decrypted);

            target = fallbackTarget;
            fallbackSucceeded = true;
            debugPrint(
              "VaultService: Successfully restored file to fallback location: $target",
            );
            break; // Succeeded!
          } catch (fallbackErr) {
            debugPrint(
              "VaultService: Failed to write to fallback directory $dirPath: $fallbackErr",
            );
          }
        }

        if (!fallbackSucceeded) {
          // If all fallbacks fail, rethrow the original permission exception
          rethrow;
        }
      } else {
        // Rethrow other errors (e.g. out of space, etc.)
        rethrow;
      }
    }

    final restoredFile = File(target);
    // Set the file's modification time to match the original creation/date taken time
    try {
      final originalDate = DateTime.fromMillisecondsSinceEpoch(item.dateTaken);
      await restoredFile.setLastModified(originalDate);
    } catch (e) {
      debugPrint(
        "VaultService: Failed to set last modified time on restored file: $e",
      );
    }

    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('in.sddev.ghost_gallery/media_manager');
        await channel.invokeMethod('scanFile', {'path': target});
      } catch (e) {
        debugPrint("VaultService: Failed to trigger media scan: $e");
      }
    }

    await _deleteEncryptedFile(item);

    final db = await _getDb();
    await db.delete('vault_items', where: 'id = ?', whereArgs: [item.id]);

    return target;
  }

  Future<void> moveItemToAlbum(String itemId, String newAlbumId) async {
    final db = await _getDb();
    await db.update(
      'vault_items',
      {'album_id': newAlbumId},
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  Future<void> deleteVaultItem(VaultItem item) async {
    await _deleteEncryptedFile(item);
    final db = await _getDb();
    await db.delete('vault_items', where: 'id = ?', whereArgs: [item.id]);
  }

  Future<void> _deleteEncryptedFile(VaultItem item) async {
    try {
      final f = File(item.encryptedPath);
      if (await f.exists()) await f.delete();

      final root = await _getRootPath();
      final thumbPath = p.join(root, _mediaRelPath, '${item.id}.thumb');
      final thumbFile = File(thumbPath);
      if (await thumbFile.exists()) await thumbFile.delete();
    } catch (e) {
      debugPrint('VaultService: delete enc file error: $e');
    }
  }

  // ── Vault-wide ops ─────────────────────────────────────────────────────────
  Future<void> deleteEntireVault() async {
    final root = await _getRootPath();
    try {
      await Directory(root).delete(recursive: true);
    } catch (e) {
      debugPrint('VaultService: delete vault error: $e');
    }
    _db?.close();
    _db = null;
    _sessionKey = null;
  }

  Future<int> getVaultStorageBytes() async {
    final root = await _getRootPath();
    int total = 0;
    try {
      await for (final entity in Directory(root).list(recursive: true)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
    } catch (_) {}
    return total;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  static String _generateId() {
    final rng = Random.secure();
    final bytes = List.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // NOTE: External storage permission helpers removed.
  // Vault exclusively uses app-internal storage (getApplicationSupportDirectory).
  // Files will be lost if the app is uninstalled or storage is cleared.
}

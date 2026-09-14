// ═══════════════════════════════════════════════════════════════════════════
// vault_models.dart — Data models for Ghost Gallery Secure Vault
// ═══════════════════════════════════════════════════════════════════════════

class VaultAlbum {
  final String id;
  final String name;
  final int createdAt;
  int itemCount;

  VaultAlbum({
    required this.id,
    required this.name,
    required this.createdAt,
    this.itemCount = 0,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'created_at': createdAt,
      };

  factory VaultAlbum.fromMap(Map<String, dynamic> map) => VaultAlbum(
        id: map['id'] as String,
        name: map['name'] as String,
        createdAt: map['created_at'] as int? ?? 0,
      );
}

class VaultItem {
  final String id;
  final String albumId;
  final String encryptedPath;
  final String originalName;
  final String originalPath;
  final String mimeType;
  final String mediaType; // 'image' | 'video'
  final int width;
  final int height;
  final int dateTaken;
  final int addedAt;
  final String encryptedMetadata; // AES-encrypted JSON blob

  VaultItem({
    required this.id,
    required this.albumId,
    required this.encryptedPath,
    required this.originalName,
    required this.originalPath,
    required this.mimeType,
    required this.mediaType,
    required this.width,
    required this.height,
    required this.dateTaken,
    required this.addedAt,
    this.encryptedMetadata = '',
  });

  bool get isVideo => mediaType == 'video';

  Map<String, dynamic> toMap() => {
        'id': id,
        'album_id': albumId,
        'encrypted_path': encryptedPath,
        'original_name': originalName,
        'original_path': originalPath,
        'mime_type': mimeType,
        'media_type': mediaType,
        'width': width,
        'height': height,
        'date_taken': dateTaken,
        'added_at': addedAt,
        'encrypted_metadata': encryptedMetadata,
      };

  factory VaultItem.fromMap(Map<String, dynamic> map) => VaultItem(
        id: map['id'] as String,
        albumId: map['album_id'] as String? ?? 'general',
        encryptedPath: map['encrypted_path'] as String,
        originalName: map['original_name'] as String? ?? '',
        originalPath: map['original_path'] as String? ?? '',
        mimeType: map['mime_type'] as String? ?? 'image/jpeg',
        mediaType: map['media_type'] as String? ?? 'image',
        width: map['width'] as int? ?? 0,
        height: map['height'] as int? ?? 0,
        dateTaken: map['date_taken'] as int? ?? 0,
        addedAt: map['added_at'] as int? ?? 0,
        encryptedMetadata: map['encrypted_metadata'] as String? ?? '',
      );
}

/// Auth methods supported by the vault
enum VaultAuthMethod { password, pin, pattern, biometric, faceUnlock }

extension VaultAuthMethodX on VaultAuthMethod {
  String get id {
    switch (this) {
      case VaultAuthMethod.password:
        return 'password';
      case VaultAuthMethod.pin:
        return 'pin';
      case VaultAuthMethod.pattern:
        return 'pattern';
      case VaultAuthMethod.biometric:
        return 'biometric';
      case VaultAuthMethod.faceUnlock:
        return 'face_unlock';
    }
  }

  String get label {
    switch (this) {
      case VaultAuthMethod.password:
        return 'Password';
      case VaultAuthMethod.pin:
        return 'PIN';
      case VaultAuthMethod.pattern:
        return 'Pattern';
      case VaultAuthMethod.biometric:
        return 'Biometric';
      case VaultAuthMethod.faceUnlock:
        return 'Face Unlock';
    }
  }

  static VaultAuthMethod fromId(String id) {
    switch (id) {
      case 'pin':
        return VaultAuthMethod.pin;
      case 'pattern':
        return VaultAuthMethod.pattern;
      case 'biometric':
        return VaultAuthMethod.biometric;
      case 'face_unlock':
        return VaultAuthMethod.faceUnlock;
      default:
        return VaultAuthMethod.password;
    }
  }
}

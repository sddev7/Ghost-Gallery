import 'dart:io';
import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import 'trash_persistence.dart';
import '../screens/vault/vault_unlock_screen.dart';
import '../screens/vault/vault_setup_screen.dart';
import 'vault_service.dart';
import '../models/vault_models.dart';

/// Handles the mandatory MANAGE_MEDIA permission flow for Android 11+.
///
/// The permission is REQUIRED before any soft-delete (rename to .trashed-…).
/// The dialog loops indefinitely — it cannot be skipped or dismissed.
/// The user MUST grant MANAGE_MEDIA via Settings before the delete proceeds.
class MediaPermissionService {
  /// Ensures MANAGE_MEDIA is granted, looping until it is.
  ///
  /// - On Android < 31, returns true immediately (system handles it).
  /// - On non-Android, returns true immediately.
  /// - Otherwise shows a non-dismissible dialog pointing to Settings,
  ///   then re-checks after the user returns. Repeats until granted.
  static Future<bool> ensureManageMediaPermission(
      BuildContext context) async {
    if (!Platform.isAndroid) return true;

    while (true) {
      final granted = await TrashPersistence.hasManageMediaPermission();
      if (granted) return true;
      if (!context.mounted) return false;

      // Show mandatory dialog — user cannot dismiss it without going to Settings
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const _ManageMediaDialog(),
      );

      // After dialog closes (user tapped "Open Settings" and came back),
      // loop re-checks. If still not granted, dialog shows again.
    }
  }

  /// Performs a soft-delete for [items] after ensuring MANAGE_MEDIA permission.
  ///
  /// For native media files this REQUIRES the permission — the loop will keep
  /// re-showing the dialog until the user grants it.
  /// For local sandbox files (captured_/imported_/win_) no permission is
  /// needed and the rename proceeds immediately.
  static Future<void> softDeleteWithPermission(
    BuildContext context,
    List<GalleryItem> items,
  ) async {
    if (items.isEmpty) return;

    // Only require MANAGE_MEDIA if there are native device media items
    final hasNative = items.any((i) => !_isLocal(i.id));
    if (hasNative && Platform.isAndroid) {
      final granted = await ensureManageMediaPermission(context);
      if (!granted) return; // context unmounted — abort
    }

    // Permission confirmed — show batch progress dialog!
    await showBatchProgressDialog<void>(
      context: context,
      title: "Moving to Trash",
      totalCount: items.length,
      action: (onProgress) => TrashPersistence.softDeleteAll(
        items,
        context: context,
        onProgress: onProgress,
    ));
  }

  /// Secure [items] in the vault. Prompts for setup if vault is not configured,
  /// unlocks the vault if locked, and requests manage media permission on Android
  /// if native files are selected before transferring files to the vault.
  static Future<void> secureMediaWithPermission(
    BuildContext context,
    List<GalleryItem> items,
    VoidCallback onSuccess,
  ) async {                       
    if (items.isEmpty) return;

    // 1. Check if Vault is configured
    final isConfigured = await VaultService.instance.isVaultConfigured();
    if (!isConfigured) {
      final setup = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Setup Secure Vault'),
          content: const Text('You need to setup a password or biometric lock to use the Secure Vault. Setup now?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Setup', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      if (setup == true) {
        if (!context.mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const VaultSetupScreen()),
        );
      }
      return;
    }

    // Lock the vault first to force authentication challenge, just like photo_viewer_screen.dart does
    VaultService.instance.lockVault();

    // 2. Ensure vault is unlocked
    if (!context.mounted) return;
    final bool? unlockRes = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (ctx) => VaultUnlockScreen(
          onUnlockSuccess: () {
            Navigator.pop(ctx, true);
          },
        ),
      ),
    );
    if (unlockRes != true) return; // failed to unlock

    if (!context.mounted) return;

    // Show album selection dialog, just like photo_viewer_screen.dart does
    final selectedAlbumId = await _showVaultAlbumSelectionDialog(context);
    if (selectedAlbumId == null) return; // cancelled selection

    if (!context.mounted) return;

    // Only require MANAGE_MEDIA if there are native device media items
    final hasNative = items.any((i) => !_isLocal(i.id));
    if (hasNative && Platform.isAndroid) {
      final granted = await ensureManageMediaPermission(context);
      if (!granted) return; // context unmounted — abort
    }

    // 3. Perform moving/encrypting in a batch progress dialog
    await showBatchProgressDialog<void>(
      context: context,
      title: "Securing Media Files",
      totalCount: items.length,
      action: (onProgress) async {
        for (int i = 0; i < items.length; i++) {
          final item = items[i];
          try {
            await VaultService.instance.addMediaToVault(
              filePath: item.imageUrl,
              albumId: selectedAlbumId,
              originalMediaId: item.id,
              mimeType: item.mimeType ?? (item.imageUrl.endsWith('.mp4') || item.imageUrl.endsWith('.mov') || item.imageUrl.endsWith('.avi') || item.imageUrl.endsWith('.mkv') ? 'video/mp4' : 'image/jpeg'),
              mediaType: item.mediaType,
              width: item.width,
              height: item.height,
              dateTaken: item.dateTimestamp,
            );
          } catch (e) {
            debugPrint("Error securing item ${item.id}: $e");
          }
          onProgress(i + 1, items.length);
        }
      },
    );
    VaultService.instance.lockVault();


    onSuccess();
  }

  static Future<String?> _showVaultAlbumSelectionDialog(
    BuildContext context,
  ) async {
    final albums = await VaultService.instance.getVaultAlbums();
    if (!context.mounted) return null;

    String? selectedAlbumId = 'general';

    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final dialogTheme = Theme.of(context);
          return AlertDialog(
            backgroundColor: dialogTheme.dialogBackgroundColor,
            title: Text(
              'Secure to Vault',
              style: TextStyle(color: dialogTheme.colorScheme.onSurface, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select a Vault album to encrypt and hide these files.',
                  style: TextStyle(color: dialogTheme.colorScheme.onSurface.withValues(alpha: 0.7), fontSize: 13),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedAlbumId,
                  dropdownColor: dialogTheme.cardColor,
                  style: TextStyle(color: dialogTheme.colorScheme.onSurface),
                  decoration: InputDecoration(
                    labelText: 'Vault Album',
                    labelStyle: TextStyle(color: dialogTheme.colorScheme.primary),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: dialogTheme.dividerColor),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: dialogTheme.colorScheme.primary),
                    ),
                  ),
                  items: albums
                      .map(
                        (a) => DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            a.name,
                            style: TextStyle(color: dialogTheme.colorScheme.onSurface),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    setDialogState(() {
                      selectedAlbumId = val;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  icon: Icon(
                    Icons.add_circle_outline,
                    color: dialogTheme.colorScheme.secondary,
                  ),
                  label: Text(
                    'Create New Album',
                    style: TextStyle(color: dialogTheme.colorScheme.secondary),
                  ),
                  onPressed: () async {
                    final nameController = TextEditingController();
                    final newAlbum = await showDialog<VaultAlbum>(
                      context: context,
                      builder: (context) {
                        final innerTheme = Theme.of(context);
                        return AlertDialog(
                          backgroundColor: innerTheme.dialogBackgroundColor,
                          title: Text(
                            'New Vault Album',
                            style: TextStyle(color: innerTheme.colorScheme.onSurface, fontWeight: FontWeight.bold),
                          ),
                          content: TextField(
                            controller: nameController,
                            style: TextStyle(color: innerTheme.colorScheme.onSurface),
                            decoration: InputDecoration(
                              labelText: 'Album Name',
                              labelStyle: TextStyle(color: innerTheme.colorScheme.primary),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                'Cancel',
                                style: TextStyle(color: innerTheme.colorScheme.onSurface.withValues(alpha: 0.6)),
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                if (nameController.text.isNotEmpty) {
                                  final album = await VaultService.instance
                                      .createVaultAlbum(nameController.text);
                                  Navigator.pop(context, album);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: innerTheme.colorScheme.primary,
                                foregroundColor: innerTheme.colorScheme.onPrimary,
                              ),
                              child: const Text('Create'),
                            ),
                          ],
                        );
                      },
                    );
                    if (newAlbum != null) {
                      final updatedAlbums = await VaultService.instance
                          .getVaultAlbums();
                      setDialogState(() {
                        albums.clear();
                        albums.addAll(updatedAlbums);
                        selectedAlbumId = newAlbum.id;
                      });
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: dialogTheme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context, selectedAlbumId);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: dialogTheme.colorScheme.primary,
                  foregroundColor: dialogTheme.colorScheme.onPrimary,
                ),
                child: const Text('Secure'),
              ),
            ],
          );
        },
      ),
    );
  }

  static bool _isLocal(String id) =>
      id.startsWith('win_') ||
      id.startsWith('imported_') ||
      id.startsWith('captured_');

  /// Displays a beautiful premium linear progress dialog during bulk operations.
  static Future<T> showBatchProgressDialog<T>({
    required BuildContext context,
    required String title,
    required int totalCount,
    required Future<T> Function(void Function(int processed, int total) onProgress) action,
  }) async {
    final progressNotifier = ValueNotifier<int>(0);

    final dialogRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final cardColor = isDark ? Colors.grey[900]! : Colors.white;
        final textColor = isDark ? Colors.white : Colors.black87;
        final subtextColor = isDark ? Colors.grey[400]! : Colors.grey[600]!;
        final accentColor = Theme.of(ctx).colorScheme.primary;

        return ValueListenableBuilder<int>(
          valueListenable: progressNotifier,
          builder: (context, processed, child) {
            final double percent = totalCount > 0 ? processed / totalCount : 0.0;
            return Dialog(
              backgroundColor: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 20),
                    LinearProgressIndicator(
                      value: percent,
                      backgroundColor: isDark ? Colors.grey[800] : Colors.grey[200],
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Processing $processed of $totalCount…",
                          style: TextStyle(
                            color: subtextColor,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          "${(percent * 100).toInt()}%",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: textColor,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    Navigator.of(context).push(dialogRoute);

    try {
      final T result = await action((processed, total) {
        progressNotifier.value = processed;
      });
      return result;
    } finally {
      if (dialogRoute.isActive) {
        Navigator.of(context).removeRoute(dialogRoute);
      }
    }
  }
}

// ── Mandatory Permission Dialog ───────────────────────────────────────────────
//
// Non-dismissible: no back button, no barrier tap, only "Open Settings".
// After the user grants permission in Settings and returns, the calling loop
// re-checks and either exits (granted) or shows the dialog again (not granted).
// ─────────────────────────────────────────────────────────────────────────────

class _ManageMediaDialog extends StatefulWidget {
  const _ManageMediaDialog();

  @override
  State<_ManageMediaDialog> createState() => _ManageMediaDialogState();
}

class _ManageMediaDialogState extends State<_ManageMediaDialog>
    with WidgetsBindingObserver {
  bool _waitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Called when the app resumes (user came back from Settings).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForSettings) {
      _waitingForSettings = false;
      // Close this dialog — the loop in ensureManageMediaPermission will
      // re-check and either exit or re-show the dialog.
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _openSettings() async {
    _waitingForSettings = true;
    await TrashPersistence.openManageMediaSettings();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF0F0F18) : Colors.white;
    final textColor = isDark ? const Color(0xFFCDCDCD) : Colors.black87;
    final subtextColor = isDark ? Colors.grey[400]! : Colors.black54;
    final buttonColor = isDark ? const Color(0xFFCC0000) : const Color(0xFF1565C0);

    // Intercept back button — do not allow dismissal
    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: cardColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Media Management Access Required',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? const Color(0xFFCC0000) : Colors.black87,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'To delete, rename, or move media files to the trash without displaying individual confirmation system popups for every single file, this app requires the Media Management permission.',
                style: TextStyle(
                  fontSize: 14,
                  color: textColor,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Please click "Grant Permission" below, which will open the system settings, then toggle "Allow app to manage media".',
                style: TextStyle(
                  fontSize: 13,
                  color: subtextColor,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _waitingForSettings ? null : _openSettings,
                    child: Text(
                      _waitingForSettings ? 'Waiting…' : 'Grant Permission',
                      style: TextStyle(
                        color: buttonColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

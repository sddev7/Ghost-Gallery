import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/vault_models.dart';
import '../../services/vault_service.dart';
import '../../widgets/pattern_lock.dart';
import 'face_camera_screen.dart';
import '../../services/entitlement_service.dart';
import '../../services/responsive_helper.dart';

class VaultSettingsScreen extends StatefulWidget {
  const VaultSettingsScreen({super.key});
  @override
  State<VaultSettingsScreen> createState() => _VaultSettingsScreenState();
}

class _VaultSettingsScreenState extends State<VaultSettingsScreen> {
  VaultAuthMethod _authMethod = VaultAuthMethod.password;
  bool _biometricAvailable = false;
  bool _isLoading = true;
  String _vaultSize = '0 B';
  int _vaultCount = 0;

  Color get _primary => Theme.of(context).colorScheme.primary;
  Color get _accent => Theme.of(context).colorScheme.secondary;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _card => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final method = await VaultService.instance.getAuthMethod();
    final bioAvail = await VaultService.instance.isBiometricAvailable();
    final count = await VaultService.instance.getTotalItemCount();
    final sizeBytes = await VaultService.instance.getVaultStorageBytes();
    setState(() {
      _authMethod = method;
      _biometricAvailable = bioAvail;
      _vaultCount = count;
      _vaultSize = _formatBytes(sizeBytes);
      _isLoading = false;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  IconData _authIcon(VaultAuthMethod m) {
    switch (m) {
      case VaultAuthMethod.pin: return Icons.dialpad_rounded;
      case VaultAuthMethod.password: return Icons.lock_rounded;
      case VaultAuthMethod.pattern: return Icons.pattern;
      case VaultAuthMethod.biometric: return Icons.fingerprint;
      case VaultAuthMethod.faceUnlock: return Icons.face_retouching_natural;
    }
  }

  Future<void> _changeAuthMethod() async {
    final chosen = await showModalBottomSheet<VaultAuthMethod>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AuthMethodSheet(
        current: _authMethod,
        biometricAvailable: _biometricAvailable,
      ),
    );
    if (chosen == null) return;
    if (chosen == VaultAuthMethod.biometric) {
      await _enrollBiometricInSettings();
    } else if (chosen == VaultAuthMethod.faceUnlock) {
      await _enrollFaceUnlockInSettings();
    } else {
      await _promptNewCredential(chosen);
    }
  }

  Future<void> _enrollBiometricInSettings() async {
    setState(() => _isLoading = true);
    final error = await VaultService.instance.verifyBiometricSupport();
    if (error != null) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
        );
      }
      return;
    }
    await VaultService.instance.setupBiometricKey();
    await VaultService.instance.changeAuth(VaultAuthMethod.biometric, 'biometric_secured');
    await _loadSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Biometric authentication enabled!')),
      );
    }
  }

  Future<void> _enrollFaceUnlockInSettings() async {
    final result = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => const FaceCameraScreen(mode: FaceCameraMode.enrollment),
      ),
    );
    if (result == null || !mounted) return; // user cancelled

    setState(() => _isLoading = true);
    try {
      await VaultService.instance.setupFaceUnlockKey(result);
      await VaultService.instance
          .changeAuth(VaultAuthMethod.faceUnlock, 'face_unlock_secured');
      await _loadSettings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Face Unlock enabled!')),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Face enrollment failed: $e'),
              backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _promptNewCredential(VaultAuthMethod method) async {
    // Pattern needs a full-screen page
    if (method == VaultAuthMethod.pattern) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _ChangePatternScreen(
            onSave: (cred) async {
              await VaultService.instance.changeAuth(method, cred);
              _loadSettings();
            },
          ),
        ),
      );
    } else {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ChangeCredentialDialog(
          method: method,
          textColor: _text,
          primaryColor: _primary,
          accentColor: _accent,
          cardColor: _card,
          onSave: (cred) async {
            await VaultService.instance.changeAuth(method, cred);
            _loadSettings();
          },
        ),
      );
    }
  }

  Future<void> _deleteEntireVault() async {
    final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text('Wipe Vault?', style: TextStyle(color: _text, fontWeight: FontWeight.bold)),
            content: Text(
              'This will permanently delete ALL encrypted files, albums, and settings. This CANNOT be undone.',
              style: TextStyle(color: _text.withValues(alpha: 0.7)),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: _text.withValues(alpha: 0.54)))),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                child: const Text('Wipe All'),
              ),
            ],
          ),
        ) ?? false;

    if (confirm) {
      setState(() => _isLoading = true);
      await VaultService.instance.deleteEntireVault();
      if (mounted) {
        Navigator.pop(context);
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWatch = context.isWatch;
    final horizPadding = isWatch ? 8.0 : (context.isTablet || context.isTV ? 24.0 : 16.0);

    return Scaffold(
      backgroundColor: _bg,
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: _primary))
          : CustomScrollView(
              slivers: [
                _buildSliverHeader(),
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(horizPadding, 0, horizPadding, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 20),
                            _buildSectionLabel('SECURITY'),
                            const SizedBox(height: 8),
                            _buildAuthCard(),
                            const SizedBox(height: 20),
                            _buildSectionLabel('VAULT DATA'),
                            const SizedBox(height: 8),
                            _buildDataCard(),
                            const SizedBox(height: 20),
                            _buildSectionLabel('DANGER ZONE'),
                            const SizedBox(height: 8),
                            _buildDangerCard(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSliverHeader() {
    final isWatch = context.isWatch;
    return SliverAppBar(
      expandedHeight: isWatch ? 120 : 200,
      pinned: true,
      backgroundColor: _bg,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, color: _text.withValues(alpha: 0.8)),
        onPressed: () => Navigator.pop(context),
      ),
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.parallax,
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [_primary.withValues(alpha: 0.85), _accent.withValues(alpha: 0.7)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: isWatch ? 8 : 32),
                Container(
                  padding: EdgeInsets.all(isWatch ? 8 : 14),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.15),
                    border: Border.all(color: Colors.white24, width: 1.5),
                  ),
                  child: Icon(_authIcon(_authMethod), size: isWatch ? 22 : 36, color: Colors.white),
                ),
                SizedBox(height: isWatch ? 6 : 12),
                Text('Vault Settings', style: TextStyle(color: Colors.white, fontSize: isWatch ? 16 : 22, fontWeight: FontWeight.bold)),
                if (!isWatch) ...[
                  const SizedBox(height: 4),
                  Text('Secured with ${_authMethod.label}', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(label, style: TextStyle(color: _text.withValues(alpha: 0.38), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2));
  }

  Widget _buildAuthCard() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: _accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.security_rounded, color: _accent, size: 22),
        ),
        title: Text('Unlock Method', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
        subtitle: Text(_authMethod.label, style: TextStyle(color: _text.withValues(alpha: 0.54), fontSize: 13)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('Change', style: TextStyle(color: _primary, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        onTap: _changeAuthMethod,
      ),
    );
  }

  Widget _buildDataCard() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: _buildStatPill(Icons.photo_library_rounded, '$_vaultCount', 'Items', _primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatPill(Icons.storage_rounded, _vaultSize, 'Used', _accent),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: _text.withValues(alpha: 0.08)),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.blueGrey.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.lock_clock_rounded, color: Colors.blueGrey, size: 22),
            ),
            title: const Text('Encryption', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('AES-256-CBC + PBKDF2', style: TextStyle(fontSize: 12)),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
              child: const Text('Active', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatPill(IconData icon, String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
              Text(label, style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDangerCard() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.2)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 22),
        ),
        title: const Text('Wipe Vault Data', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
        subtitle: Text('Permanently delete all encrypted files', style: TextStyle(color: _text.withValues(alpha: 0.38), fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: Colors.redAccent),
        onTap: _deleteEntireVault,
      ),
    );
  }
}

// ─── Auth Method Picker Bottom Sheet ──────────────────────────────────────────
class _AuthMethodSheet extends StatelessWidget {
  final VaultAuthMethod current;
  final bool biometricAvailable;
  const _AuthMethodSheet({required this.current, required this.biometricAvailable});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final accent = Theme.of(context).colorScheme.secondary;
    final text = Theme.of(context).colorScheme.onSurface;
    final card = Theme.of(context).cardColor;

    final methods = [
      (VaultAuthMethod.pin, Icons.dialpad_rounded, 'PIN Code', '4-8 digit numeric code'),
      (VaultAuthMethod.password, Icons.lock_rounded, 'Password', 'Alphanumeric password'),
      (VaultAuthMethod.pattern, Icons.pattern, 'Pattern', 'Draw on a 3×3 grid'),
      if (biometricAvailable)
        (VaultAuthMethod.biometric, Icons.fingerprint, 'Biometric', 'Fingerprint'),
      (VaultAuthMethod.faceUnlock, Icons.face_retouching_natural, 'Face Unlock', 'ML-powered face recognition'),
    ];

    final status = EntitlementService.instance.statusNotifier.value;
    final isPremium = status == EntitlementStatus.subscribed ||
        status == EntitlementStatus.trialRunning;

    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: text.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Change Unlock Method', style: TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          ...methods.map((m) {
            final isActive = m.$1 == current;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isActive ? primary.withValues(alpha: 0.15) : text.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(m.$2, color: isActive ? accent : text.withValues(alpha: 0.6), size: 22),
              ),
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(m.$3, style: TextStyle(color: text, fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                ],
              ),
              subtitle: Text(m.$4, style: TextStyle(color: text.withValues(alpha: 0.45), fontSize: 12)),
              trailing: isActive ? Icon(Icons.check_circle_rounded, color: accent) : null,
              onTap: () {
                Navigator.pop(context, m.$1);
              },
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Change Password / PIN Credential Dialog ───────────────────────────────────
class _ChangeCredentialDialog extends StatefulWidget {
  final VaultAuthMethod method;
  final Color textColor, primaryColor, accentColor, cardColor;
  final Future<void> Function(String cred) onSave;

  const _ChangeCredentialDialog({
    required this.method, required this.textColor,
    required this.primaryColor, required this.accentColor,
    required this.cardColor, required this.onSave,
  });

  @override
  State<_ChangeCredentialDialog> createState() => _ChangeCredentialDialogState();
}

class _ChangeCredentialDialogState extends State<_ChangeCredentialDialog> {
  int _stage = 0;
  String _enteredCred = '';
  String _errorMessage = '';
  final _textController = TextEditingController();

  @override
  void dispose() { _textController.dispose(); super.dispose(); }

  bool get _isPin => widget.method == VaultAuthMethod.pin;

  void _handleContinue() {
    final val = _textController.text;
    if (_isPin) {
      if (val.length < 4) { setState(() => _errorMessage = 'PIN must be 4–8 digits'); return; }
    } else {
      if (val.isEmpty) { setState(() => _errorMessage = 'Password cannot be empty'); return; }
    }
    setState(() { _enteredCred = val; _textController.clear(); _stage = 1; _errorMessage = ''; });
  }

  Future<void> _handleSave() async {
    final confirm = _textController.text;
    if (_isPin) {
      if (confirm.length < 4) { setState(() => _errorMessage = 'PIN must be 4–8 digits'); return; }
    } else {
      if (confirm.isEmpty) { setState(() => _errorMessage = 'Please confirm your password'); return; }
    }
    if (_enteredCred != confirm) {
      setState(() { _errorMessage = 'Does not match. Try again.'; _stage = 0; _enteredCred = ''; _textController.clear(); });
      return;
    }
    try {
      await widget.onSave(_enteredCred);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _errorMessage = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWatch = context.isWatch;
    final title = _stage == 0 ? 'New ${widget.method.label}' : 'Confirm ${widget.method.label}';
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(title, style: TextStyle(color: widget.textColor, fontSize: isWatch ? 15 : 18, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: SizedBox(
          width: isWatch ? 220 : 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isPin) ...[
                Text('Enter ${_stage == 0 ? "new" : "same"} PIN (4–8 digits)',
                    style: TextStyle(color: widget.textColor.withValues(alpha: 0.6), fontSize: isWatch ? 11 : 13)),
                SizedBox(height: isWatch ? 10 : 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(8, (i) {
                    final active = i < _textController.text.length;
                    return Container(
                      margin: EdgeInsets.symmetric(horizontal: isWatch ? 2 : 3),
                      width: isWatch ? 7 : 10,
                      height: isWatch ? 7 : 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? widget.primaryColor : widget.textColor.withValues(alpha: 0.12),
                      ),
                    );
                  }),
                ),
                SizedBox(height: isWatch ? 12 : 20),
                _buildKeypad(),
              ] else ...[
                TextField(
                  controller: _textController,
                  obscureText: true,
                  style: TextStyle(color: widget.textColor),
                  decoration: InputDecoration(
                    labelText: _stage == 0 ? 'New Password' : 'Confirm Password',
                    labelStyle: TextStyle(color: widget.textColor.withValues(alpha: 0.5)),
                    prefixIcon: Icon(Icons.lock_outline, color: widget.textColor.withValues(alpha: 0.5)),
                  ),
                ),
              ],
              if (_errorMessage.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_errorMessage, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: widget.textColor.withValues(alpha: 0.5)))),
        ElevatedButton(
          onPressed: _stage == 0 ? _handleContinue : _handleSave,
          style: ElevatedButton.styleFrom(backgroundColor: widget.primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: Text(_stage == 0 ? 'Continue' : 'Save'),
        ),
      ],
    );
  }

  Widget _buildKeypad() {
    final isWatch = context.isWatch;
    return Wrap(
      spacing: isWatch ? 6 : 10,
      runSpacing: isWatch ? 6 : 10,
      alignment: WrapAlignment.center,
      children: [
        for (int i = 1; i <= 9; i++) _keyBtn(i.toString()),
        _keyBtn('C', color: Colors.redAccent),
        _keyBtn('0'),
        _keyBtn('⌫', color: Colors.orangeAccent),
      ],
    );
  }

  Widget _keyBtn(String label, {Color? color}) {
    final isWatch = context.isWatch;
    final btnSize = isWatch ? 44.0 : 60.0;
    return SizedBox(
      width: btnSize,
      height: btnSize,
      child: OutlinedButton(
        onPressed: () {
          HapticFeedback.lightImpact();
          setState(() {
            _errorMessage = '';
            if (label == 'C') { _textController.clear(); }
            else if (label == '⌫') { final t = _textController.text; if (t.isNotEmpty) _textController.text = t.substring(0, t.length - 1); }
            else if (_textController.text.length < 8) { _textController.text += label; }
          });
        },
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          side: BorderSide(color: color ?? widget.textColor.withValues(alpha: 0.15)),
          backgroundColor: color != null ? color.withValues(alpha: 0.08) : widget.cardColor,
          foregroundColor: color ?? widget.textColor,
          padding: EdgeInsets.zero,
        ),
        child: Text(label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color ?? widget.textColor)),
      ),
    );
  }
}

// ─── Full-Screen Pattern Change Screen ────────────────────────────────────────
class _ChangePatternScreen extends StatefulWidget {
  final Future<void> Function(String cred) onSave;
  const _ChangePatternScreen({required this.onSave});
  @override
  State<_ChangePatternScreen> createState() => _ChangePatternScreenState();
}

class _ChangePatternScreenState extends State<_ChangePatternScreen> {
  int _stage = 0; // 0 = enter, 1 = confirm
  List<int> _first = [];
  List<int> _confirm = [];
  String _error = '';
  bool _saving = false;

  Color get _primary => Theme.of(context).colorScheme.primary;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _card => Theme.of(context).cardColor;

  Future<void> _handleNext() async {
    if (_stage == 0) {
      if (_first.length < 4) { setState(() => _error = 'Connect at least 4 dots'); return; }
      setState(() { _stage = 1; _error = ''; });
    } else {
      if (_confirm.length < 4) { setState(() => _error = 'Connect at least 4 dots'); return; }
      if (_first.join(',') != _confirm.join(',')) {
        setState(() { _stage = 0; _error = "Patterns don't match. Draw again."; _first = []; _confirm = []; });
        return;
      }
      setState(() => _saving = true);
      try {
        await widget.onSave(_first.join(','));
        if (mounted) Navigator.pop(context);
      } catch (e) {
        setState(() { _saving = false; _error = 'Error saving: $e'; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: _text.withValues(alpha: 0.7)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_stage == 0 ? 'Draw New Pattern' : 'Confirm Pattern',
            style: TextStyle(color: _text, fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                _stage == 0 ? 'Connect at least 4 dots to set your pattern.' : 'Draw the same pattern again to confirm.',
                style: TextStyle(color: _text.withValues(alpha: 0.6), fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: PatternLock(
                      key: ValueKey(_stage),
                      onSelect: (_) {},
                      onComplete: (pts) => setState(() {
                        if (_stage == 0) {
                          _first = pts;
                        } else {
                          _confirm = pts;
                        }
                        _error = pts.length < 4 ? 'Connect at least 4 dots' : '';
                      }),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_error.isNotEmpty)
                Text(_error, style: const TextStyle(color: Colors.redAccent, fontSize: 14), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              _saving
                  ? CircularProgressIndicator(color: _primary)
                  : ElevatedButton(
                      onPressed: _handleNext,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text(_stage == 0 ? 'Continue' : 'Save Pattern',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

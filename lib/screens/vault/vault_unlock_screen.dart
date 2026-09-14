import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/vault_models.dart';
import '../../services/vault_service.dart';
import '../../widgets/pattern_lock.dart';
import 'face_camera_screen.dart';
import 'vault_setup_screen.dart';
import '../../services/responsive_helper.dart';

class VaultUnlockScreen extends StatefulWidget {
  final VoidCallback onUnlockSuccess;
  const VaultUnlockScreen({super.key, required this.onUnlockSuccess});

  @override
  State<VaultUnlockScreen> createState() => _VaultUnlockScreenState();
}

class _VaultUnlockScreenState extends State<VaultUnlockScreen>
    with SingleTickerProviderStateMixin {
  VaultAuthMethod _authMethod = VaultAuthMethod.password;
  bool _isLoading = true;
  bool _isUnlocking = false; // overlay spinner instead of replacing scaffold
  String _errorMessage = '';
  final _credController = TextEditingController();
  List<int> _patternPoints = [];
  int _patternResetCounter = 0;
  int? _pinLength;
  bool _obscurePassword = true;
  int _failedAttempts = 0;
  static const int _maxFailedAttempts = 7;

  // Shake animation for error
  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  Color get _primaryColor => Theme.of(context).colorScheme.primary;
  Color get _accentColor => Theme.of(context).colorScheme.secondary;
  Color get _bgColor => Theme.of(context).scaffoldBackgroundColor;
  Color get _cardColor => Theme.of(context).cardColor;
  Color get _textColor => Theme.of(context).colorScheme.onSurface;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10, end: -6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6, end: 0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut));

    // Clear error on new typing
    _credController.addListener(_onCredChanged);
    _loadAuthMethodAndTriggerBiometrics();
  }

  void _onCredChanged() {
    if (_errorMessage.isNotEmpty) {
      setState(() => _errorMessage = '');
    }
  }

  @override
  void dispose() {
    _credController.removeListener(_onCredChanged);
    _credController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _loadAuthMethodAndTriggerBiometrics() async {
    setState(() => _isLoading = true);
    final isConfigured = await VaultService.instance.isVaultConfigured();
    if (!isConfigured) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const VaultSetupScreen()),
        );
      }
      return;
    }

    final method = await VaultService.instance.getAuthMethod();
    final pinLen = await VaultService.instance.getPinLength();
    setState(() {
      _authMethod = method;
      _pinLength = pinLen;
      _isLoading = false;
    });

    if (method == VaultAuthMethod.biometric) {
      _triggerBiometricUnlock();
    } else if (method == VaultAuthMethod.faceUnlock) {
      _triggerFaceUnlock();
    }
  }

  Future<void> _triggerBiometricUnlock() async {
    final error = await VaultService.instance.unlockWithBiometric(context);
    if (error == null) {
      widget.onUnlockSuccess();
    } else {
      setState(() {
        _errorMessage = error;
      });
    }
  }

  Future<void> _triggerFaceUnlock() async {
    final embJson = await VaultService.instance.getFaceEmbeddings();
    if (embJson == null || !mounted) {
      setState(() {
        _errorMessage = 'No face enrolled. Re-enroll in Settings.';
      });
      return;
    }
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => FaceCameraScreen(
          mode: FaceCameraMode.unlock,
          storedEmbeddingsJson: embJson,
        ),
      ),
    );
    if (!mounted) return;
    if (result == true) {
      final err = await VaultService.instance.unlockWithFaceKey();
      if (err == null) {
        widget.onUnlockSuccess();
      } else {
        setState(() {
          _errorMessage = err;
        });
      }
    } else {
      setState(() {
        _errorMessage = 'Face verification cancelled or failed.';
      });
    }
  }

  void _triggerShake() {
    _shakeController.reset();
    _shakeController.forward();
  }

  void _handleFailedAttempt(String message) {
    _failedAttempts++;
    setState(() {
      _errorMessage = _failedAttempts >= _maxFailedAttempts
          ? 'Too many failed attempts ($_failedAttempts). Consider resetting.'
          : message;
      _credController.clear();
      _patternPoints.clear();
    });
    _triggerShake();
  }

  Future<void> _handleUnlock() async {
    final cred = _authMethod == VaultAuthMethod.pattern
        ? _patternPoints.join(',')
        : _credController.text;

    if (cred.isEmpty) {
      setState(() => _errorMessage = 'Please input security lock code');
      _triggerShake();
      return;
    }

    setState(() => _isUnlocking = true);
    final success = await VaultService.instance.unlockWithCredential(cred);
    if (!mounted) return;
    setState(() => _isUnlocking = false);

    if (success) {
      widget.onUnlockSuccess();
    } else {
      _handleFailedAttempt('Incorrect ${_authMethod.label}. Try again.');
    }
  }

  Future<void> _checkPinUnlockAutomatic() async {
    final pin = _credController.text;

    // Fix: Only auto-check when pin length is known
    if (_pinLength == null) return; // will use confirm button instead

    if (pin.length != _pinLength) return;

    setState(() => _isUnlocking = true);
    final success = await VaultService.instance.unlockWithCredential(pin);
    if (!mounted) return;
    setState(() => _isUnlocking = false);

    if (success) {
      widget.onUnlockSuccess();
    } else {
      _handleFailedAttempt('Incorrect PIN. Try again.');
    }
  }

  Future<void> _handlePatternUnlockAutomatic(List<int> points) async {
    final cred = points.join(',');
    setState(() => _isUnlocking = true);
    final success = await VaultService.instance.unlockWithCredential(cred);
    if (!mounted) return;
    setState(() => _isUnlocking = false);

    if (success) {
      widget.onUnlockSuccess();
    } else {
      _handleFailedAttempt('Incorrect pattern. Try again.');
      setState(() => _patternResetCounter++);
    }
  }

  Future<void> _showForceResetDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
          const SizedBox(width: 10),
          Text('Force Reset Vault',
              style: TextStyle(
                  color: _textColor, fontWeight: FontWeight.bold, fontSize: 18)),
        ]),
        content: Text(
          '⚠ This will PERMANENTLY DELETE all vault data — including all encrypted files, albums, and configuration.\n\n'
          'This action CANNOT be undone. Your vault files are NOT recoverable.\n\n'
          'Are you absolutely sure?',
          style: TextStyle(
              color: _textColor.withValues(alpha: 0.8), height: 1.5, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: _textColor.withValues(alpha: 0.6))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Delete Everything',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isLoading = true);
      await VaultService.instance.deleteEntireVault();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const VaultSetupScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: _bgColor,
        body: Center(
          child: CircularProgressIndicator(color: _primaryColor),
        ),
      );
    }

    // Determine which input method to show
    final showBiometricUI = _authMethod == VaultAuthMethod.biometric;
    final showFaceUI = _authMethod == VaultAuthMethod.faceUnlock;

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Unlock Vault',
            style: TextStyle(
                color: _textColor.withValues(alpha: 0.7),
                fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(
                    horizontal: context.isWatch ? 12.0 : 24.0,
                    vertical: context.isWatch ? 8.0 : 16.0,
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                  // ── Gradient lock circle (matches setup screen) ──
                  Container(
                    height: 80,
                    width: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [_primaryColor, _accentColor],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _primaryColor.withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      showBiometricUI
                          ? Icons.fingerprint
                          : showFaceUI
                              ? Icons.face_retouching_natural
                              : _authMethod == VaultAuthMethod.pattern
                                  ? Icons.pattern
                                  : _authMethod == VaultAuthMethod.pin
                                      ? Icons.dialpad_rounded
                                      : Icons.lock_open_rounded,
                      size: 38,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    showBiometricUI
                        ? 'Biometric Unlock'
                        : showFaceUI
                            ? 'Face Unlock'
                            : 'Enter ${_authMethod.label}',
                    style: TextStyle(
                        color: _textColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    showFaceUI
                        ? 'Scanning your face…'
                        : 'Vault is encrypted. Unlock using your ${showBiometricUI ? "biometrics" : _authMethod.label}.',
                    style: TextStyle(
                        color: _textColor.withValues(alpha: 0.54), fontSize: 12),
                    textAlign: TextAlign.center,
                  ),

                  // ── Animated error message with shake ──
                  AnimatedBuilder(
                    animation: _shakeAnimation,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(_shakeAnimation.value, 0),
                      child: child,
                    ),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _errorMessage.isNotEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.redAccent.withValues(alpha: 0.3)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.error_outline,
                                        color: Colors.redAccent, size: 16),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        _errorMessage,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.redAccent,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Input area ──
                  if (showFaceUI)
                    _buildFaceUnlockPrompt()
                  else if (showBiometricUI)
                    _buildBiometricPrompt()
                  else if (_authMethod == VaultAuthMethod.password)
                    _buildPasswordInput()
                  else if (_authMethod == VaultAuthMethod.pin)
                    _buildPinInput()
                  else if (_authMethod == VaultAuthMethod.pattern)
                    _buildPatternInput(),

                  const SizedBox(height: 20),

                  // ── Unlock button for password (and PIN when length unknown) ──
                  if (_authMethod == VaultAuthMethod.password ||
                      (_authMethod == VaultAuthMethod.pin && _pinLength == null))
                    Container(
                      width: double.infinity,
                      height: 54,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          colors: [_primaryColor, _accentColor],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _primaryColor.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _isUnlocking ? null : _handleUnlock,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 54),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Unlock Vault',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),

                  // ── Biometric / Face Buttons ──
                  if (_authMethod == VaultAuthMethod.biometric) ...[
                    TextButton.icon(
                      onPressed: _triggerBiometricUnlock,
                      icon: Icon(Icons.fingerprint,
                          color: _primaryColor, size: 20),
                      label: const Text('Retry Biometrics',
                          style: TextStyle(
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _showForceResetDialog,
                      icon: const Icon(Icons.delete_forever_outlined,
                          color: Colors.redAccent, size: 18),
                      label: const Text('Reset Vault',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                  if (_authMethod == VaultAuthMethod.faceUnlock) ...[
                    TextButton.icon(
                      onPressed: _triggerFaceUnlock,
                      icon: Icon(Icons.face_retouching_natural,
                          color: _primaryColor, size: 20),
                      label: const Text('Retry Face Unlock',
                          style: TextStyle(
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _showForceResetDialog,
                      icon: const Icon(Icons.delete_forever_outlined,
                          color: Colors.redAccent, size: 18),
                      label: const Text('Reset Vault',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],

                  // ── Force Reset after too many failed attempts ──
                  if (_failedAttempts >= _maxFailedAttempts) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _showForceResetDialog,
                      icon: const Icon(Icons.delete_forever,
                          color: Colors.redAccent, size: 18),
                      label: const Text('Force Reset Vault',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),

          // ── Overlay loading spinner (prevents jarring flash) ──
          if (_isUnlocking)
            Positioned.fill(
              child: Container(
                color: Colors.black26,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: _cardColor,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: CircularProgressIndicator(color: _primaryColor),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPasswordInput() {
    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _textColor.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: _primaryColor.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: _credController,
        obscureText: _obscurePassword,
        style: TextStyle(color: _textColor, fontSize: 15),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _handleUnlock(),
        decoration: InputDecoration(
          hintText: 'Enter password',
          hintStyle: TextStyle(color: _textColor.withValues(alpha: 0.35)),
          prefixIcon: Icon(Icons.lock_outline,
              color: _textColor.withValues(alpha: 0.5), size: 20),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: _textColor.withValues(alpha: 0.5),
              size: 20,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          filled: true,
          fillColor: Colors.transparent,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }

  Widget _buildPinInput() {
    final dotCount = _pinLength ?? 8;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(dotCount, (i) {
            final active = i < _credController.text.length;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(horizontal: 5),
              width: active ? 14 : 10,
              height: active ? 14 : 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _primaryColor : Colors.transparent,
                border: Border.all(
                  color: active ? _primaryColor : _textColor.withValues(alpha: 0.24),
                  width: 2,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: _primaryColor.withValues(alpha: 0.3),
                          blurRadius: 6,
                          spreadRadius: 1,
                        )
                      ]
                    : null,
              ),
            );
          }),
        ),
        if (_pinLength == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Enter PIN and press confirm',
                style: TextStyle(
                    color: _textColor.withValues(alpha: 0.4), fontSize: 11)),
          ),
        const SizedBox(height: 20),
        _buildKeypad(),
      ],
    );
  }

  Widget _buildKeypad() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildKeypadRow(['1', '2', '3']),
        const SizedBox(height: 10),
        _buildKeypadRow(['4', '5', '6']),
        const SizedBox(height: 10),
        _buildKeypadRow(['7', '8', '9']),
        const SizedBox(height: 10),
        _buildKeypadRow(['C', '0', '⌫']),
      ],
    );
  }

  Widget _buildKeypadRow(List<String> labels) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: labels
          .map((l) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _keyBtn(l,
                    color: l == 'C'
                        ? Colors.redAccent
                        : l == '⌫'
                            ? Colors.orangeAccent
                            : null),
              ))
          .toList(),
    );
  }

  Widget _keyBtn(String label, {Color? color}) {
    return SizedBox(
      width: 64,
      height: 64,
      child: OutlinedButton(
        onPressed: () {
          HapticFeedback.lightImpact();
          setState(() {
            _errorMessage = '';
            if (label == 'C') {
              _credController.text = '';
            } else if (label == '⌫') {
              final t = _credController.text;
              if (t.isNotEmpty) {
                _credController.text = t.substring(0, t.length - 1);
              }
            } else {
              final maxLen = _pinLength ?? 8;
              if (_credController.text.length < maxLen) {
                _credController.text += label;
                // Only auto-check when pin length IS known
                if (_pinLength != null &&
                    _credController.text.length == _pinLength) {
                  _checkPinUnlockAutomatic();
                }
              }
            }
          });
        },
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          side: BorderSide(
            color: color?.withValues(alpha: 0.3) ?? _textColor.withValues(alpha: 0.08),
            width: 1.5,
          ),
          backgroundColor: color != null
              ? color.withValues(alpha: 0.06)
              : _textColor.withValues(alpha: 0.03),
          foregroundColor: color ?? _textColor,
          padding: EdgeInsets.zero,
        ),
        child: label == '⌫'
            ? Icon(Icons.backspace_outlined, size: 20, color: color ?? _textColor)
            : label == 'C'
                ? Icon(Icons.clear_rounded, size: 22, color: color ?? _textColor)
                : Text(label,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: color ?? _textColor)),
      ),
    );
  }

  Widget _buildPatternInput() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Draw your unlock pattern',
          style: TextStyle(color: _textColor.withValues(alpha: 0.5), fontSize: 12),
        ),
        const SizedBox(height: 12),
        Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.35,
            maxWidth: MediaQuery.of(context).size.height * 0.35,
          ),
          decoration: BoxDecoration(
            color: _textColor.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _textColor.withValues(alpha: 0.06)),
          ),
          padding: const EdgeInsets.all(8),
          child: AspectRatio(
            aspectRatio: 1.0,
            child: PatternLock(
              key: ValueKey(_patternResetCounter),
              onSelect: (_) {},
              onComplete: (points) {
                setState(() {
                  _patternPoints = points;
                  _errorMessage = '';
                });
                if (points.length >= 4) {
                  _handlePatternUnlockAutomatic(points);
                } else {
                  setState(() =>
                      _errorMessage = 'Connect at least 4 dots');
                  _triggerShake();
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBiometricPrompt() {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 24),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _primaryColor.withValues(alpha: 0.1),
              border: Border.all(
                  color: _primaryColor.withValues(alpha: 0.2), width: 2),
            ),
            child: Icon(Icons.fingerprint,
                size: 44, color: _primaryColor),
          ),
          const SizedBox(height: 20),
          Text(
            'Touch the fingerprint sensor',
            style: TextStyle(
                color: _textColor.withValues(alpha: 0.7),
                fontSize: 14,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
            'Authenticate using device biometrics',
            style: TextStyle(
                color: _textColor.withValues(alpha: 0.4), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildFaceUnlockPrompt() {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 24),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _primaryColor.withValues(alpha: 0.1),
              border: Border.all(
                  color: _primaryColor.withValues(alpha: 0.2), width: 2),
            ),
            child: Icon(Icons.face_retouching_natural,
                size: 44, color: _primaryColor),
          ),
          const SizedBox(height: 20),
          Text(
            'Opening face scanner…',
            style: TextStyle(
                color: _textColor.withValues(alpha: 0.7),
                fontSize: 14,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
            'Position your face in front of the camera',
            style: TextStyle(
                color: _textColor.withValues(alpha: 0.4), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/vault_models.dart';
import '../../services/vault_service.dart';
import '../../widgets/pattern_lock.dart';
import 'face_camera_screen.dart';
import 'vault_screen.dart';
import '../../services/media_permission_service.dart';
import '../../services/responsive_helper.dart';

class VaultSetupScreen extends StatefulWidget {
  const VaultSetupScreen({super.key});
  @override
  State<VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<VaultSetupScreen>
    with WidgetsBindingObserver {
  // step: 0=Warning, 1=ChooseMethod, 2=EnterCred, 3=Confirm, 4=Success
  int _step = 0;
  VaultAuthMethod? _selectedMethod;
  final _credController = TextEditingController();
  final _confirmController = TextEditingController();
  String _errorMessage = '';
  List<int> _patternPoints = [];
  List<int> _confirmPatternPoints = [];
  bool _isBiometricProcessing = false;

  Color get _primary => Theme.of(context).colorScheme.primary;
  Color get _accent => Theme.of(context).colorScheme.secondary;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _card => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VaultService.instance.secureScreen(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _credController.dispose();
    _confirmController.dispose();
    VaultService.instance.secureScreen(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      VaultService.instance.secureScreen(false);
    } else if (state == AppLifecycleState.resumed) {
      VaultService.instance.secureScreen(true);
    }
  }



  Future<void> _checkPermissionsAndProceed() async {
    try {
      final bool granted = await const MethodChannel(
        'in.sddev.ghost_gallery/media_manager',
      ).invokeMethod<bool>('requestMediaPermission') ?? false;

      if (granted) {
        _nextStep();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Gallery permissions are required for Vault.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Permission error: $e');
    }
  }

  void _nextStep() => setState(() {
    _errorMessage = '';
    _step++;
  });

  void _prevStep() {
    if (_step == 0) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _errorMessage = '';
      _step--;
      if (_step == 1) {
        _credController.clear();
        _confirmController.clear();
        _patternPoints.clear();
        _confirmPatternPoints.clear();
      }
    });
  }

  Future<void> _handleSave() async {
    final cred = _selectedMethod == VaultAuthMethod.pattern
        ? _patternPoints.join(',')
        : _credController.text;
    final confirm = _selectedMethod == VaultAuthMethod.pattern
        ? _confirmPatternPoints.join(',')
        : _confirmController.text;

    if (cred.isEmpty) {
      setState(() => _errorMessage = 'Please enter a valid lock credential');
      return;
    }
    if (cred != confirm) {
      setState(() {
        _errorMessage = 'Credentials do not match. Try again.';
        _confirmController.clear();
        _confirmPatternPoints.clear();
        _step = 2;
      });
      return;
    }
    try {
      await VaultService.instance.setupVault(_selectedMethod!, cred);
      if (_selectedMethod == VaultAuthMethod.biometric) {
        await VaultService.instance.setupBiometricKey();
      }
      _nextStep();
    } catch (e) {
      setState(() => _errorMessage = 'Failed to configure Vault: $e');
    }
  }

  Future<void> _enrollBiometricsDirectly() async {
    setState(() {
      _isBiometricProcessing = true;
      _errorMessage = '';
    });
    final errorMsg = await VaultService.instance.verifyBiometricSupport();
    if (errorMsg == null) {
      try {
        _selectedMethod = VaultAuthMethod.biometric;
        await VaultService.instance.setupVault(
          VaultAuthMethod.biometric,
          'biometric_secured',
        );
        await VaultService.instance.setupBiometricKey();
        setState(() {
          _isBiometricProcessing = false;
          _step = 4;
        });
      } catch (e) {
        setState(() {
          _isBiometricProcessing = false;
          _errorMessage = 'Failed to store biometric config: $e';
        });
      }
    } else {
      setState(() {
        _isBiometricProcessing = false;
        _errorMessage = errorMsg;
      });
    }
  }

  Future<void> _enrollFaceUnlockDirectly() async {
    final result = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => const FaceCameraScreen(mode: FaceCameraMode.enrollment),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _isBiometricProcessing = true;
      _errorMessage = '';
    });
    try {
      _selectedMethod = VaultAuthMethod.faceUnlock;
      await VaultService.instance.setupVault(
        VaultAuthMethod.faceUnlock,
        'face_unlock_secured',
      );
      await VaultService.instance.setupFaceUnlockKey(result);
      setState(() {
        _isBiometricProcessing = false;
        _step = 4;
      });
    } catch (e) {
      setState(() {
        _isBiometricProcessing = false;
        _errorMessage = 'Face enrollment failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: _text.withValues(alpha: 0.7)),
          onPressed: _prevStep,
        ),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: _buildCurrentStep(),
        ),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0:
        return _buildWelcomeStep();
      case 1:
        return _buildChooseMethodStep();
      case 2:
        return _buildEnterCredStep(isConfirm: false);
      case 3:
        return _buildEnterCredStep(isConfirm: true);
      case 4:
        return _buildSuccessStep();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildWelcomeStep() {
    final isWatch = context.isWatch;
    return SingleChildScrollView(
      key: const ValueKey('welcome'),
      padding: EdgeInsets.all(isWatch ? 12 : 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: isWatch ? 12 : 36),
              Container(
                width: isWatch ? 64 : 110,
                height: isWatch ? 64 : 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [_primary, _accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _primary.withValues(alpha: 0.3),
                      blurRadius: isWatch ? 12 : 24,
                      spreadRadius: isWatch ? 1 : 2,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.shield_rounded,
                  size: isWatch ? 32 : 56,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: isWatch ? 16 : 32),
              Text(
                'Secure Vault',
                style: TextStyle(
                  color: _text,
                  fontSize: isWatch ? 18 : 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Encrypt and hide your most private files securely on your device.',
                  style: TextStyle(
                    color: _text.withValues(alpha: 0.6),
                    fontSize: isWatch ? 12 : 15,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(height: isWatch ? 20 : 44),
              ElevatedButton(
                onPressed: () {
                  if (Platform.isAndroid || Platform.isIOS) {
                    _checkPermissionsAndProceed();
                  } else {
                    _nextStep();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  minimumSize: Size(double.infinity, isWatch ? 42 : 54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  'Get Started',
                  style: TextStyle(fontSize: isWatch ? 14 : 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChooseMethodStep() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          key: const ValueKey('choose'),
          padding: EdgeInsets.symmetric(
            horizontal: context.isWatch ? 12 : 24,
            vertical: 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose Security',
                style: TextStyle(
                  color: _text,
                  fontSize: context.isWatch ? 18 : 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Select how you want to unlock your Vault.',
                style: TextStyle(color: _text.withValues(alpha: 0.55), fontSize: context.isWatch ? 12 : 14),
              ),
              const SizedBox(height: 20),
              if (_errorMessage.isNotEmpty) ...[
                Text(
                  _errorMessage,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
                const SizedBox(height: 12),
              ],
          Expanded(
            child: _isBiometricProcessing
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      _methodCard(
                        VaultAuthMethod.pin,
                        'PIN Lock',
                        '4–8 digit secret code.',
                        Icons.dialpad_rounded,
                      ),
                      _methodCard(
                        VaultAuthMethod.password,
                        'Password',
                        'Strong alphanumeric password.',
                        Icons.lock_rounded,
                      ),
                      _methodCard(
                        VaultAuthMethod.pattern,
                        'Pattern Lock',
                        'Connect 4+ dots on a 3×3 grid.',
                        Icons.pattern,
                      ),
                      _methodCard(
                        VaultAuthMethod.biometric,
                        'Biometrics',
                        'Use Fingerprint .',
                        Icons.fingerprint,
                        onTap: () {
                          _enrollBiometricsDirectly();
                        },
                      ),
                      _methodCard(
                        VaultAuthMethod.faceUnlock,
                        'Face Unlock',
                        'ML-powered face recognition.',
                        Icons.face_retouching_natural,
                        onTap: () {
                          _enrollFaceUnlockDirectly();
                        },
                      ),
                    ],
                  ),
          ),
          if (_selectedMethod != VaultAuthMethod.biometric &&
              _selectedMethod != VaultAuthMethod.faceUnlock &&
              !_isBiometricProcessing)
            ElevatedButton(
              onPressed: _selectedMethod != null ? _nextStep : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _text.withValues(alpha: 0.1),
                minimumSize: const Size(double.infinity, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    ),
      ),
    );
  }

  Widget _methodCard(
    VaultAuthMethod method,
    String title,
    String subtitle,
    IconData icon, {
    VoidCallback? onTap,
  }) {
    final isSelected = _selectedMethod == method;
    return GestureDetector(
      onTap: onTap ?? () => setState(() => _selectedMethod = method),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? _primary.withValues(alpha: 0.12) : _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? _primary : _text.withValues(alpha: 0.06),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected
                    ? _primary.withValues(alpha: 0.25)
                    : _text.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: isSelected ? _accent : _text.withValues(alpha: 0.6),
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: _text,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: _text.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle_rounded, color: _accent),
          ],
        ),
      ),
    );
  }

  Widget _buildEnterCredStep({required bool isConfirm}) {
    final isPattern = _selectedMethod == VaultAuthMethod.pattern;
    final isPin = _selectedMethod == VaultAuthMethod.pin;
    final isWatch = context.isWatch;
    final title = isConfirm ? 'Confirm Lock' : 'Create Lock';
    final subtitle = isConfirm
        ? 'Repeat to confirm'
        : 'Set your ${_selectedMethod?.label ?? ""} lock';

    final content = Column(
      mainAxisSize: isPattern ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: _text,
            fontSize: isWatch ? 18 : 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(color: _text.withValues(alpha: 0.55), fontSize: isWatch ? 12 : 14),
        ),
        SizedBox(height: isWatch ? 12 : 24),
        if (isPattern)
          _buildPatternStep(isConfirm)
        else if (isPin)
          _buildPinStep(isConfirm)
        else
          _buildPasswordStep(isConfirm),
        if (_errorMessage.isNotEmpty) ...[
          const SizedBox(height: 12),
          Center(
            child: Text(
              _errorMessage,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        if (!isPattern) ...[
          SizedBox(height: isWatch ? 16 : 28),
          ElevatedButton(
            onPressed: () {
              final val = isConfirm
                  ? _confirmController.text
                  : _credController.text;
              if (val.isEmpty) {
                setState(() => _errorMessage = 'Field cannot be empty');
                return;
              }
              if (isPin && (val.length < 4 || int.tryParse(val) == null)) {
                setState(
                  () => _errorMessage = 'PIN must be 4+ numeric digits',
                );
                return;
              }
              if (isConfirm) {
                _handleSave();
              } else {
                _nextStep();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              minimumSize: Size(double.infinity, isWatch ? 42 : 54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              isConfirm ? 'Confirm & Save' : 'Continue',
              style: TextStyle(
                fontSize: isWatch ? 14 : 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          key: ValueKey('cred_$isConfirm'),
          padding: EdgeInsets.symmetric(
            horizontal: isWatch ? 12 : 24,
            vertical: 12,
          ),
          child: isPattern ? content : SingleChildScrollView(child: content),
        ),
      ),
    );
  }

  Widget _buildPatternStep(bool isConfirm) {
    return Expanded(
      child: Column(
        children: [
          Text(
            isConfirm ? 'Draw the same pattern' : 'Connect at least 4 dots',
            style: TextStyle(color: _text.withValues(alpha: 0.6), fontSize: 13),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1.0,
                child: PatternLock(
                  key: ValueKey('pattern_$isConfirm'),
                  onSelect: (_) {},
                  onComplete: (pts) => setState(() {
                    if (isConfirm) {
                      _confirmPatternPoints = pts;
                    } else {
                      _patternPoints = pts;
                    }
                    _errorMessage = pts.length < 4
                        ? 'Connect at least 4 dots'
                        : '';
                  }),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed:
                (isConfirm
                        ? _confirmPatternPoints.length
                        : _patternPoints.length) >=
                    4
                ? (isConfirm ? _handleSave : _nextStep)
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _text.withValues(alpha: 0.1),
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              isConfirm ? 'Confirm Pattern' : 'Continue',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildPinStep(bool isConfirm) {
    final ctrl = isConfirm ? _confirmController : _credController;
    final isWatch = context.isWatch;
    final dotSize = isWatch ? 8.0 : 12.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(8, (i) {
            final active = i < ctrl.text.length;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.symmetric(horizontal: isWatch ? 3 : 6),
              width: active ? (dotSize + 3) : dotSize,
              height: active ? (dotSize + 3) : dotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _primary : Colors.transparent,
                border: Border.all(
                  color: active ? _primary : _text.withValues(alpha: 0.24),
                  width: 2,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: _primary.withValues(alpha: 0.3),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
            );
          }),
        ),
        SizedBox(height: isWatch ? 14 : 28),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPinRow(['1', '2', '3'], ctrl),
            SizedBox(height: isWatch ? 6 : 12),
            _buildPinRow(['4', '5', '6'], ctrl),
            SizedBox(height: isWatch ? 6 : 12),
            _buildPinRow(['7', '8', '9'], ctrl),
            SizedBox(height: isWatch ? 6 : 12),
            _buildPinRow(['C', '0', '⌫'], ctrl),
          ],
        ),
      ],
    );
  }

  Widget _buildPinRow(List<String> labels, TextEditingController ctrl) {
    final isWatch = context.isWatch;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: labels.map((label) {
        Color? btnColor;
        if (label == 'C') btnColor = Colors.redAccent;
        if (label == '⌫') btnColor = Colors.orangeAccent;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: isWatch ? 4 : 12),
          child: _pinKey(label, ctrl, color: btnColor),
        );
      }).toList(),
    );
  }

  Widget _pinKey(String label, TextEditingController ctrl, {Color? color}) {
    final isWatch = context.isWatch;
    final keySize = isWatch ? 46.0 : 70.0;
    return SizedBox(
      width: keySize,
      height: keySize,
      child: OutlinedButton(
        onPressed: () {
          HapticFeedback.lightImpact();
          setState(() {
            _errorMessage = '';
            if (label == 'C') {
              ctrl.clear();
            } else if (label == '⌫') {
              if (ctrl.text.isNotEmpty) {
                ctrl.text = ctrl.text.substring(0, ctrl.text.length - 1);
              }
            } else if (ctrl.text.length < 8) {
              ctrl.text += label;
            }
          });
        },
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          side: BorderSide(
            color: color?.withValues(alpha: 0.3) ?? _text.withValues(alpha: 0.08),
            width: 1.5,
          ),
          backgroundColor: color != null
              ? color.withValues(alpha: 0.06)
              : _text.withValues(alpha: 0.03),
          foregroundColor: color ?? _text,
          padding: EdgeInsets.zero,
        ),
        child: label == '⌫'
            ? Icon(Icons.backspace_outlined, size: isWatch ? 18 : 22, color: color ?? _text)
            : label == 'C'
            ? Icon(Icons.clear_rounded, size: isWatch ? 18 : 24, color: color ?? _text)
            : Text(
                label,
                style: TextStyle(
                  fontSize: isWatch ? 16 : 24,
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
      ),
    );
  }

  Widget _buildPasswordStep(bool isConfirm) {
    return TextField(
      controller: isConfirm ? _confirmController : _credController,
      obscureText: true,
      style: TextStyle(color: _text),
      decoration: InputDecoration(
        labelText: isConfirm ? 'Confirm Password' : 'New Password',
        labelStyle: TextStyle(color: _text.withValues(alpha: 0.5)),
        filled: true,
        fillColor: _card,
        prefixIcon: Icon(Icons.lock_outline, color: _text.withValues(alpha: 0.5)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildSuccessStep() {
    final isWatch = context.isWatch;
    return SingleChildScrollView(
      key: const ValueKey('success'),
      padding: EdgeInsets.symmetric(horizontal: isWatch ? 12 : 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: isWatch ? 16 : 40),
              Container(
                width: isWatch ? 64 : 100,
                height: isWatch ? 64 : 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: isWatch ? 38 : 64,
                  color: Colors.greenAccent,
                ),
              ),
              SizedBox(height: isWatch ? 14 : 28),
              Text(
                'Vault Initialized!',
                style: TextStyle(
                  color: _text,
                  fontSize: isWatch ? 20 : 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Your Secure Vault is ready. Files encrypted here are stored safely on this device.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _text.withValues(alpha: 0.6),
                  fontSize: isWatch ? 12 : 15,
                  height: 1.4,
                ),
              ),
              SizedBox(height: isWatch ? 20 : 44),
              ElevatedButton(
                onPressed: () async {
                  if (Platform.isAndroid) {
                    final granted =
                        await MediaPermissionService.ensureManageMediaPermission(
                          context,
                        );
                    if (!granted) return;
                  }
                  if (!VaultService.instance.isUsingExternalStorage && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '⚠ External storage unavailable — Vault stored internally. Files may be lost on uninstall or Clear Data.',
                        ),
                        duration: Duration(seconds: 6),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                  if (mounted) {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(name: 'vault'),
                        builder: (_) => const VaultScreen(),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  minimumSize: Size(double.infinity, isWatch ? 42 : 54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  'Open Vault',
                  style: TextStyle(fontSize: isWatch ? 14 : 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

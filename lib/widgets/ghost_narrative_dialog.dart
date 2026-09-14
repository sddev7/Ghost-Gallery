// ═══════════════════════════════════════════════════════════════════════════
// ghost_narrative_dialog.dart
//
// Ghost AI onboarding narrative — shown ONCE before media permission request.
// Features:
//   • Floating ghost banner with blood-red glow
//   • Typewriter write-in animation for the narrative text
//   • Privacy bullet points
//   • "Let Ghost In" → triggers permission  |  "Maybe Later" → dismiss
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Shows the Ghost narrative dialog as a bottom-sheet style modal.
/// Returns `true` if the user tapped "Let Ghost In", `false` otherwise.
Future<bool> showGhostNarrativeDialog(BuildContext context) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Ghost Narrative',
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 420),
    transitionBuilder: (ctx, anim, _, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      );
    },
    pageBuilder: (ctx, _, __) => const _GhostNarrativeSheet(),
  );
  return result ?? false;
}

// ── Full-screen bottom-sheet dialog ──────────────────────────────────────────

class _GhostNarrativeSheet extends StatefulWidget {
  const _GhostNarrativeSheet();

  @override
  State<_GhostNarrativeSheet> createState() => _GhostNarrativeSheetState();
}

class _GhostNarrativeSheetState extends State<_GhostNarrativeSheet>
    with TickerProviderStateMixin {
  // ── Colors ──────────────────────────────────────────────────────────────────
  static const Color _voidBlack     = Color(0xFF060509);
  static const Color _cardBg        = Color(0xFF0D0B16);
  static const Color _bloodRed      = Color(0xFF8B0000);
  static const Color _bloodRedGlow  = Color(0xFFCC0000);
  static const Color _paleText      = Color(0xFFD4D4E0);
  static const Color _dimText       = Color(0xFF8888AA);
  static const Color _bulletGold    = Color(0xFFFFD180);

  // ── Typewriter narrative ───────────────────────────────────────────────────
  static const String _fullText =
      'Hi, I\'m Ghost — your On-Device AI.\n\n'
      'Let me peek at your photos & videos.\n'
      'I process everything locally, so I can:\n\n'
      '  •  Surface smarter search results\n'
      '  •  Remember family & friends\' birthdays\n'
      '  •  Craft birthday wish videos & more\n'
      '     — on exactly the right day\n\n'
      'Worried about privacy?\n'
      'Nothing ever leaves your device.\n'
      'I exist for your eyes only.';

  // ── Animations ──────────────────────────────────────────────────────────────
  late final AnimationController _floatCtrl;
  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;

  // ── Typewriter state ───────────────────────────────────────────────────────
  String  _displayedText = '';
  int     _charIndex      = 0;
  Timer?  _typeTimer;
  bool    _typingDone     = false;

  @override
  void initState() {
    super.initState();

    // Floating ghost image
    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);

    // Fade-in for the whole card
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    _fadeCtrl.forward();

    // Start typewriter after a short pause
    Future.delayed(const Duration(milliseconds: 600), _startTyping);
  }

  void _startTyping() {
    if (!mounted) return;
    _typeTimer = Timer.periodic(const Duration(milliseconds: 22), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_charIndex >= _fullText.length) {
        t.cancel();
        setState(() => _typingDone = true);
        return;
      }
      setState(() {
        _displayedText = _fullText.substring(0, ++_charIndex);
      });
    });
  }

  // Skip animation on tap
  void _skipTyping() {
    if (_typingDone) return;
    _typeTimer?.cancel();
    setState(() {
      _displayedText = _fullText;
      _charIndex     = _fullText.length;
      _typingDone    = true;
    });
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    _floatCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _voidBlack,
        body: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: GestureDetector(
              onTap: _skipTyping,
              behavior: HitTestBehavior.translucent,
              child: Column(
                children: [
                  // ── Ghost banner ─────────────────────────────────────────────
                  _buildGhostBanner(screenH),
  
                  // ── Narrative scroll area ────────────────────────────────────
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      child: _buildNarrativeCard(),
                    ),
                  ),
  
                  // ── Action buttons ───────────────────────────────────────────
                  _buildActions(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Ghost Banner ──────────────────────────────────────────────────────────

  Widget _buildGhostBanner(double screenH) {
    return Container(
      width: double.infinity,
      height: screenH * 0.30,
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.75,
          colors: [Color(0xFF1A0A0A), _voidBlack],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Blood glow
          AnimatedBuilder(
            animation: _floatCtrl,
            builder: (_, __) {
              final pulse = 0.3 + 0.1 * math.sin(_floatCtrl.value * math.pi);
              return Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _bloodRed.withValues(alpha: pulse),
                      blurRadius: 60,
                      spreadRadius: 20,
                    ),
                  ],
                ),
              );
            },
          ),
          // Floating ghost image
          AnimatedBuilder(
            animation: _floatCtrl,
            builder: (_, child) {
              final dy = math.sin(_floatCtrl.value * math.pi) * 14;
              return Transform.translate(
                offset: Offset(0, dy),
                child: child,
              );
            },
            child: Image.asset(
              'assets/normal.png',
              width: 140,
              height: 140,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.nights_stay_rounded,
                size: 100,
                color: _bloodRedGlow,
              ),
            ),
          ),
          // "GHOST" label at bottom of banner
          Positioned(
            bottom: 12,
            child: Text(
              'G H O S T',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 6,
                color: _bloodRedGlow.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Narrative Card ────────────────────────────────────────────────────────

  Widget _buildNarrativeCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _bloodRed.withValues(alpha: 0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: _bloodRed.withValues(alpha: 0.08),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Typewriter text
          Text(
            _displayedText,
            style: const TextStyle(
              fontSize: 15.5,
              color: _paleText,
              height: 1.65,
              fontFamily: 'Roboto',
            ),
          ),
          // Blinking cursor while typing
          if (!_typingDone)
            _BlinkingCursor(color: _bloodRedGlow),
          // Privacy badge — shown after typing done
          if (_typingDone) ...[
            const SizedBox(height: 20),
            _buildPrivacyBadge(),
          ],
        ],
      ),
    );
  }

  Widget _buildPrivacyBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.green.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline_rounded, color: Colors.green, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Zero uploads. Zero cloud. 100% on your device.',
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.green[300],
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Action Buttons ────────────────────────────────────────────────────────

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Primary CTA
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: _bloodRedGlow,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 8,
                shadowColor: _bloodRed.withValues(alpha: 0.5),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.visibility_rounded, size: 20),
                  SizedBox(width: 10),
                  Text(
                    'Let Ghost In',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Secondary
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Maybe Later',
              style: TextStyle(
                color: _dimText,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Blinking cursor widget ────────────────────────────────────────────────────

class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Opacity(
        opacity: _ctrl.value,
        child: Container(
          width: 2,
          height: 18,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }
}

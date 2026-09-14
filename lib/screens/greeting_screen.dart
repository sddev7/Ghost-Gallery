import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'home_screen.dart';
import '../widgets/subscription_guard.dart';
import '../services/responsive_helper.dart';
import '../config/app_social_links.dart';

class GreetingScreen extends StatefulWidget {
  final String appTheme;
  final void Function(String) onThemeChanged;

  const GreetingScreen({
    super.key,
    required this.appTheme,
    required this.onThemeChanged,
  });

  @override
  State<GreetingScreen> createState() => _GreetingScreenState();
}

class _GreetingScreenState extends State<GreetingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _floatController;
  late final AnimationController _introController;

  late final Animation<double> _titleFade;
  late final Animation<double> _titleScale;
  late final Animation<double> _taglineFade;
  late final Animation<double> _taglineSlide;
  late final Animation<double> _contentFade;

  bool _agreedToPolicy = false;
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();

    // Loop float animation for the ghost image
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    // Staged introduction animation controller
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _titleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      ),
    );

    _titleScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOutBack),
      ),
    );

    _taglineFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
      ),
    );

    _taglineSlide = Tween<double>(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
      ),
    );

    _contentFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.6, 1.0, curve: Curves.easeIn),
      ),
    );

    _introController.forward();
  }

  @override
  void dispose() {
    _floatController.dispose();
    _introController.dispose();
    super.dispose();
  }

  Future<void> _launchPrivacyPolicy() async {
    final url = Uri.parse(AppSocialLinks.privacyPolicy);
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      } else {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching privacy policy: $e');
    }
  }

  Future<void> _getStarted() async {
    if (!_agreedToPolicy || _isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ghost_has_launched_before', true);

      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 600),
            pageBuilder: (context, animation, secondaryAnimation) {
              return GalleryHomeScreen(
                appTheme: widget.appTheme,
                onThemeChanged: widget.onThemeChanged,
              );
            },
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.0, 0.05),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                  child: child,
                ),
              );
            },
          ),
        );
      }
    } catch (e) {
      debugPrint('Navigation error: $e');
      setState(() => _isNavigating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color voidBlack = Color(0xFF000000);
    const Color cardBg = Color(0xFF121214);
    const Color borderCol = Color(0xFF222226);
    const Color puttyWhite = Color(0xFFEDEAE2);
    const Color puttyWhiteBright = Color(0xFFF5F3ED);
    const Color puttyMuted = Color(0xFF9E9C96);
    final isWatch = context.isWatch;

    return Scaffold(
      backgroundColor: voidBlack,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double imgSize = isWatch
                ? 72.0
                : (constraints.maxHeight * 0.22).clamp(90.0, 190.0);
            final double titleSize = isWatch ? 20.0 : (constraints.maxWidth > 600 ? 38.0 : 30.0);

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(
                    horizontal: isWatch ? 12.0 : 28.0,
                    vertical: isWatch ? 8.0 : 16.0,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(height: isWatch ? 6 : 14),

                      // ── FLOATING GHOST IMAGE ──
                      AnimatedBuilder(
                        animation: _floatController,
                        builder: (context, child) {
                          final double floatOffset = math.sin(_floatController.value * 2 * math.pi) * 12;
                          return Transform.translate(
                            offset: Offset(0, floatOffset),
                            child: AnimatedBuilder(
                              animation: _introController,
                              builder: (context, innerChild) {
                                return Opacity(
                                  opacity: _taglineFade.value,
                                  child: Transform.scale(
                                    scale: _titleScale.value,
                                    child: Container(
                                      width: imgSize,
                                      height: imgSize,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: puttyWhite.withAlpha(20),
                                            blurRadius: 30,
                                            spreadRadius: 4,
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(imgSize),
                                        child: Image.asset(
                                          'assets/normal.png',
                                          fit: BoxFit.contain,
                                          errorBuilder: (context, error, stackTrace) {
                                            return Icon(
                                              Icons.nights_stay,
                                              size: imgSize * 0.5,
                                              color: puttyWhiteBright,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                      SizedBox(height: isWatch ? 10 : 20),

                      // ── APP NAME & TAGLINE ──
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                            animation: _introController,
                            builder: (context, child) {
                              return Opacity(
                                opacity: _titleFade.value,
                                child: Transform.scale(
                                  scale: _titleScale.value,
                                  child: Text(
                                    'GHOST GALLERY',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: titleSize,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: isWatch ? 1.0 : 2.0,
                                      color: puttyWhiteBright,
                                      shadows: [
                                        Shadow(
                                          color: Colors.white.withAlpha(40),
                                          blurRadius: 10,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          SizedBox(height: isWatch ? 6 : 14),

                          AnimatedBuilder(
                            animation: _introController,
                            builder: (context, child) {
                              return Opacity(
                                opacity: _taglineFade.value,
                                child: Transform.translate(
                                  offset: Offset(0, _taglineSlide.value),
                                  child: Text(
                                    'What happens in the dark stays on your device. A ghost meant only for your eye.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: isWatch ? 11.5 : 14.5,
                                      fontWeight: FontWeight.w400,
                                      color: puttyMuted,
                                      height: 1.45,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: isWatch ? 12 : 24),

                      // ── AGREE PRIVACY POLICY & BUTTON ──
                      AnimatedBuilder(
                        animation: _introController,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _contentFade.value,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: isWatch ? 8 : 12,
                                    vertical: isWatch ? 4 : 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cardBg,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: borderCol,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Theme(
                                        data: ThemeData(
                                          unselectedWidgetColor: puttyMuted.withAlpha(120),
                                        ),
                                        child: Checkbox(
                                          value: _agreedToPolicy,
                                          activeColor: puttyWhiteBright,
                                          checkColor: Colors.black,
                                          onChanged: (val) {
                                            setState(() {
                                              _agreedToPolicy = val ?? false;
                                            });
                                          },
                                        ),
                                      ),
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _agreedToPolicy = !_agreedToPolicy;
                                            });
                                          },
                                          child: RichText(
                                            text: TextSpan(
                                              style: TextStyle(
                                                fontSize: isWatch ? 10.5 : 12.5,
                                                color: puttyMuted,
                                              ),
                                              children: [
                                                const TextSpan(text: 'I agree to the '),
                                                WidgetSpan(
                                                  alignment: PlaceholderAlignment.middle,
                                                  child: GestureDetector(
                                                    onTap: _launchPrivacyPolicy,
                                                    child: const Text(
                                                      'Privacy Policy',
                                                      style: TextStyle(
                                                        color: puttyWhiteBright,
                                                        fontWeight: FontWeight.bold,
                                                        decoration: TextDecoration.underline,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const TextSpan(text: ' to continue.'),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(height: isWatch ? 10 : 18),

                                SizedBox(
                                  width: double.infinity,
                                  height: isWatch ? 40 : 50,
                                  child: ElevatedButton(
                                    onPressed: _agreedToPolicy ? _getStarted : null,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: puttyWhiteBright,
                                      foregroundColor: Colors.black,
                                      disabledBackgroundColor: const Color(0xFF1A1A1E),
                                      disabledForegroundColor: const Color(0xFF555555),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      elevation: _agreedToPolicy ? 8 : 0,
                                    ),
                                    child: _isNavigating
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                                            ),
                                          )
                                        : Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                'Get Started',
                                                style: TextStyle(
                                                  fontSize: isWatch ? 13 : 15,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: 0.8,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Icon(
                                                Icons.arrow_forward_rounded,
                                                size: isWatch ? 14 : 18,
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      SizedBox(height: isWatch ? 6 : 16),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

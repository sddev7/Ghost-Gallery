import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_social_links.dart';
import '../services/responsive_helper.dart';

class FollowUsDialog extends StatelessWidget {
  const FollowUsDialog({super.key});

  static Future<void> show(BuildContext context) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const FollowUsDialog(),
    );
  }

  // Checks app open count and shows dialog on 2nd+ open unless denied
  static Future<void> checkAndPrompt(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int openCount = (prefs.getInt('app_open_count') ?? 0) + 1;
      await prefs.setInt('app_open_count', openCount);

      final bool neverShow = prefs.getBool('follow_us_never_show_again') ?? false;
      if (!neverShow && openCount >= 2 && context.mounted) {
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (context.mounted) {
            show(context);
          }
        });
      }
    } catch (e) {
      debugPrint('FollowUs check error: $e');
    }
  }

  Future<void> _denyNeverShowAgain(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('follow_us_never_show_again', true);
    } catch (_) {}
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _launch(BuildContext context, String urlStr) async {
    final uri = Uri.parse(urlStr);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open link: $urlStr'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isWatch = context.isWatch;
    final isTv = context.isTV;

    final borderCol = isDark ? const Color(0xFF2D2B3D) : const Color(0xFFE4E4E7);
    final textPrim = isDark ? const Color(0xFFEDEAE2) : const Color(0xFF18181B);
    final textSec = isDark ? const Color(0xFF9E9C96) : const Color(0xFF71717A);
    final accentMint = isDark ? const Color(0xFF5EEAD4) : const Color(0xFF0D9488);

    final dialogWidth = isWatch
        ? 240.0
        : context.isMobile
            ? 360.0
            : isTv
                ? 440.0
                : 400.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.zero,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isWatch ? 8 : 20,
              vertical: isWatch ? 10 : 24,
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: dialogWidth),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(isWatch ? 18 : 28),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isDark
                        ? const [Color(0xFF181622), Color(0xFF0F0E16)]
                        : const [Colors.white, Color(0xFFF9FAFB)],
                  ),
                  borderRadius: BorderRadius.circular(isWatch ? 18 : 28),
                  border: Border.all(color: borderCol, width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.65 : 0.15),
                      blurRadius: isWatch ? 14 : 32,
                      spreadRadius: isWatch ? 1 : 4,
                    ),
                    if (isDark)
                      BoxShadow(
                        color: accentMint.withValues(alpha: 0.05),
                        blurRadius: 40,
                        spreadRadius: 2,
                      ),
                  ],
                ),
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isWatch ? 12 : 22,
                    vertical: isWatch ? 12 : 22,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Top header badge with Ghost mascot and glow
                      _buildHeaderAvatar(isWatch, isDark, accentMint, textPrim),
                      SizedBox(height: isWatch ? 6 : 10),
                      // Ecosystem Pill Tag
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: isWatch ? 8 : 10,
                          vertical: isWatch ? 2 : 4,
                        ),
                        decoration: BoxDecoration(
                          color: accentMint.withValues(alpha: isDark ? 0.12 : 0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: accentMint.withValues(alpha: isDark ? 0.35 : 0.25),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: isWatch ? 5 : 6,
                              height: isWatch ? 5 : 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accentMint,
                              ),
                            ),
                            SizedBox(width: isWatch ? 4 : 6),
                            Text(
                              'GHOST ECOSYSTEM',
                              style: TextStyle(
                                fontSize: isWatch ? 8.5 : 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1,
                                color: accentMint,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: isWatch ? 8 : 12),
                      // Title
                      Text(
                        'We are open-source',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isWatch ? 16 : 20,
                          fontWeight: FontWeight.w800,
                          color: textPrim,
                          letterSpacing: -0.4,
                        ),
                      ),
                      SizedBox(height: isWatch ? 4 : 6),
                      // Subtitle
                      Text(
                        'We made Ghost Ecosystem open-source. Join us.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isWatch ? 11 : 13,
                          color: textSec,
                          height: 1.35,
                        ),
                      ),
                      SizedBox(height: isWatch ? 14 : 20),
                      // Large pill button for GitHub repo
                      _buildGithubPillButton(
                        context: context,
                        isWatch: isWatch,
                        isDark: isDark,
                        textPrim: textPrim,
                        textSec: textSec,
                        accentColor: accentMint,
                      ),
                      SizedBox(height: isWatch ? 14 : 18),
                      // Small icon buttons row for Instagram, X, and Explore more
                      _buildSocialRow(
                        context: context,
                        isWatch: isWatch,
                        isDark: isDark,
                        textPrim: textPrim,
                        textSec: textSec,
                      ),
                      SizedBox(height: isWatch ? 10 : 16),
                      // Bottom action buttons: Don't show again & Close
                      _buildBottomActions(context, isWatch, isDark, textPrim, textSec),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
),
);
}

  Widget _buildHeaderAvatar(bool isWatch, bool isDark, Color accentMint, Color textPrim) {
    final avatarSize = isWatch ? 42.0 : 56.0;
    final mascotSize = isWatch ? 30.0 : 40.0;

    return Container(
      width: avatarSize,
      height: avatarSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            accentMint.withValues(alpha: isDark ? 0.22 : 0.15),
            Colors.transparent,
          ],
          radius: 0.85,
        ),
      ),
      child: Center(
        child: Container(
          width: mascotSize + 8,
          height: mascotSize + 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? const Color(0xFF222030) : const Color(0xFFF1F1F4),
            border: Border.all(
              color: isDark ? const Color(0xFF3F3B54) : const Color(0xFFD4D4D8),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: Image.asset(
              'assets/normal.png',
              width: mascotSize,
              height: mascotSize,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => CustomPaint(
                size: Size(mascotSize * 0.65, mascotSize * 0.65),
                painter: GitHubMarkPainter(color: textPrim),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGithubPillButton({
    required BuildContext context,
    required bool isWatch,
    required bool isDark,
    required Color textPrim,
    required Color textSec,
    required Color accentColor,
  }) {
    final height = isWatch ? 42.0 : 54.0;
    final bgColors = isDark
        ? const [Color(0xFF262436), Color(0xFF1B1925)]
        : const [Color(0xFFFFFFFF), Color(0xFFF3F4F6)];
    final borderCol = isDark ? const Color(0xFF3D3A52) : const Color(0xFFD4D4D8);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _launch(context, AppSocialLinks.githubRepo),
        borderRadius: BorderRadius.circular(32),
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: isWatch ? 12 : 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: bgColors,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: borderCol, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: isWatch ? 28 : 34,
                height: isWatch ? 28 : 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0xFF161520) : const Color(0xFFEAEBED),
                ),
                child: Center(
                  child: CustomPaint(
                    size: Size(isWatch ? 16 : 20, isWatch ? 16 : 20),
                    painter: GitHubMarkPainter(color: textPrim),
                  ),
                ),
              ),
              SizedBox(width: isWatch ? 8 : 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GitHub Repository',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isWatch ? 12 : 14,
                        fontWeight: FontWeight.w700,
                        color: textPrim,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (!isWatch) ...[
                      const SizedBox(height: 1),
                      Text(
                        'Star & explore our codebase',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: textSec,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.arrow_outward_rounded,
                size: isWatch ? 14 : 17,
                color: accentColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSocialRow({
    required BuildContext context,
    required bool isWatch,
    required bool isDark,
    required Color textPrim,
    required Color textSec,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildSocialItem(
          context: context,
          isWatch: isWatch,
          isDark: isDark,
          textSec: textSec,
          label: 'Instagram',
          tooltip: 'Instagram',
          icon: CustomPaint(
            size: Size(isWatch ? 18 : 22, isWatch ? 18 : 22),
            painter: const InstagramMarkPainter(useGradient: true),
          ),
          onTap: () => _launch(context, AppSocialLinks.instagram),
        ),
        _buildSocialItem(
          context: context,
          isWatch: isWatch,
          isDark: isDark,
          textSec: textSec,
          label: 'X',
          tooltip: 'X (Twitter)',
          icon: CustomPaint(
            size: Size(isWatch ? 16 : 20, isWatch ? 16 : 20),
            painter: XMarkPainter(color: textPrim),
          ),
          onTap: () => _launch(context, AppSocialLinks.xTwitter),
        ),
        _buildSocialItem(
          context: context,
          isWatch: isWatch,
          isDark: isDark,
          textSec: textSec,
          label: 'Explore more',
          tooltip: 'Explore more on Play Store',
          icon: CustomPaint(
            size: Size(isWatch ? 18 : 22, isWatch ? 18 : 22),
            painter: const GooglePlayMarkPainter(),
          ),
          onTap: () => _launch(context, AppSocialLinks.playPublisher),
        ),
      ],
    );
  }

  Widget _buildSocialItem({
    required BuildContext context,
    required bool isWatch,
    required bool isDark,
    required Color textSec,
    required String label,
    required String tooltip,
    required Widget icon,
    required VoidCallback onTap,
  }) {
    final btnSize = isWatch ? 38.0 : 48.0;
    final itemBg = isDark ? const Color(0xFF1E1C2A) : const Color(0xFFF4F4F6);
    final itemBorder = isDark ? const Color(0xFF333044) : const Color(0xFFE4E4E7);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(isWatch ? 12 : 16),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: isWatch ? 2 : 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: btnSize,
                height: btnSize,
                decoration: BoxDecoration(
                  color: itemBg,
                  borderRadius: BorderRadius.circular(isWatch ? 12 : 16),
                  border: Border.all(color: itemBorder, width: 1.1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(child: icon),
              ),
              SizedBox(height: isWatch ? 3 : 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: isWatch ? 9.5 : 11,
                  color: textSec,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomActions(
    BuildContext context,
    bool isWatch,
    bool isDark,
    Color textPrim,
    Color textSec,
  ) {
    if (isWatch) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 34,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? const Color(0xFF2B283E) : const Color(0xFFE4E4E7),
                foregroundColor: textPrim,
                elevation: 0,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Close', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            height: 30,
            child: TextButton(
              onPressed: () => _denyNeverShowAgain(context),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                foregroundColor: textSec,
              ),
              child: Text("Don't show Again", style: TextStyle(fontSize: 9.5, color: textSec)),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF191724) : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDark ? const Color(0xFF333044) : const Color(0xFFD4D4D8),
                width: 1.1,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _denyNeverShowAgain(context),
                borderRadius: BorderRadius.circular(14),
                child: Center(
                  child: Text(
                    "Don't show Again",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textSec,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? const [Color(0xFF2E2B42), Color(0xFF222032)]
                    : const [Color(0xFFEDEAE2), Color(0xFFE2DFD7)],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDark ? const Color(0xFF4A4666) : const Color(0xFFCBD5E1),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.of(context).pop(),
                borderRadius: BorderRadius.circular(14),
                child: Center(
                  child: Text(
                    'Close',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: textPrim,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Custom vector painter for the official GitHub mark
class GitHubMarkPainter extends CustomPainter {
  final Color color;
  const GitHubMarkPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    final matrix = Matrix4.diagonal3Values(scale, scale, 1.0);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(12, 2)
      ..cubicTo(6.477, 2, 2, 6.484, 2, 12.017)
      ..cubicTo(2, 16.442, 4.865, 20.197, 8.839, 21.521)
      ..cubicTo(9.339, 21.613, 9.521, 21.304, 9.521, 21.038)
      ..cubicTo(9.521, 20.801, 9.513, 20.17, 9.508, 19.335)
      ..cubicTo(6.726, 19.94, 6.139, 17.992, 6.139, 17.992)
      ..cubicTo(5.685, 16.834, 5.029, 16.526, 5.029, 16.526)
      ..cubicTo(4.121, 15.906, 5.098, 15.918, 5.098, 15.918)
      ..cubicTo(6.101, 15.988, 6.628, 16.95, 6.628, 16.95)
      ..cubicTo(7.52, 18.48, 8.969, 18.038, 9.538, 17.782)
      ..cubicTo(9.63, 17.135, 9.888, 16.694, 10.174, 16.444)
      ..cubicTo(7.954, 16.191, 5.619, 15.331, 5.619, 11.493)
      ..cubicTo(5.619, 10.4, 6.009, 9.505, 6.648, 8.805)
      ..cubicTo(6.545, 8.552, 6.202, 7.533, 6.746, 6.155)
      ..cubicTo(6.746, 6.155, 7.586, 5.885, 9.496, 7.181)
      ..cubicTo(10.296, 6.959, 11.146, 6.848, 11.996, 6.844)
      ..cubicTo(12.846, 6.848, 13.696, 6.959, 14.496, 7.181)
      ..cubicTo(16.406, 5.885, 17.246, 6.155, 17.246, 6.155)
      ..cubicTo(17.79, 7.533, 17.447, 8.552, 17.344, 8.805)
      ..cubicTo(17.984, 9.505, 18.373, 10.4, 18.373, 11.493)
      ..cubicTo(18.373, 15.341, 16.034, 16.188, 13.808, 16.436)
      ..cubicTo(14.167, 16.745, 14.486, 17.356, 14.486, 18.291)
      ..cubicTo(14.486, 19.629, 14.474, 20.71, 14.474, 21.038)
      ..cubicTo(14.474, 21.306, 14.654, 21.618, 15.162, 21.52)
      ..cubicTo(19.135, 20.193, 22, 16.44, 22, 12.017)
      ..cubicTo(22, 6.484, 17.522, 2, 12, 2)
      ..close();
    canvas.drawPath(path.transform(matrix.storage), paint);
  }

  @override
  bool shouldRepaint(covariant GitHubMarkPainter oldDelegate) => oldDelegate.color != color;
}

// Custom vector painter for the modern X logo
class XMarkPainter extends CustomPainter {
  final Color color;
  const XMarkPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    final matrix = Matrix4.diagonal3Values(scale, scale, 1.0);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(18.244, 2.25)
      ..lineTo(21.552, 2.25)
      ..lineTo(14.325, 10.51)
      ..lineTo(22.827, 21.75)
      ..lineTo(16.17, 21.75)
      ..lineTo(10.956, 14.933)
      ..lineTo(4.99, 21.75)
      ..lineTo(1.68, 21.75)
      ..lineTo(9.41, 12.915)
      ..lineTo(1.254, 2.25)
      ..lineTo(8.08, 2.25)
      ..lineTo(12.793, 8.481)
      ..close();
    final hole = Path()
      ..moveTo(17.083, 19.77)
      ..lineTo(18.916, 19.77)
      ..lineTo(7.084, 4.126)
      ..lineTo(5.117, 4.126)
      ..close();
    path.addPath(hole, Offset.zero);
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path.transform(matrix.storage), paint);
  }

  @override
  bool shouldRepaint(covariant XMarkPainter oldDelegate) => oldDelegate.color != color;
}

// Custom vector painter for the Instagram camera icon
class InstagramMarkPainter extends CustomPainter {
  final Color? color;
  final bool useGradient;
  const InstagramMarkPainter({this.color, this.useGradient = false});

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = math.max(1.2, size.width * 0.09);
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.28));

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    if (useGradient) {
      borderPaint.shader = const LinearGradient(
        colors: [Color(0xFF833AB4), Color(0xFFFD1D1D), Color(0xFFFCAF45)],
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
      ).createShader(rect);
    } else {
      borderPaint.color = color ?? Colors.white;
    }

    canvas.drawRRect(rrect, borderPaint);

    final center = Offset(size.width / 2, size.height / 2);
    final circleRadius = size.width * 0.22;
    canvas.drawCircle(center, circleRadius, borderPaint);

    final dotPaint = Paint()..style = PaintingStyle.fill;
    if (useGradient) {
      dotPaint.shader = borderPaint.shader;
    } else {
      dotPaint.color = borderPaint.color;
    }
    final dotCenter = Offset(size.width * 0.74, size.height * 0.26);
    canvas.drawCircle(dotCenter, size.width * 0.055, dotPaint);
  }

  @override
  bool shouldRepaint(covariant InstagramMarkPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.useGradient != useGradient;
}

// Custom vector painter for the Google Play Store icon
class GooglePlayMarkPainter extends CustomPainter {
  const GooglePlayMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final pBlue = Path()
      ..moveTo(w * 0.08, h * 0.05)
      ..lineTo(w * 0.58, h * 0.50)
      ..lineTo(w * 0.08, h * 0.95)
      ..close();
    canvas.drawPath(pBlue, Paint()..color = const Color(0xFF00C3FF));

    final pGreen = Path()
      ..moveTo(w * 0.08, h * 0.05)
      ..lineTo(w * 0.70, h * 0.38)
      ..lineTo(w * 0.58, h * 0.50)
      ..close();
    canvas.drawPath(pGreen, Paint()..color = const Color(0xFF00E676));

    final pRed = Path()
      ..moveTo(w * 0.08, h * 0.95)
      ..lineTo(w * 0.58, h * 0.50)
      ..lineTo(w * 0.70, h * 0.62)
      ..close();
    canvas.drawPath(pRed, Paint()..color = const Color(0xFFFF334B));

    final pYellow = Path()
      ..moveTo(w * 0.58, h * 0.50)
      ..lineTo(w * 0.70, h * 0.38)
      ..lineTo(w * 0.88, h * 0.49)
      ..lineTo(w * 0.70, h * 0.62)
      ..close();
    canvas.drawPath(pYellow, Paint()..color = const Color(0xFFFFD400));
  }

  @override
  bool shouldRepaint(covariant GooglePlayMarkPainter oldDelegate) => false;
}

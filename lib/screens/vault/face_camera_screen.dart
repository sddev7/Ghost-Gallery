// ═══════════════════════════════════════════════════════════════════════════
// face_camera_screen.dart — Reusable Face Camera + Scan Overlay
//
// Used by both enrollment (captures 5 embeddings) and unlock (matches live).
// Returns:
//   • Enrollment → String (embeddings JSON) or null (cancelled)
//   • Unlock     → true (matched) / false (failed) / null (cancelled)
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../../services/face_unlock_service.dart';

enum FaceCameraMode { enrollment, unlock }

class FaceCameraScreen extends StatefulWidget {
  final FaceCameraMode mode;

  /// For unlock mode: stored embeddings JSON to match against.
  final String? storedEmbeddingsJson;

  const FaceCameraScreen({
    super.key,
    required this.mode,
    this.storedEmbeddingsJson,
  });

  @override
  State<FaceCameraScreen> createState() => _FaceCameraScreenState();
}

class _FaceCameraScreenState extends State<FaceCameraScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  CameraController? _camCtrl;
  CameraDescription? _frontCam;
  bool _initialised = false;
  bool _processing = false;
  bool _disposed = false;
  bool _streamStarted = false;
  String _status = 'Initializing camera…';
  String _subtitle = '';

  // ── Enrollment state ────────────────────────────────────────────────────
  final List<List<double>> _embeddings = [];
  static const int _needed = 5;

  // ── Unlock state ────────────────────────────────────────────────────────
  int _attempts = 0;
  static const int _maxAttempts = 40; // ~13 s of trying
  bool _matched = false;

  // ── Face detection ──────────────────────────────────────────────────────
  bool _faceDetected = false;

  // ── Throttle: process one frame every 350 ms ───────────────────────────
  DateTime _lastProcessed = DateTime(2000);
  static const _frameCooldown = Duration(milliseconds: 350);

  // ── Animations ──────────────────────────────────────────────────────────
  late final AnimationController _ringCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _successCtrl;
  late final Animation<double> _pulseAnim;
  late final Animation<double> _successScale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _successCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _successCtrl, curve: Curves.elasticOut),
    );

    _initCamera();
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopStream();
    } else if (state == AppLifecycleState.resumed) {
      _startStream();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _camCtrl?.dispose();
    _ringCtrl.dispose();
    _pulseCtrl.dispose();
    _successCtrl.dispose();
    FaceUnlockService.instance.dispose();
    super.dispose();
  }

  // ── Camera init ─────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      _frontCam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      _camCtrl = CameraController(
        _frontCam!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await _camCtrl!.initialize();
      if (_disposed) return;
      setState(() {
        _initialised = true;
        _status = widget.mode == FaceCameraMode.enrollment
            ? 'Position your face in the circle'
            : 'Looking for your face…';
        _subtitle = widget.mode == FaceCameraMode.enrollment
            ? 'Keep steady • 0/$_needed captured'
            : 'Hold still for recognition';
      });
      _startStream();
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _status = 'Camera error';
        _subtitle = '$e';
      });
    }
  }

  void _startStream() {
    if (_streamStarted || _camCtrl == null || !_camCtrl!.value.isInitialized) {
      return;
    }
    _camCtrl!.startImageStream(_onFrame);
    _streamStarted = true;
  }

  void _stopStream() {
    if (!_streamStarted || _camCtrl == null) return;
    try {
      _camCtrl!.stopImageStream();
    } catch (_) {}
    _streamStarted = false;
  }

  // ── Frame processing ───────────────────────────────────────────────────
  void _onFrame(CameraImage image) {
    if (_processing || _disposed || _matched) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < _frameCooldown) return;
    _lastProcessed = now;
    _processFrame(image);
  }

  Future<void> _processFrame(CameraImage image) async {
    _processing = true;
    try {
      final svc = FaceUnlockService.instance;
      final faces = await svc.detectFacesFromCameraImage(image, _frontCam!);
      if (_disposed) return;

      // Filter faces to avoid background false positives
      List<Face> sortedFaces = List.from(faces);
      sortedFaces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
          .compareTo(a.boundingBox.width * a.boundingBox.height));

      List<Face> significantFaces = [];
      if (sortedFaces.isNotEmpty) {
        final mainFace = sortedFaces.first;
        significantFaces.add(mainFace);
        final mainArea = mainFace.boundingBox.width * mainFace.boundingBox.height;
        for (int i = 1; i < sortedFaces.length; i++) {
          final otherFace = sortedFaces[i];
          final otherArea = otherFace.boundingBox.width * otherFace.boundingBox.height;
          // If the other face is at least 30% of the main face's area, we count it as a second face
          if (otherArea > mainArea * 0.3) {
            significantFaces.add(otherFace);
          }
        }
      }

      if (significantFaces.isEmpty) {
        if (mounted) {
          setState(() {
            _faceDetected = false;
            _status = 'No face detected';
            _subtitle = 'Position your face within the circle';
          });
        }
        return;
      }

      if (significantFaces.length > 1) {
        if (mounted) {
          setState(() {
            _faceDetected = true;
            _status = 'Multiple faces detected';
            _subtitle = 'Only one face should be visible';
          });
        }
        return;
      }

      if (mounted) setState(() => _faceDetected = true);

      final primaryFace = significantFaces.first;
      final emb = await svc.extractEmbeddingFromCameraImage(image, _frontCam!, primaryFace);
      if (_disposed || emb == null) return;

      if (widget.mode == FaceCameraMode.enrollment) {
        _onEnrollFrame(emb);
      } else {
        _onUnlockFrame(emb);
      }
    } catch (e) {
      debugPrint('FaceCameraScreen: $e');
    } finally {
      _processing = false;
    }
  }

  void _onEnrollFrame(List<double> emb) {
    _embeddings.add(emb);
    final n = _embeddings.length;
    if (n >= _needed) {
      HapticFeedback.heavyImpact();
      _matched = true;
      _stopStream();
      setState(() {
        _status = 'Face enrolled!';
        _subtitle = 'Setting up face unlock…';
      });
      _successCtrl.forward();
      Future.delayed(const Duration(milliseconds: 900), () {
        if (_disposed) return;
        Navigator.pop(context, FaceUnlockService.encodeEmbeddings(_embeddings));
      });
    } else {
      HapticFeedback.lightImpact();
      setState(() {
        _status = 'Capturing face data…';
        _subtitle = 'Keep steady • $n/$_needed captured';
      });
    }
  }

  void _onUnlockFrame(List<double> emb) {
    _attempts++;
    final stored =
        FaceUnlockService.decodeEmbeddings(widget.storedEmbeddingsJson ?? '');
    if (stored.isEmpty) {
      setState(() {
        _status = 'No enrolled face found';
        _subtitle = 'Set up face unlock in settings';
      });
      return;
    }
    if (FaceUnlockService.instance.matchEmbeddings(emb, stored)) {
      HapticFeedback.heavyImpact();
      _matched = true;
      _stopStream();
      setState(() {
        _status = 'Face recognized!';
        _subtitle = 'Unlocking vault…';
      });
      _successCtrl.forward();
      Future.delayed(const Duration(milliseconds: 900), () {
        if (_disposed) return;
        Navigator.pop(context, true);
      });
    } else if (_attempts >= _maxAttempts) {
      _stopStream();
      setState(() {
        _status = 'Face not recognized';
        _subtitle = 'Try again or use alternate method';
      });
      Future.delayed(const Duration(seconds: 2), () {
        if (_disposed) return;
        Navigator.pop(context, false);
      });
    } else {
      setState(() {
        _status = 'Scanning…';
        _subtitle = 'Hold still for recognition';
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final accent = Theme.of(context).colorScheme.secondary;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview ──────────────────────────────────────────
          if (_initialised && _camCtrl != null)
            Positioned.fill(
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _camCtrl!.value.previewSize?.height ?? 1,
                    height: _camCtrl!.value.previewSize?.width ?? 1,
                    child: CameraPreview(_camCtrl!),
                  ),
                ),
              ),
            ),

          // ── Dark overlay with circle cut-out ────────────────────────
          Positioned.fill(
            child: CustomPaint(painter: _OverlayPainter()),
          ),

          // ── Scan ring ──
          _buildScanRing(accent),

          // ── Progress dots ──
          if (widget.mode == FaceCameraMode.enrollment)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).size.height / 2 + 152,
              child: _buildProgressDots(),
            ),

          // ── Top bar ────────────────────────────────────────────────
          _buildTopBar(),

          // ── Bottom status ──────────────────────────────────────────
          _buildBottomStatus(),

          // ── Loading overlay ────────────────────────────────────────
          if (!_initialised)
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: primary, strokeWidth: 2),
                      const SizedBox(height: 16),
                      const Text('Initializing camera…',
                          style: TextStyle(color: Colors.white70, fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Sub-widgets ─────────────────────────────────────────────────────────
  Widget _buildScanRing(Color accent) {
    return Center(
      child: AnimatedBuilder(
        animation: Listenable.merge([_ringCtrl, _pulseAnim]),
        builder: (_, _) {
          final ringColor = _matched
              ? Colors.greenAccent
              : _faceDetected
                  ? accent
                  : Colors.white.withValues(alpha: 0.5);
          return SizedBox(
            width: 264,
            height: 264,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Pulsing border
                Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ringColor.withValues(alpha: _pulseAnim.value * 0.5),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: ringColor.withValues(alpha: _pulseAnim.value * 0.25),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                ),
                // Rotating arcs
                if (!_matched)
                  Transform.rotate(
                    angle: _ringCtrl.value * 2 * pi,
                    child: CustomPaint(
                      size: const Size(272, 272),
                      painter: _ArcPainter(color: ringColor),
                    ),
                  ),
                // Success check
                if (_matched)
                  ScaleTransition(
                    scale: _successScale,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.greenAccent.withValues(alpha: 0.15),
                        border: Border.all(
                            color: Colors.greenAccent, width: 3),
                      ),
                      child: const Icon(Icons.check_rounded,
                          color: Colors.greenAccent, size: 48),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildProgressDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_needed, (i) {
        final done = i < _embeddings.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: done ? 12 : 8,
          height: done ? 12 : 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? Colors.greenAccent : Colors.white24,
            boxShadow: done
                ? [BoxShadow(color: Colors.greenAccent.withValues(alpha: 0.5), blurRadius: 6)]
                : null,
          ),
        );
      }),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context, null),
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white, size: 18),
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.mode == FaceCameraMode.enrollment
                          ? Icons.face_retouching_natural
                          : Icons.lock_open_rounded,
                      color: Colors.white70,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.mode == FaceCameraMode.enrollment
                          ? 'Face Enrollment'
                          : 'Face Unlock',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomStatus() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.7),
                Colors.black.withValues(alpha: 0.9),
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  _status,
                  key: ValueKey(_status),
                  style: TextStyle(
                    color: _matched ? Colors.greenAccent : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  _subtitle,
                  key: ValueKey(_subtitle),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              if (widget.mode == FaceCameraMode.unlock && !_matched) ...[
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Use alternate method',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PAINTERS
// ═══════════════════════════════════════════════════════════════════════════

/// Dark overlay with a circular cut-out in the centre.
class _OverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const r = 130.0;
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: r))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// Two rotating gradient arcs.
class _ArcPainter extends CustomPainter {
  final Color color;
  _ArcPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.8);
    for (int i = 0; i < 2; i++) {
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: r), i * pi, pi * 0.4, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) => old.color != color;
}

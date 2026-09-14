import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../services/database_helper.dart';

class ProfileCropperScreen extends StatefulWidget {
  final String imagePath;
  final String personId;

  const ProfileCropperScreen({
    super.key,
    required this.imagePath,
    required this.personId,
  });

  @override
  State<ProfileCropperScreen> createState() => _ProfileCropperScreenState();
}

class _ProfileCropperScreenState extends State<ProfileCropperScreen> {
  ui.Image? _image;
  double _originalWidth = 0;
  double _originalHeight = 0;
  double _wLayout = 0;
  double _hLayout = 0;
  bool _loadingImage = true;
  bool _saving = false;
  final TransformationController _transformationController = TransformationController();
  double _viewportSize = 300.0;
  bool _initialized = false;
  double _containerWidth = 0;
  double _containerHeight = 0;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    _image?.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;

      _originalWidth = img.width.toDouble();
      _originalHeight = img.height.toDouble();

      setState(() {
        _image = img;
        _loadingImage = false;
      });
    } catch (e) {
      debugPrint("Error loading image for cropper: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error loading image: $e")),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _onCropConfirmed() async {
    if (_image == null || _saving) return;

    setState(() => _saving = true);

    try {
      // 1. Get transformation values
      final matrix = _transformationController.value;
      final double scale = matrix.getMaxScaleOnAxis();
      final double translationX = matrix.entry(0, 3);
      final double translationY = matrix.entry(1, 3);

      // 2. Crop box bounds in container coordinates
      final double cropBoxLeft = _containerWidth / 2 - _viewportSize / 2;
      final double cropBoxTop = _containerHeight / 2 - _viewportSize / 2;

      // 3. Map coordinates back to the layout size of the image
      final double cropLeftLayout = (cropBoxLeft - translationX) / scale;
      final double cropTopLayout = (cropBoxTop - translationY) / scale;
      final double cropWidthLayout = _viewportSize / scale;
      final double cropHeightLayout = _viewportSize / scale;

      // 4. Scale layout coordinates back to original image pixel coordinates
      final int cropX = (cropLeftLayout * (_originalWidth / _wLayout)).clamp(0.0, _originalWidth - 1).toInt();
      final int cropY = (cropTopLayout * (_originalHeight / _hLayout)).clamp(0.0, _originalHeight - 1).toInt();
      final int cropW = (cropWidthLayout * (_originalWidth / _wLayout)).clamp(1.0, _originalWidth - cropX).toInt();
      final int cropH = (cropHeightLayout * (_originalHeight / _hLayout)).clamp(1.0, _originalHeight - cropY).toInt();

      // 4. Perform the cropping on a hardware-accelerated Canvas
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        Rect.fromLTWH(0, 0, _viewportSize, _viewportSize),
      );

      canvas.drawImageRect(
        _image!,
        Rect.fromLTWH(cropX.toDouble(), cropY.toDouble(), cropW.toDouble(), cropH.toDouble()),
        Rect.fromLTWH(0, 0, _viewportSize, _viewportSize),
        Paint()
          ..isAntiAlias = true
          ..filterQuality = ui.FilterQuality.high,
      );

      final picture = recorder.endRecording();
      final croppedImage = await picture.toImage(_viewportSize.toInt(), _viewportSize.toInt());
      final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);

      if (byteData != null) {
        final pngBytes = byteData.buffer.asUint8List();

        // 5. Save the cropped PNG to a permanent directory
        final appDocDir = await getApplicationDocumentsDirectory();
        final targetDir = Directory('${appDocDir.path}/profile_pictures');
        if (!targetDir.existsSync()) {
          targetDir.createSync(recursive: true);
        }

        final targetPath = '${targetDir.path}/profile_${widget.personId}_${DateTime.now().millisecondsSinceEpoch}.png';
        final file = File(targetPath);
        await file.writeAsBytes(pngBytes, flush: true);

        // 6. Update database for the person cover image
        // Save the cover image details: cover_x=0, cover_y=0, cover_w=300, cover_h=300 since it is pre-cropped
        await DatabaseHelper.instance.updatePersonCover(
          widget.personId,
          targetPath,
          0,
          0,
          _viewportSize.toInt(),
          _viewportSize.toInt(),
          isCustomCover: true,
        );

        croppedImage.dispose();

        if (mounted) {
          Navigator.pop(context, targetPath);
        }
      } else {
        throw Exception("Failed to convert cropped image to byte data");
      }
    } catch (e) {
      debugPrint("Error cropping image: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error cropping image: $e")),
        );
      }
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Crop Profile Photo",
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        actions: [
          if (!_loadingImage)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _saving
                  ? const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : TextButton(
                      onPressed: _onCropConfirmed,
                      child: const Text(
                        "Save",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wContainer = constraints.maxWidth;
                final hContainer = constraints.maxHeight;

                if (!_initialized && !_loadingImage && _originalWidth > 0 && _originalHeight > 0) {
                  _containerWidth = wContainer;
                  _containerHeight = hContainer;
                  _viewportSize = (wContainer < 320 || hContainer < 320)
                      ? (wContainer < hContainer ? wContainer * 0.75 : hContainer * 0.75).clamp(140.0, 300.0)
                      : 300.0;

                  double imageAspectRatio = _originalWidth / _originalHeight;
                  double containerAspectRatio = wContainer / hContainer;
                  if (imageAspectRatio > containerAspectRatio) {
                    _wLayout = wContainer;
                    _hLayout = wContainer / imageAspectRatio;
                  } else {
                    _hLayout = hContainer;
                    _wLayout = hContainer * imageAspectRatio;
                  }

                  // Center the image in the container initially
                  final initialTranslationX = (wContainer - _wLayout) / 2;
                  final initialTranslationY = (hContainer - _hLayout) / 2;

                  _transformationController.value = Matrix4.identity()
                    ..translate(initialTranslationX, initialTranslationY);

                  _initialized = true;
                }

                return Stack(
                  children: [
                    Positioned.fill(
                      child: _loadingImage
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white54,
                              ),
                            )
                          : InteractiveViewer(
                              transformationController: _transformationController,
                              constrained: false,
                              minScale: 0.1,
                              maxScale: 8.0,
                              boundaryMargin: const EdgeInsets.all(400),
                              child: SizedBox(
                                width: _wLayout,
                                height: _hLayout,
                                child: Image.file(
                                  File(widget.imagePath),
                                  fit: BoxFit.fill,
                                ),
                              ),
                            ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: ViewportOverlayPainter(_viewportSize),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            color: Colors.black,
            child: const Text(
              "Drag to pan. Pinch to zoom in/out.",
              style: TextStyle(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class ViewportOverlayPainter extends CustomPainter {
  final double viewportSize;

  ViewportOverlayPainter(this.viewportSize);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;

    // Draw overlay on the entire screen, but cut out a circle in the center.
    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final cutoutPath = Path()
      ..addOval(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: viewportSize,
          height: viewportSize,
        ),
      );

    final combinedPath = Path.combine(
      PathOperation.difference,
      overlayPath,
      cutoutPath,
    );

    canvas.drawPath(combinedPath, paint);

    // Draw a thin white circular border around the cutout
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: viewportSize,
        height: viewportSize,
      ),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

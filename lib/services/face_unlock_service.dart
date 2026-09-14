// ═══════════════════════════════════════════════════════════════════════════
// face_unlock_service.dart — Face Unlock using ML Kit + MobileFaceNet
//
// Uses Google ML Kit FaceDetector for face detection in camera frames,
// then MobileFaceNet (TFLite) for 192-D face embedding extraction.
// Enrollment stores the embedding; unlock compares live embedding vs stored.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img_lib;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Result of a face unlock attempt.
enum FaceUnlockResult {
  success,
  noFaceDetected,
  multipleFacesDetected,
  faceNotRecognized,
  error,
}

class FaceUnlockService {
  FaceUnlockService._();
  static final FaceUnlockService instance = FaceUnlockService._();

  static const int _embeddingDims = 192;
  static const double _matchThreshold = 0.72; // cosine similarity threshold
  static const int _targetSize = 112; // MobileFaceNet input size
  static const double _cropPadding = 0.20;

  FaceDetector? _faceDetector;
  static Interpreter? _interpreter;

  FaceDetector _getDetector() {
    _faceDetector ??= FaceDetector(
      options: FaceDetectorOptions(
        minFaceSize: 0.15,
        enableClassification: true,
        enableContours: false,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
    return _faceDetector!;
  }

  static Future<Interpreter> _getInterpreter() async {
    if (_interpreter != null) return _interpreter!;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobile_face_net.tflite',
    );
    return _interpreter!;
  }

  /// Extract embedding for the given face from the camera image.
  /// Returns null if extraction fails.
  Future<List<double>?> extractEmbeddingFromCameraImage(CameraImage image, CameraDescription camera, Face face) async {
    try {
      // Convert camera image to img_lib.Image for embedding extraction
      final imgForEmbedding = _cameraImageToImage(image, camera);
      if (imgForEmbedding == null) return null;

      return await _extractEmbedding(imgForEmbedding, face.boundingBox);
    } catch (e) {
      debugPrint('FaceUnlockService: extractEmbeddingFromCameraImage error: $e');
      return null;
    }
  }

  /// Detect faces in a camera image.
  /// Returns list of detected face bounding boxes.
  Future<List<Face>> detectFacesFromCameraImage(CameraImage image, CameraDescription camera) async {
    try {
      final inputImage = _cameraImageToInputImage(image, camera);
      if (inputImage == null) return [];

      final detector = _getDetector();
      return await detector.processImage(inputImage);
    } catch (e) {
      debugPrint('FaceUnlockService: detectFaces error: $e');
      return [];
    }
  }

  /// Compare a live embedding against stored enrollment embeddings.
  /// Returns true if the best match exceeds the threshold.
  bool matchEmbeddings(List<double> liveEmbedding, List<List<double>> storedEmbeddings) {
    if (storedEmbeddings.isEmpty) return false;

    double bestSim = -1.0;
    for (final stored in storedEmbeddings) {
      final sim = _cosineSimilarity(liveEmbedding, stored);
      if (sim > bestSim) bestSim = sim;
    }

    debugPrint('FaceUnlockService: Best cosine similarity = $bestSim (threshold: $_matchThreshold)');
    return bestSim >= _matchThreshold;
  }

  /// Encode embeddings to JSON string for storage.
  static String encodeEmbeddings(List<List<double>> embeddings) {
    return jsonEncode(embeddings.map((e) => e.map((v) => v.toStringAsFixed(6)).toList()).toList());
  }

  /// Decode embeddings from stored JSON string.
  static List<List<double>> decodeEmbeddings(String encoded) {
    try {
      final List<dynamic> decoded = jsonDecode(encoded);
      return decoded.map<List<double>>((e) {
        return (e as List<dynamic>).map<double>((v) => double.parse(v.toString())).toList();
      }).toList();
    } catch (e) {
      debugPrint('FaceUnlockService: decodeEmbeddings error: $e');
      return [];
    }
  }

  /// Extract 192-D embedding from a cropped face region.
  Future<List<double>?> _extractEmbedding(img_lib.Image image, Rect boundingBox) async {
    try {
      final int x = boundingBox.left.round().clamp(0, image.width - 1);
      final int y = boundingBox.top.round().clamp(0, image.height - 1);
      final int w = boundingBox.width.round().clamp(1, image.width - x);
      final int h = boundingBox.height.round().clamp(1, image.height - y);

      final int padX = (w * _cropPadding).round();
      final int padY = (h * _cropPadding).round();

      final int cropX = (x - padX).clamp(0, image.width - 1);
      final int cropY = (y - padY).clamp(0, image.height - 1);
      final int cropW = (w + padX * 2).clamp(1, image.width - cropX);
      final int cropH = (h + padY * 2).clamp(1, image.height - cropY);

      final cropped = img_lib.copyCrop(
        image,
        x: cropX,
        y: cropY,
        width: cropW,
        height: cropH,
      );
      final resized = img_lib.copyResize(
        cropped,
        width: _targetSize,
        height: _targetSize,
        interpolation: img_lib.Interpolation.linear,
      );

      // Build input tensor [1, 112, 112, 3]
      final input = List.generate(
        1,
        (_) => List.generate(
          _targetSize,
          (row) => List.generate(_targetSize, (col) {
            final pixel = resized.getPixel(col, row);
            return [
              (pixel.r.toDouble() - 128.0) / 128.0,
              (pixel.g.toDouble() - 128.0) / 128.0,
              (pixel.b.toDouble() - 128.0) / 128.0,
            ];
          }),
        ),
      );

      final interpreter = await _getInterpreter();
      final output = List.generate(1, (_) => List.filled(_embeddingDims, 0.0));
      interpreter.run(input, output);

      return _l2Normalize(List<double>.from(output[0]));
    } catch (e) {
      debugPrint('FaceUnlockService: _extractEmbedding error: $e');
      return null;
    }
  }

  /// Convert CameraImage to ML Kit InputImage.
  InputImage? _cameraImageToInputImage(CameraImage image, CameraDescription camera) {
    try {
      final sensorOrientation = camera.sensorOrientation;
      InputImageRotation rotation;
      switch (sensorOrientation) {
        case 0:
          rotation = InputImageRotation.rotation0deg;
          break;
        case 90:
          rotation = InputImageRotation.rotation90deg;
          break;
        case 180:
          rotation = InputImageRotation.rotation180deg;
          break;
        case 270:
          rotation = InputImageRotation.rotation270deg;
          break;
        default:
          rotation = InputImageRotation.rotation0deg;
      }

      if (Platform.isAndroid) {
        // Concatenate all planes for NV21 format
        final WriteBuffer allBytes = WriteBuffer();
        for (final Plane plane in image.planes) {
          allBytes.putUint8List(plane.bytes);
        }
        final bytes = allBytes.done().buffer.asUint8List();

        final inputImageData = InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes.first.bytesPerRow,
        );
        return InputImage.fromBytes(
          bytes: bytes,
          metadata: inputImageData,
        );
      } else if (Platform.isIOS) {
        final bgra = image.planes.first.bytes;
        final inputImageData = InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.planes.first.bytesPerRow,
        );
        return InputImage.fromBytes(
          bytes: bgra,
          metadata: inputImageData,
        );
      }
      return null;
    } catch (e) {
      debugPrint('FaceUnlockService: _cameraImageToInputImage error: $e');
      return null;
    }
  }

  /// Convert CameraImage to img_lib.Image for embedding extraction.
  img_lib.Image? _cameraImageToImage(CameraImage image, CameraDescription camera) {
    try {
      img_lib.Image? converted;
      if (Platform.isAndroid) {
        converted = _convertYUV420ToImage(image, camera);
      } else if (Platform.isIOS) {
        converted = _convertBGRA8888ToImage(image);
      }
      
      if (converted == null) return null;

      // Rotate the image to match the sensor orientation (which matches ML Kit's rotation)
      final sensorOrientation = camera.sensorOrientation;
      if (sensorOrientation == 90) {
        return img_lib.copyRotate(converted, angle: 90);
      } else if (sensorOrientation == 180) {
        return img_lib.copyRotate(converted, angle: 180);
      } else if (sensorOrientation == 270) {
        return img_lib.copyRotate(converted, angle: 270);
      }
      return converted;
    } catch (e) {
      debugPrint('FaceUnlockService: _cameraImageToImage error: $e');
      return null;
    }
  }

  /// Convert YUV420 (Android) camera frame to img_lib.Image.
  img_lib.Image _convertYUV420ToImage(CameraImage image, CameraDescription camera) {
    final int width = image.width;
    final int height = image.height;
    final result = img_lib.Image(width: width, height: height);

    if (image.planes.length == 1) {
      // Single continuous plane (NV21 format)
      final bytes = image.planes[0].bytes;
      final int bytesPerRow = image.planes[0].bytesPerRow;
      final int uvStart = bytesPerRow * height;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int yIndex = y * bytesPerRow + x;
          // NV21 stores VU interleaved: V is at uvIndex, U is at uvIndex + 1
          final int uvIndex = uvStart + (y ~/ 2) * bytesPerRow + (x ~/ 2) * 2;

          if (yIndex >= bytes.length || uvIndex + 1 >= bytes.length) continue;

          final int yVal = bytes[yIndex];
          final int vVal = bytes[uvIndex];
          final int uVal = bytes[uvIndex + 1];

          // YUV to RGB conversion
          int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
          int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).round().clamp(0, 255);
          int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

          result.setPixelRgba(x, y, r, g, b, 255);
        }
      }
    } else {
      // 3 planes format
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int yIndex = y * yPlane.bytesPerRow + x;
          final int uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2);

          if (yIndex >= yPlane.bytes.length ||
              uvIndex >= uPlane.bytes.length ||
              uvIndex >= vPlane.bytes.length) {
            continue;
          }

          final int yVal = yPlane.bytes[yIndex];
          final int uVal = uPlane.bytes[uvIndex];
          final int vVal = vPlane.bytes[uvIndex];

          // YUV to RGB conversion
          int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
          int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).round().clamp(0, 255);
          int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

          result.setPixelRgba(x, y, r, g, b, 255);
        }
      }
    }

    return result;
  }

  /// Convert BGRA8888 (iOS) camera frame to img_lib.Image.
  img_lib.Image _convertBGRA8888ToImage(CameraImage image) {
    final plane = image.planes[0];
    final result = img_lib.Image(width: image.width, height: image.height);

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final int idx = y * plane.bytesPerRow + x * 4;
        if (idx + 3 >= plane.bytes.length) continue;
        final b = plane.bytes[idx];
        final g = plane.bytes[idx + 1];
        final r = plane.bytes[idx + 2];
        final a = plane.bytes[idx + 3];
        result.setPixelRgba(x, y, r, g, b, a);
      }
    }
    return result;
  }

  static List<double>? _l2Normalize(List<double> v) {
    double sum = 0;
    for (final x in v) {
      sum += x * x;
    }
    final double norm = sqrt(sum);
    if (norm < 1e-6) return null;
    return v.map((x) => x / norm).toList();
  }

  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return -1.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA < 1e-12 || normB < 1e-12) return -1.0;
    final similarity = dot / (sqrt(normA) * sqrt(normB));
    return similarity.clamp(-1.0, 1.0);
  }

  void dispose() {
    _faceDetector?.close();
    _faceDetector = null;
  }
}

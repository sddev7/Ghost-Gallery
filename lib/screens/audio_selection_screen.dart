import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'audio_trimmer_screen.dart';

class AudioSelectionScreen extends StatefulWidget {
  final double videoDuration;
  const AudioSelectionScreen({super.key, required this.videoDuration});

  @override
  State<AudioSelectionScreen> createState() => _AudioSelectionScreenState();
}

class _AudioSelectionScreenState extends State<AudioSelectionScreen> with SingleTickerProviderStateMixin {
  bool _isPicking = false;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _pickAudioFile() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final file = File(filePath);
        final fileName = result.files.single.name;

        if (mounted) {
          final String? trimmedPath = await Navigator.push<String>(
            context,
            MaterialPageRoute(
              builder: (_) => AudioTrimmerScreen(
                audioFile: file,
                audioTitle: fileName,
                videoDuration: widget.videoDuration,
              ),
            ),
          );

          // Clean up the original raw picked file from the file picker cache
          try {
            if (file.existsSync()) {
              file.deleteSync();
              debugPrint("AudioSelectionScreen: Deleted original picked file from cache: ${file.path}");
            }
          } catch (e) {
            debugPrint("AudioSelectionScreen: Error deleting picked file: $e");
          }

          if (trimmedPath != null && mounted) {
            Navigator.of(context).pop(trimmedPath);
          }
        }
      }
    } catch (e) {
      debugPrint("AudioSelectionScreen: Error picking audio file: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to pick audio file: $e"),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPicking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Premium theme-aligned colors
    final backgroundColor = theme.scaffoldBackgroundColor;
    final cardColor = theme.cardColor;
    final primaryTextColor = theme.colorScheme.onSurface;
    final secondaryTextColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final accentColor = theme.colorScheme.primary;
    final borderThemeColor = theme.dividerColor;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text(
          "Choose Soundtrack",
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 20,
            letterSpacing: -0.5,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: primaryTextColor, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),

              // Animated music visualization decoration
              Center(
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = 1.0 + (_pulseController.value * 0.05);
                    return Transform.scale(
                      scale: scale,
                      child: child,
                    );
                  },
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accentColor.withValues(alpha: 0.08),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: isDark ? 0.15 : 0.05),
                          blurRadius: 32,
                          spreadRadius: 8,
                        )
                      ],
                    ),
                    child: Center(
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accentColor.withValues(alpha: 0.12),
                          border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 1.5),
                        ),
                        child: Icon(
                          Icons.library_music_rounded,
                          size: 42,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // Title and subtitle instructions
              Text(
                "Add Background Music",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: primaryTextColor,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Choose an audio track from your device. You can then trim and position it to align perfectly with your slide transition beats.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: secondaryTextColor,
                ),
              ),

              const Spacer(),

              // Specifications card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: borderThemeColor.withValues(alpha: 0.5)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Target Duration",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: secondaryTextColor,
                          ),
                        ),
                        Text(
                          "${widget.videoDuration.toStringAsFixed(1)} seconds",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: primaryTextColor,
                          ),
                        ),
                      ],
                    ),
                    Divider(height: 24, color: borderThemeColor.withValues(alpha: 0.5)),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, size: 16, color: accentColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "Supports MP3, M4A, WAV, and other standard native device formats.",
                            style: TextStyle(
                              fontSize: 12,
                              color: secondaryTextColor,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Action button to browse files
              ElevatedButton(
                onPressed: _isPicking ? null : _pickAudioFile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: accentColor.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  elevation: 4,
                  shadowColor: accentColor.withValues(alpha: 0.4),
                ),
                child: _isPicking
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.folder_open_rounded, size: 20),
                          SizedBox(width: 10),
                          Text(
                            "Browse Device Music",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

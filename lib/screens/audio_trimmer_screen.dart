import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

class AudioTrimmerScreen extends StatefulWidget {
  final File audioFile;
  final String audioTitle;
  final double videoDuration;

  const AudioTrimmerScreen({
    super.key,
    required this.audioFile,
    required this.audioTitle,
    required this.videoDuration,
  });

  @override
  State<AudioTrimmerScreen> createState() => _AudioTrimmerScreenState();
}

class _AudioTrimmerScreenState extends State<AudioTrimmerScreen> with TickerProviderStateMixin {
  VideoPlayerController? _audioController;
  late ScrollController _scrollController;
  late AnimationController _rotationController;
  
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isTrimming = false;
  
  double _audioDuration = 0.0;
  double _trimStart = 0.0;
  double _currentPlayPosition = 0.0;
  
  // Fade configurations
  double _fadeInDuration = 0.0;
  double _fadeOutDuration = 0.0;

  // Waveform heights
  List<double> _waveHeights = [];
  final double _barWidth = 3.0;
  final double _barGap = 2.0;
  
  // Layout parameters (initialized dynamically in build)
  bool _layoutConfigured = false;
  double _pixelsPerSecond = 20.0;
  double _maxTrimStart = 0.0;
  double _viewportWidth = 300.0;
  double _selectionWidth = 150.0;
  double _horizontalPadding = 24.0;
  
  bool _isScrollingProgrammatically = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    _initializePlayer();
  }

  @override
  void dispose() {
    _audioController?.removeListener(_onPlayUpdate);
    _audioController?.dispose();
    _scrollController.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  Future<void> _initializePlayer() async {
    final controller = VideoPlayerController.file(widget.audioFile);
    _audioController = controller;

    try {
      await controller.initialize();
      _audioDuration = controller.value.duration.inMilliseconds / 1000.0;
      
      _trimStart = 0.0;
      _currentPlayPosition = 0.0;

      setState(() {
        _isInitialized = true;
      });

      controller.addListener(_onPlayUpdate);
      await controller.seekTo(Duration(milliseconds: (_trimStart * 1000).toInt()));
    } catch (e) {
      debugPrint("AudioTrimmerScreen: Failed to initialize audio player: $e");
    }
  }

  void _onPlayUpdate() {
    if (_audioController == null || !mounted) return;
    
    final currentPos = _audioController!.value.position.inMilliseconds / 1000.0;
    final trimEnd = _trimStart + widget.videoDuration;

    // Loop within trim window
    if (currentPos >= trimEnd || currentPos >= _audioDuration) {
      _audioController!.seekTo(Duration(milliseconds: (_trimStart * 1000).toInt()));
    }

    final playing = _audioController!.value.isPlaying;
    if (playing != _isPlaying) {
      setState(() {
        _isPlaying = playing;
      });
      if (playing) {
        _rotationController.repeat();
      } else {
        _rotationController.stop();
      }
    }

    setState(() {
      _currentPlayPosition = _audioController!.value.position.inMilliseconds / 1000.0;
    });
  }

  Future<void> _togglePlay() async {
    if (_audioController == null || !_isInitialized) return;

    if (_isPlaying) {
      await _audioController!.pause();
    } else {
      // Seek to start of trim window if outside it
      final currentPos = _audioController!.value.position.inMilliseconds / 1000.0;
      final trimEnd = _trimStart + widget.videoDuration;
      if (currentPos < _trimStart || currentPos > trimEnd) {
        await _audioController!.seekTo(Duration(milliseconds: (_trimStart * 1000).toInt()));
      }
      await _audioController!.play();
    }
  }

  void _nudgeTrim(double amount) {
    final target = (_trimStart + amount).clamp(0.0, _maxTrimStart);
    if (target != _trimStart) {
      setState(() {
        _trimStart = target;
        _currentPlayPosition = target;
      });
      
      _isScrollingProgrammatically = true;
      _scrollController.animateTo(
        target * _pixelsPerSecond,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      ).then((_) {
        _isScrollingProgrammatically = false;
      });
      
      _audioController?.seekTo(Duration(milliseconds: (target * 1000).toInt()));
    }
  }

  List<double> _generateWaveformHeights(String title, double duration) {
    // Generate deterministic heights using a hash of the title and duration
    final int seed = title.hashCode ^ (duration * 100).toInt();
    final random = math.Random(seed);
    
    final int barCount = ((duration * _pixelsPerSecond) / (_barWidth + _barGap)).ceil();
    final heights = List<double>.generate(barCount, (index) {
      // Create a nice organic wave look by combining sine waves and noise
      final double angle1 = index * 0.08;
      final double angle2 = index * 0.22;
      final double base = 0.25 + 0.45 * (math.sin(angle1) * math.cos(angle2)).abs();
      final double noise = random.nextDouble() * 0.25;
      return (base + noise).clamp(0.06, 0.95);
    });
    
    return heights;
  }

  String _formatTime(double seconds) {
    final int m = seconds ~/ 60;
    final double s = seconds % 60;
    return "$m:${s.toStringAsFixed(1).padLeft(4, '0')}";
  }

  void _configureLayout(double screenWidth) {
    if (_layoutConfigured) return;
    
    _viewportWidth = screenWidth - 48; // 24 padding on each side
    
    // We want the selection box to take up 65% of the viewport width
    double desiredSelectionWidth = _viewportWidth * 0.65;
    
    // Calculate pixels per second based on the video duration
    _pixelsPerSecond = desiredSelectionWidth / widget.videoDuration;
    
    // Clamp pixelsPerSecond to reasonable values (between 8 and 45 px/sec)
    _pixelsPerSecond = _pixelsPerSecond.clamp(8.0, 45.0);
    
    _selectionWidth = widget.videoDuration * _pixelsPerSecond;
    _horizontalPadding = (_viewportWidth - _selectionWidth) / 2;
    _maxTrimStart = (_audioDuration - widget.videoDuration).clamp(0.0, _audioDuration);
    
    // Generate waveform heights
    _waveHeights = _generateWaveformHeights(widget.audioTitle, _audioDuration);
    
    _layoutConfigured = true;
    
    // Set up scroll listener once layout is set
    _scrollController.addListener(() {
      if (!_isScrollingProgrammatically && mounted) {
        final newTrimStart = _scrollController.offset / _pixelsPerSecond;
        final clampedTrimStart = newTrimStart.clamp(0.0, _maxTrimStart);
        
        if (clampedTrimStart != _trimStart) {
          setState(() {
            _trimStart = clampedTrimStart;
            _currentPlayPosition = clampedTrimStart;
          });
          
          // Live seek
          _audioController?.seekTo(Duration(milliseconds: (clampedTrimStart * 1000).toInt()));
        }
      }
    });

    // Jump to the initial trim start
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _isScrollingProgrammatically = true;
        _scrollController.jumpTo(_trimStart * _pixelsPerSecond);
        _isScrollingProgrammatically = false;
      }
    });
  }

  Future<void> _trimAudio() async {
    if (_isTrimming) return;

    setState(() {
      _isTrimming = true;
    });

    await _audioController?.pause();

    try {
      final tempDir = await getTemporaryDirectory();
      // Use .m4a output container since we encode with AAC (MP3 container is incompatible with AAC)
      final outPath = "${tempDir.path}/trimmed_${DateTime.now().millisecondsSinceEpoch}.m4a";

      final double durationToTrim = widget.videoDuration.clamp(0.0, _audioDuration);
      
      // Enforce max fade duration constraints (each fade duration cannot exceed half of trimmed segment)
      double fadeIn = _fadeInDuration;
      double fadeOut = _fadeOutDuration;
      final maxFade = durationToTrim / 2.0;
      if (fadeIn > maxFade) fadeIn = maxFade;
      if (fadeOut > maxFade) fadeOut = maxFade;

      final List<String> args = [
        '-y',
        '-ss', _trimStart.toString(),
        '-t', durationToTrim.toString(),
        '-i', widget.audioFile.path,
      ];

      if (fadeIn > 0 || fadeOut > 0) {
        String filterVal = '';
        if (fadeIn > 0 && fadeOut > 0) {
          final fadeOutStart = durationToTrim - fadeOut;
          filterVal = 'afade=t=in:st=0:d=$fadeIn,afade=t=out:st=$fadeOutStart:d=$fadeOut';
        } else if (fadeIn > 0) {
          filterVal = 'afade=t=in:st=0:d=$fadeIn';
        } else if (fadeOut > 0) {
          final fadeOutStart = durationToTrim - fadeOut;
          filterVal = 'afade=t=out:st=$fadeOutStart:d=$fadeOut';
        }
        args.addAll(['-af', filterVal]);
      }

      args.addAll([
        '-vn', // Discard any embedded video/mjpeg streams (like album cover pictures)
        '-c:a', 'aac',
        '-b:a', '192k',
        outPath,
      ]);

      debugPrint("AudioTrimmerScreen: Running FFmpeg with args: $args");
      final session = await FFmpegKit.executeWithArguments(args);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        if (mounted) {
          Navigator.of(context).pop(outPath);
        }
      } else {
        debugPrint("AudioTrimmerScreen: FFmpeg failed with code: $returnCode");
        
        // Print the FFmpeg logs to standard output for debugging
        final logs = await session.getLogs();
        for (final log in logs) {
          debugPrint("FFmpeg Log: ${log.getMessage()}");
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Failed to trim song. Please try another range.")),
          );
        }
        setState(() {
          _isTrimming = false;
        });
      }
    } catch (e) {
      debugPrint("AudioTrimmerScreen: Trim error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
      setState(() {
        _isTrimming = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Premium Design Palette
    final backgroundColor = isDark ? const Color(0xFF09090F) : const Color(0xFFF4F5FC);
    final cardColor = isDark ? const Color(0xFF13141E) : Colors.white;
    final primaryTextColor = isDark ? Colors.white : const Color(0xFF1E2030);
    final secondaryTextColor = isDark ? Colors.white70 : const Color(0xFF5A5E73);
    final accentColor = const Color(0xFFD32F2F); // Glowing Premium Red
    final neonHighlightColor = const Color(0xFFFF5252);
    
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text(
          "Trim Sound",
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, letterSpacing: -0.5),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: primaryTextColor, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_isInitialized && !_isTrimming)
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: TextButton(
                onPressed: _trimAudio,
                child: Text(
                  "Apply",
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _isTrimming
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: accentColor, strokeWidth: 3),
                    const SizedBox(height: 28),
                    Text(
                      "Processing Audio Track...",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: primaryTextColor,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Applying fade transitions & formatting output",
                      style: TextStyle(
                        fontSize: 13,
                        color: secondaryTextColor,
                      ),
                    ),
                  ],
                ),
              )
            : !_isInitialized
                ? Center(
                    child: CircularProgressIndicator(color: accentColor, strokeWidth: 3),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      _configureLayout(constraints.maxWidth);
                      
                      final double totalWaveformWidth = (_audioDuration * _pixelsPerSecond) + (_horizontalPadding * 2);
                      final double playheadOffset = ((_currentPlayPosition - _trimStart).clamp(0.0, widget.videoDuration) / widget.videoDuration) * _selectionWidth;

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 1. Vinyl Record disc rotation art card
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                              decoration: BoxDecoration(
                                color: cardColor,
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  )
                                ],
                              ),
                              child: Row(
                                children: [
                                  // Rotating Vinyl
                                  RotationTransition(
                                    turns: _rotationController,
                                    child: Container(
                                      width: 76,
                                      height: 76,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black,
                                        boxShadow: [
                                          BoxShadow(
                                            color: accentColor.withValues(alpha: 0.35),
                                            blurRadius: 16,
                                            spreadRadius: 1,
                                          )
                                        ],
                                        gradient: RadialGradient(
                                          colors: [
                                            Colors.grey[850]!,
                                            Colors.black,
                                            Colors.grey[900]!,
                                            Colors.black,
                                          ],
                                          stops: const [0.0, 0.45, 0.75, 1.0],
                                        ),
                                      ),
                                      child: Center(
                                        child: Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: accentColor.withValues(alpha: 0.12),
                                            border: Border.all(color: accentColor, width: 2),
                                          ),
                                          child: Icon(
                                            Icons.music_note,
                                            size: 15,
                                            color: neonHighlightColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  // Track Meta info
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.audioTitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w800,
                                            color: primaryTextColor,
                                            letterSpacing: -0.3,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Icon(Icons.video_library_rounded, size: 14, color: secondaryTextColor),
                                            const SizedBox(width: 6),
                                            Text(
                                              "Target Duration: ${widget.videoDuration.toStringAsFixed(1)}s",
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: secondaryTextColor,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            const SizedBox(height: 24),

                            // 2. Large Time Display readout
                            Center(
                              child: Column(
                                children: [
                                  Text(
                                    "${_formatTime(_currentPlayPosition - _trimStart)} / ${_formatTime(widget.videoDuration)}",
                                    style: TextStyle(
                                      fontSize: 34,
                                      fontWeight: FontWeight.w900,
                                      fontFamily: 'Courier', // Elegant monospaced feel
                                      color: primaryTextColor,
                                      letterSpacing: -1.0,
                                      shadows: isDark
                                          ? [
                                              Shadow(
                                                color: neonHighlightColor.withValues(alpha: 0.4),
                                                blurRadius: 10,
                                              )
                                            ]
                                          : [],
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        "Trim Offset: ${_formatTime(_trimStart)}",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: secondaryTextColor,
                                        ),
                                      ),
                                      Text(
                                        "  •  ",
                                        style: TextStyle(color: secondaryTextColor.withValues(alpha: 0.5)),
                                      ),
                                      Text(
                                        "Ends at: ${_formatTime(_trimStart + widget.videoDuration)}",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: secondaryTextColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            
                            const SizedBox(height: 20),

                            // 3. Interactive Waveform Workspace (Center of page)
                            Container(
                              height: 140,
                              decoration: BoxDecoration(
                                color: cardColor.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.04),
                                ),
                              ),
                              child: Stack(
                                children: [
                                  // Scrollable Waveform
                                  Positioned.fill(
                                    child: NotificationListener<ScrollNotification>(
                                      onNotification: (ScrollNotification notification) {
                                        if (notification is ScrollStartNotification) {
                                          if (_isPlaying) {
                                            _togglePlay();
                                          }
                                        }
                                        return false;
                                      },
                                      child: SingleChildScrollView(
                                        controller: _scrollController,
                                        scrollDirection: Axis.horizontal,
                                        physics: const BouncingScrollPhysics(),
                                        child: SizedBox(
                                          width: totalWaveformWidth,
                                          height: 140,
                                          child: CustomPaint(
                                            size: Size(totalWaveformWidth, 140),
                                            painter: WaveformPainter(
                                              waveHeights: _waveHeights,
                                              barWidth: _barWidth,
                                              barGap: _barGap,
                                              trimStart: _trimStart,
                                              videoDuration: widget.videoDuration,
                                              pixelsPerSecond: _pixelsPerSecond,
                                              paddingOffset: _horizontalPadding,
                                              audioDuration: _audioDuration,
                                              activeColor: neonHighlightColor,
                                              inactiveColor: isDark ? Colors.white.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.15),
                                              isDark: isDark,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Active Trim Selection Frame Overlay (Centered)
                                  Positioned(
                                    left: _horizontalPadding - 6,
                                    top: 10,
                                    bottom: 25,
                                    child: IgnorePointer(
                                      child: Row(
                                        children: [
                                          // Left crop boundary handle
                                          Container(
                                            width: 6,
                                            decoration: BoxDecoration(
                                              color: accentColor,
                                              borderRadius: const BorderRadius.only(
                                                topLeft: Radius.circular(6),
                                                bottomLeft: Radius.circular(6),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: accentColor.withValues(alpha: 0.4),
                                                  blurRadius: 8,
                                                  offset: const Offset(-2, 0),
                                                )
                                              ],
                                            ),
                                            child: Center(
                                              child: Container(
                                                width: 1.5,
                                                height: 16,
                                                color: Colors.white70,
                                              ),
                                            ),
                                          ),
                                          
                                          // The Selection Box middle frame
                                          Container(
                                            width: _selectionWidth,
                                            decoration: BoxDecoration(
                                              border: Border.symmetric(
                                                horizontal: BorderSide(
                                                  color: accentColor.withValues(alpha: 0.7),
                                                  width: 1.5,
                                                ),
                                              ),
                                              color: Colors.transparent,
                                            ),
                                          ),

                                          // Right crop boundary handle
                                          Container(
                                            width: 6,
                                            decoration: BoxDecoration(
                                              color: accentColor,
                                              borderRadius: const BorderRadius.only(
                                                topRight: Radius.circular(6),
                                                bottomRight: Radius.circular(6),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: accentColor.withValues(alpha: 0.4),
                                                  blurRadius: 8,
                                                  offset: const Offset(2, 0),
                                                )
                                              ],
                                            ),
                                            child: Center(
                                              child: Container(
                                                width: 1.5,
                                                height: 16,
                                                color: Colors.white70,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Playhead indicator vertical line
                                  Positioned(
                                    left: _horizontalPadding + playheadOffset,
                                    top: 10,
                                    bottom: 25,
                                    child: IgnorePointer(
                                      child: Column(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              color: Colors.white,
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black45,
                                                  blurRadius: 3,
                                                  spreadRadius: 1,
                                                )
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            child: Container(
                                              width: 1.8,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            const SizedBox(height: 16),

                            // 4. Fine-tuning & Playback Control row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Nudge Left panel
                                Row(
                                  children: [
                                    _buildNudgeButton(
                                      icon: Icons.double_arrow_rounded,
                                      label: "-1s",
                                      onPressed: () => _nudgeTrim(-1.0),
                                      isLeft: true,
                                      isDark: isDark,
                                    ),
                                    const SizedBox(width: 8),
                                    _buildNudgeButton(
                                      icon: Icons.keyboard_arrow_left_rounded,
                                      label: "-0.1s",
                                      onPressed: () => _nudgeTrim(-0.1),
                                      isLeft: true,
                                      isDark: isDark,
                                    ),
                                  ],
                                ),

                                // Main Playback circular button
                                GestureDetector(
                                  onTap: _togglePlay,
                                  child: Container(
                                    width: 60,
                                    height: 60,
                                    decoration: BoxDecoration(
                                      color: accentColor,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: accentColor.withValues(alpha: 0.4),
                                          blurRadius: 16,
                                          offset: const Offset(0, 6),
                                        )
                                      ],
                                    ),
                                    child: Icon(
                                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 32,
                                    ),
                                  ),
                                ),

                                // Nudge Right panel
                                Row(
                                  children: [
                                    _buildNudgeButton(
                                      icon: Icons.keyboard_arrow_right_rounded,
                                      label: "+0.1s",
                                      onPressed: () => _nudgeTrim(0.1),
                                      isLeft: false,
                                      isDark: isDark,
                                    ),
                                    const SizedBox(width: 8),
                                    _buildNudgeButton(
                                      icon: Icons.double_arrow_rounded,
                                      label: "+1s",
                                      onPressed: () => _nudgeTrim(1.0),
                                      isLeft: false,
                                      isDark: isDark,
                                    ),
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 24),

                            // 5. Audio Fades Configuration Card
                            Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: cardColor,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.02),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  )
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.tune_rounded, size: 18, color: accentColor),
                                      const SizedBox(width: 8),
                                      Text(
                                        "Transitions & Fades",
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          color: primaryTextColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  
                                  // Fade In row
                                  _buildFadeSlider(
                                    label: "Fade In Duration",
                                    value: _fadeInDuration,
                                    icon: Icons.trending_up_rounded,
                                    isDark: isDark,
                                    accentColor: accentColor,
                                    onChanged: (val) {
                                      setState(() {
                                        _fadeInDuration = val;
                                      });
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  
                                  // Fade Out row
                                  _buildFadeSlider(
                                    label: "Fade Out Duration",
                                    value: _fadeOutDuration,
                                    icon: Icons.trending_down_rounded,
                                    isDark: isDark,
                                    accentColor: accentColor,
                                    onChanged: (val) {
                                      setState(() {
                                        _fadeOutDuration = val;
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  Widget _buildNudgeButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool isLeft,
    required bool isDark,
  }) {
    final textColor = isDark ? Colors.white70 : const Color(0xFF5A5E73);
    final buttonBg = isDark ? const Color(0xFF161722) : Colors.white;
    final borderCol = isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05);

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: buttonBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderCol),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLeft)
              Transform.rotate(
                angle: icon == Icons.double_arrow_rounded ? math.pi : 0,
                child: Icon(icon, size: 14, color: textColor),
              ),
            const SizedBox(width: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            if (!isLeft)
              Icon(icon, size: 14, color: textColor),
          ],
        ),
      ),
    );
  }

  Widget _buildFadeSlider({
    required String label,
    required double value,
    required IconData icon,
    required bool isDark,
    required Color accentColor,
    required ValueChanged<double> onChanged,
  }) {
    final labelColor = isDark ? Colors.white70 : const Color(0xFF5A5E73);
    return Row(
      children: [
        Icon(icon, size: 18, color: labelColor.withValues(alpha: 0.7)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    ),
                  ),
                  Text(
                    "${value.toStringAsFixed(1)}s",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: accentColor,
                  inactiveTrackColor: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                  thumbColor: accentColor,
                  overlayColor: accentColor.withValues(alpha: 0.15),
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                ),
                child: Slider(
                  value: value,
                  min: 0.0,
                  max: 5.0,
                  divisions: 10,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> waveHeights;
  final double barWidth;
  final double barGap;
  final double trimStart;
  final double videoDuration;
  final double pixelsPerSecond;
  final double paddingOffset;
  final double audioDuration;
  final Color activeColor;
  final Color inactiveColor;
  final bool isDark;

  final TextPainter textPainter = TextPainter(
    textDirection: TextDirection.ltr,
  );

  WaveformPainter({
    required this.waveHeights,
    required this.barWidth,
    required this.barGap,
    required this.trimStart,
    required this.videoDuration,
    required this.pixelsPerSecond,
    required this.paddingOffset,
    required this.audioDuration,
    required this.activeColor,
    required this.inactiveColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw Waveform Ticks
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    final double midY = (size.height - 25) / 2 + 10;
    final double maxBarHeight = size.height - 45;
    final int count = waveHeights.length;
    final double step = barWidth + barGap;

    for (int i = 0; i < count; i++) {
      final double x = paddingOffset + i * step;
      final double height = waveHeights[i] * maxBarHeight;

      // Determine active region
      final double selectionStart = paddingOffset + trimStart * pixelsPerSecond;
      final double selectionEnd = selectionStart + videoDuration * pixelsPerSecond;

      final bool isActive = x >= selectionStart && x <= selectionEnd;
      paint.color = isActive ? activeColor : inactiveColor;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, midY),
            width: barWidth,
            height: height.clamp(3.0, maxBarHeight),
          ),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }

    // 2. Draw ruler timeline ticks at the bottom
    final double ticksY = size.height - 20;
    final double tickSpacing = 5.0 * pixelsPerSecond;
    final int numTicks = (audioDuration / 5).floor() + 1;
    
    final tickPaint = Paint()
      ..color = isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.18)
      ..strokeWidth = 1.0;
      
    for (int t = 0; t < numTicks; t++) {
      final double tickX = paddingOffset + t * tickSpacing;
      
      // Draw minor ticks
      canvas.drawLine(
        Offset(tickX, ticksY),
        Offset(tickX, ticksY + 5),
        tickPaint,
      );
      
      // Label major ticks (every 10s)
      if (t % 2 == 0) {
        final textSpan = TextSpan(
          text: _formatRulerTime(t * 5.0),
          style: TextStyle(
            color: isDark ? Colors.white.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.4),
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        );
        textPainter.text = textSpan;
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(tickX - textPainter.width / 2, ticksY - 14),
        );
      }
    }
  }

  String _formatRulerTime(double seconds) {
    final int m = seconds ~/ 60;
    final int s = (seconds % 60).toInt();
    return "$m:${s.toString().padLeft(2, '0')}";
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.trimStart != trimStart ||
        oldDelegate.videoDuration != videoDuration ||
        oldDelegate.audioDuration != audioDuration ||
        oldDelegate.waveHeights != waveHeights ||
        oldDelegate.isDark != isDark;
  }
}

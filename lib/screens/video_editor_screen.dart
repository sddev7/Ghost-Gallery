import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';

class VideoEditorPage extends StatefulWidget {
  final String videoUrl;
  final Function(String) onSave;
  final String? initialTool;

  const VideoEditorPage({
    super.key,
    required this.videoUrl,
    required this.onSave,
    this.initialTool,
  });

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  final _editorKey = GlobalKey<ProImageEditorState>();
  final bool _saving = false;

  ProVideoController? _proVideoController;
  late VideoMetadata _metadata;
  late VideoPlayerController _videoController;

  List<ImageProvider>? _thumbnails;
  final int _thumbnailCount = 7;

  bool _isSeeking = false;
  TrimDurationSpan? _durationSpan;
  TrimDurationSpan? _tempDurationSpan;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 1. Load Metadata
    final editorVideo = widget.videoUrl.startsWith('http')
        ? EditorVideo.network(widget.videoUrl)
        : EditorVideo.file(widget.videoUrl);

    _metadata = await ProVideoEditor.instance.getMetadata(editorVideo);

    // 2. Initialize VideoPlayerController
    _videoController = widget.videoUrl.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl))
        : VideoPlayerController.file(File(widget.videoUrl));

    await _videoController.initialize();
    await _videoController.setLooping(false);
    await _videoController.setVolume(100);
    await _videoController.pause();

    // 3. Generate Thumbnails (so the frames show in the trim/timeline section!)
    try {
      final imageWidth = MediaQuery.sizeOf(context).width / _thumbnailCount * MediaQuery.devicePixelRatioOf(context);
      final duration = _metadata.duration;
      final segmentDuration = duration.inMilliseconds / _thumbnailCount;
      
      final thumbnailList = await ProVideoEditor.instance.getThumbnails(
        ThumbnailConfigs(
          video: editorVideo,
          outputSize: Size.square(imageWidth),
          boxFit: ThumbnailBoxFit.cover,
          timestamps: List.generate(_thumbnailCount, (i) {
            final midpointMs = (i + 0.5) * segmentDuration;
            return Duration(milliseconds: midpointMs.round());
          }),
          outputFormat: ThumbnailFormat.jpeg,
        ),
      );
      
      _thumbnails = thumbnailList.map(MemoryImage.new).toList();
      var cacheList = _thumbnails!.map((item) => precacheImage(item, context));
      await Future.wait(cacheList);
    } catch (e) {
      debugPrint("Error generating editor thumbnails: $e");
    }

    if (!mounted) return;

    // 4. Create ProVideoController
    final controller = ProVideoController(
      initialResolution: _metadata.resolution,
      videoDuration: _metadata.duration,
      fileSize: _metadata.fileSize,
      videoPlayer: _buildVideoPlayer(),
      thumbnails: _thumbnails,
    );

    setState(() => _proVideoController = controller);

    _videoController.addListener(_onDurationChange);

    _proVideoController?.initialize(
      configsFunction: () => const VideoEditorConfigs(
        initialMuted: false,
        initialPlay: false,
        isAudioSupported: true,
        minTrimDuration: Duration(seconds: 1),
      ),
      callbacksFunction: () => VideoEditorCallbacks(),
      callbacksAudioFunction: () => const AudioEditorCallbacks(),
    );
  }

  void _onDurationChange() {
    if (_proVideoController == null || !mounted) return;
    final duration = _videoController.value.position;
    _proVideoController!.setPlayTime(duration);

    if (_durationSpan != null && duration >= _durationSpan!.end) {
      _seekToPosition(_durationSpan!);
    } else if (duration >= _metadata.duration) {
      _seekToPosition(
        TrimDurationSpan(start: Duration.zero, end: _metadata.duration),
      );
    }
  }

  Future<void> _seekToPosition(TrimDurationSpan span) async {
    _durationSpan = span;

    if (_isSeeking) {
      _tempDurationSpan = span;
      return;
    }
    _isSeeking = true;

    _proVideoController?.pause();
    _proVideoController?.setPlayTime(_durationSpan!.start);

    await _videoController.pause();
    await _videoController.seekTo(span.start);

    _isSeeking = false;

    if (_tempDurationSpan != null) {
      final nextSeek = _tempDurationSpan!;
      _tempDurationSpan = null;
      await _seekToPosition(nextSeek);
    }
  }

  @override
  void dispose() {
    _videoController.removeListener(_onDurationChange);
    _videoController.dispose();
    _proVideoController?.dispose();
    super.dispose();
  }

  Widget _buildVideoPlayer() {
    return Center(
      child: AspectRatio(
        aspectRatio: _videoController.value.size.aspectRatio,
        child: VideoPlayer(_videoController),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editorVideo = widget.videoUrl.startsWith('http')
        ? EditorVideo.network(widget.videoUrl)
        : EditorVideo.file(widget.videoUrl);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Editor'),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _proVideoController == null
              ? const Center(child: CircularProgressIndicator())
              : ProImageEditor.video(
                  _proVideoController!,
                  key: _editorKey,
                  configs: ProImageEditorConfigs(
                    theme: ThemeData(
                      useMaterial3: true,
                      brightness: Theme.of(context).brightness,
                      colorScheme: Theme.of(context).colorScheme,
                      scaffoldBackgroundColor: Theme.of(context).scaffoldBackgroundColor,
                      appBarTheme: AppBarTheme(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    mainEditor: MainEditorConfigs(
                      tools: [
                        SubEditorMode.cropRotate,
                        SubEditorMode.tune,
                        SubEditorMode.filter,
                        SubEditorMode.blur,
                      ],
                    ),
                    videoEditor: const VideoEditorConfigs(
                      initialMuted: false,
                      initialPlay: false,
                      isAudioSupported: true,
                    ),
                  ),
                  callbacks: ProImageEditorCallbacks(
                    onCloseEditor: (mode) {
                      if (mode == EditorMode.main && mounted) Navigator.pop(context);
                    },
                    videoEditorCallbacks: VideoEditorCallbacks(
                      onPause: _videoController.pause,
                      onPlay: _videoController.play,
                      onMuteToggle: (isMuted) {
                        _videoController.setVolume(isMuted ? 0 : 100);
                      },
                      onTrimSpanUpdate: (durationSpan) {
                        if (_videoController.value.isPlaying) {
                          _proVideoController?.pause();
                        }
                      },
                      onTrimSpanEnd: _seekToPosition,
                    ),
                    onCompleteWithParameters: (params) async {
                      try {
                        LoadingDialog.instance.hide();
                      } catch (e) {
                        debugPrint("Error hiding loading dialog: $e");
                      }
                      final renderData = VideoRenderData(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        videoSegments: [
                          VideoSegment(
                            video: editorVideo,
                            volume: 1,
                          ),
                        ],
                        outputFormat: VideoOutputFormat.mp4,
                        enableAudio: true,
                        colorFilters: const [],
                        startTime: params.startTime,
                        endTime: params.endTime,
                        transform: params.isTransformed
                            ? ExportTransform(
                                width: params.cropWidth,
                                height: params.cropHeight,
                                rotateTurns: params.rotateTurns,
                                x: params.cropX,
                                y: params.cropY,
                                flipX: params.flipX,
                                flipY: params.flipY,
                              )
                            : null,
                      );

                      final tempDir = await getTemporaryDirectory();
                      final outPath = '${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.mp4';

                      // Show modern FLAT UI exporting progress dialog
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (dialogCtx) {
                          return StreamBuilder<ProgressModel>(
                            stream: ProVideoEditor.instance.progressStreamById(renderData.id),
                            builder: (context, snapshot) {
                              double progress = 0.0;
                              if (snapshot.hasData) {
                                progress = snapshot.data!.progress; // 0.0 to 1.0
                              }
                              final percent = (progress * 100).toInt();

                              return AlertDialog(
                                backgroundColor: Theme.of(context).colorScheme.surface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                title: const Text(
                                  'Exporting Video',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 16),
                                    SizedBox(
                                      width: 80,
                                      height: 80,
                                      child: CircularProgressIndicator(
                                        value: progress > 0 ? progress : null,
                                        strokeWidth: 6,
                                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    Text(
                                      '$percent%',
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Please wait while we render your edits...',
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      );

                      String? outputPath;
                      try {
                        outputPath = await ProVideoEditor.instance.renderVideoToFile(
                          outPath,
                          renderData,
                        );
                      } catch (e) {
                        debugPrint("Error rendering video: $e");
                      } finally {
                        // Dismiss progress dialog
                        if (mounted) {
                          Navigator.pop(context);
                        }
                      }

                      if (outputPath != null) {
                        widget.onSave(outputPath);
                      }
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

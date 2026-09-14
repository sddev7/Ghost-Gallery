import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import '../screens/tabs/video_preview_widget.dart';

class AlbumSlideshowBackground extends StatefulWidget {
  final List<GalleryItem> items;

  const AlbumSlideshowBackground({
    super.key,
    required this.items,
  });

  @override
  State<AlbumSlideshowBackground> createState() => _AlbumSlideshowBackgroundState();
}

class _AlbumSlideshowBackgroundState extends State<AlbumSlideshowBackground> {
  List<GalleryItem> _slideshowItems = [];
  int _currentIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _setupItems();
    if (_slideshowItems.isNotEmpty) {
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(covariant AlbumSlideshowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items != oldWidget.items) {
      _setupItems();
      if (_slideshowItems.isNotEmpty && _timer == null) {
        _startTimer();
      } else if (_slideshowItems.isEmpty) {
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  void _setupItems() {
    if (widget.items.isEmpty) {
      _slideshowItems = [];
      return;
    }
    // Take a random selection of up to 12 items for the background slideshow to keep it performant
    final random = Random();
    final allItems = List<GalleryItem>.from(widget.items);
    allItems.shuffle(random);
    _slideshowItems = allItems.take(12).toList();
    _currentIndex = 0;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 7), (timer) {
      if (!mounted || _slideshowItems.length <= 1) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % _slideshowItems.length;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_slideshowItems.isEmpty) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF130F40), // Obsidian midnight violet
              Color(0xFF000000),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    final currentItem = _slideshowItems[_currentIndex];

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 1500),
      switchInCurve: Curves.easeIn,
      switchOutCurve: Curves.easeOut,
      layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ...previousChildren,
            ?currentChild,
          ],
        );
      },
      child: KenBurnsImage(
        key: ValueKey<String>('${currentItem.id}_$_currentIndex'),
        item: currentItem,
      ),
    );
  }
}

class KenBurnsImage extends StatefulWidget {
  final GalleryItem item;

  const KenBurnsImage({
    required this.item,
    super.key,
  });

  @override
  State<KenBurnsImage> createState() => _KenBurnsImageState();
}

class _KenBurnsImageState extends State<KenBurnsImage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<Alignment> _alignmentAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    final random = Random();
    
    // Animate scale between 1.05 and 1.25 for a noticeable but smooth zoom
    final zoomIn = random.nextBool();
    _scaleAnimation = Tween<double>(
      begin: zoomIn ? 1.05 : 1.25,
      end: zoomIn ? 1.25 : 1.05,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    // Pan within a safe range to prevent showing black edges at scale >= 1.05
    final double startX = (random.nextDouble() * 0.4) - 0.2;
    final double startY = (random.nextDouble() * 0.4) - 0.2;
    final double endX = (random.nextDouble() * 0.4) - 0.2;
    final double endY = (random.nextDouble() * 0.4) - 0.2;

    _alignmentAnimation = AlignmentTween(
      begin: Alignment(startX, startY),
      end: Alignment(endX, endY),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = File(widget.item.imageUrl);
    final isVideo = widget.item.mediaType == 'video';

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox.expand(
          child: ClipRect(
            child: Transform.scale(
              scale: _scaleAnimation.value,
              alignment: _alignmentAnimation.value,
              child: isVideo
                  ? VideoPreviewWidget(
                      videoPath: widget.item.imageUrl,
                      assetId: widget.item.id,
                      fit: BoxFit.cover,
                      maxWidth: 800,
                      quality: 60,
                    )
                  : (file.existsSync()
                      ? Image.file(
                          file,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Color(0xFF130F40),
                                Color(0xFF000000),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                        )),
            ),
          ),
        );
      },
    );
  }
}


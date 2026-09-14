import 'package:flutter/material.dart';

class KenBurnsWrapper extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final int index;
  final bool isPaused;
  final bool isFaceZoomInOut;
  final Alignment? faceAlignment;
  final double faceZoomScale;

  const KenBurnsWrapper({
    super.key,
    required this.child,
    required this.duration,
    required this.index,
    this.isPaused = false,
    this.isFaceZoomInOut = false,
    this.faceAlignment,
    this.faceZoomScale = 1.4,
  });

  @override
  State<KenBurnsWrapper> createState() => _KenBurnsWrapperState();
}

class _KenBurnsWrapperState extends State<KenBurnsWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<Alignment> _alignmentAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _setupAnimation();

    if (widget.isPaused) {
      _controller.stop();
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant KenBurnsWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.duration != widget.duration ||
        oldWidget.isFaceZoomInOut != widget.isFaceZoomInOut ||
        oldWidget.faceAlignment != widget.faceAlignment) {
      _controller.duration = widget.duration;
      _setupAnimation();
      if (widget.isPaused) {
        _controller.forward(from: 0.0);
        _controller.stop();
      } else {
        _controller.forward(from: 0.0);
      }
    } else if (oldWidget.isPaused != widget.isPaused) {
      if (widget.isPaused) {
        _controller.stop();
      } else {
        _controller.forward();
      }
    }
  }

  void _setupAnimation() {
    if (widget.isFaceZoomInOut) {
      final targetAlign = widget.faceAlignment ?? Alignment.center;
      _scaleAnimation = TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween<double>(begin: 1.0, end: widget.faceZoomScale)
              .chain(CurveTween(curve: Curves.easeInOutCubic)),
          weight: 50,
        ),
        TweenSequenceItem(
          tween: Tween<double>(begin: widget.faceZoomScale, end: 1.0)
              .chain(CurveTween(curve: Curves.easeInOutCubic)),
          weight: 50,
        ),
      ]).animate(_controller);

      _alignmentAnimation = TweenSequence<Alignment>([
        TweenSequenceItem(
          tween: AlignmentTween(begin: Alignment.center, end: targetAlign)
              .chain(CurveTween(curve: Curves.easeInOutCubic)),
          weight: 50,
        ),
        TweenSequenceItem(
          tween: AlignmentTween(begin: targetAlign, end: Alignment.center)
              .chain(CurveTween(curve: Curves.easeInOutCubic)),
          weight: 50,
        ),
      ]).animate(_controller);
      return;
    }

    // Deterministically choose zoom style and alignments based on index
    final int style = widget.index % 4;
    double startScale;
    double endScale;
    Alignment startAlign;
    Alignment endAlign;

    switch (style) {
      case 0:
        // Zoom In to Top Left
        startScale = 1.0;
        endScale = 1.25;
        startAlign = Alignment.center;
        endAlign = const Alignment(-0.5, -0.5); // Top Left
        break;
      case 1:
        // Zoom Out from Bottom Right
        startScale = 1.25;
        endScale = 1.0;
        startAlign = const Alignment(0.5, 0.5); // Bottom Right
        endAlign = Alignment.center;
        break;
      case 2:
        // Zoom In to Bottom Left
        startScale = 1.0;
        endScale = 1.25;
        startAlign = Alignment.center;
        endAlign = const Alignment(-0.5, 0.5); // Bottom Left
        break;
      case 3:
      default:
        // Zoom Out from Top Right
        startScale = 1.25;
        endScale = 1.0;
        startAlign = const Alignment(0.5, -0.5); // Top Right
        endAlign = Alignment.center;
        break;
    }

    _scaleAnimation = Tween<double>(
      begin: startScale,
      end: endScale,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _alignmentAnimation = AlignmentTween(
      begin: startAlign,
      end: endAlign,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ClipRect(
          child: Transform.scale(
            scale: _scaleAnimation.value,
            alignment: _alignmentAnimation.value,
            child: widget.child,
          ),
        );
      },
    );
  }
}

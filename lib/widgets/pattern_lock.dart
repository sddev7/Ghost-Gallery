import 'package:flutter/material.dart';

class PatternLock extends StatefulWidget {
  final int dimension;
  final Function(List<int> points) onSelect;
  final Function(List<int> points) onComplete;
  final List<int> initialPoints;

  const PatternLock({
    super.key,
    this.dimension = 3,
    required this.onSelect,
    required this.onComplete,
    this.initialPoints = const [],
  });

  @override
  State<PatternLock> createState() => _PatternLockState();
}

class _PatternLockState extends State<PatternLock> {
  final List<int> _points = [];
  Offset? _currentTouchPoint;

  @override
  void initState() {
    super.initState();
    _points.addAll(widget.initialPoints);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double size = constraints.maxWidth;
        // Make the drawing area square and centered if height constraint is smaller
        final double drawSize = size;
        final double dotSpacing = drawSize / (widget.dimension + 1);

        return GestureDetector(
          onPanStart: (details) {
            setState(() {
              _points.clear();
              _currentTouchPoint = details.localPosition;
            });
            _checkTouchPoint(details.localPosition, dotSpacing, drawSize);
          },
          onPanUpdate: (details) {
            setState(() {
              _currentTouchPoint = details.localPosition;
            });
            _checkTouchPoint(details.localPosition, dotSpacing, drawSize);
          },
          onPanEnd: (details) {
            widget.onComplete(List.from(_points));
            setState(() {
              _currentTouchPoint = null;
            });
          },
          child: Container(
            color: Colors.transparent, // Ensures the entire area catches drag events
            width: drawSize,
            height: drawSize,
            child: CustomPaint(
              size: Size(drawSize, drawSize),
              painter: _PatternPainter(
                points: _points,
                currentTouchPoint: _currentTouchPoint,
                dimension: widget.dimension,
                dotSpacing: dotSpacing,
                primaryColor: Theme.of(context).colorScheme.primary,
                accentColor: Theme.of(context).colorScheme.secondary,
                textColor: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        );
      },
    );
  }

  void _checkTouchPoint(Offset localPosition, double dotSpacing, double totalSize) {
    final int dim = widget.dimension;
    final double hitRadius = dotSpacing * 0.45;

    for (int i = 0; i < dim * dim; i++) {
      final int row = i ~/ dim;
      final int col = i % dim;
      
      // Calculate dot center using a 1-based index spacing so dots are padded inside the canvas
      final double cx = (col + 1) * dotSpacing;
      final double cy = (row + 1) * dotSpacing;

      final double distance = (localPosition.dx - cx) * (localPosition.dx - cx) +
          (localPosition.dy - cy) * (localPosition.dy - cy);

      if (distance < hitRadius * hitRadius) {
        if (!_points.contains(i)) {
          setState(() {
            _points.add(i);
          });
          widget.onSelect(List.from(_points));
        }
      }
    }
  }
}

class _PatternPainter extends CustomPainter {
  final List<int> points;
  final Offset? currentTouchPoint;
  final int dimension;
  final double dotSpacing;
  final Color primaryColor;
  final Color accentColor;
  final Color textColor;

  _PatternPainter({
    required this.points,
    required this.currentTouchPoint,
    required this.dimension,
    required this.dotSpacing,
    required this.primaryColor,
    required this.accentColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double bgDotRadius = dotSpacing * 0.11;
    final double activeDotRadius = dotSpacing * 0.086;
    final double activeGlowRadius = dotSpacing * 0.228;
    final double strokeWidth = dotSpacing * 0.071;

    final bgDotPaint = Paint()
      ..color = textColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    // Draw the grid dots
    for (int i = 0; i < dimension * dimension; i++) {
      final int row = i ~/ dimension;
      final int col = i % dimension;
      final double cx = (col + 1) * dotSpacing;
      final double cy = (row + 1) * dotSpacing;
      canvas.drawCircle(Offset(cx, cy), bgDotRadius, bgDotPaint);
    }

    if (points.isEmpty) return;

    // Line drawing setup
    final linePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.9)
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final activeDotPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;

    Path path = Path();
    for (int idx = 0; idx < points.length; idx++) {
      final int val = points[idx];
      final int row = val ~/ dimension;
      final int col = val % dimension;
      final double cx = (col + 1) * dotSpacing;
      final double cy = (row + 1) * dotSpacing;

      // Draw active dots with a beautiful inner dot and outer glow
      canvas.drawCircle(Offset(cx, cy), activeGlowRadius, glowPaint);
      canvas.drawCircle(Offset(cx, cy), activeDotRadius, activeDotPaint);

      if (idx == 0) {
        path.moveTo(cx, cy);
      } else {
        path.lineTo(cx, cy);
      }
    }

    // Trailing line segment to current finger location
    if (currentTouchPoint != null && points.isNotEmpty) {
      final int lastVal = points.last;
      final int row = lastVal ~/ dimension;
      final int col = lastVal % dimension;
      final double cx = (col + 1) * dotSpacing;
      final double cy = (row + 1) * dotSpacing;
      
      canvas.drawPath(path, linePaint);
      canvas.drawLine(Offset(cx, cy), currentTouchPoint!, linePaint);
    } else {
      canvas.drawPath(path, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter oldDelegate) => true;
}

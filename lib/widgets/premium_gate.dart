import 'package:flutter/material.dart';

class PremiumGate extends StatelessWidget {
  final Widget child;
  final double blurSigma;
  final double lockIconSize;
  final BorderRadius? borderRadius;

  const PremiumGate({
    super.key,
    required this.child,
    this.blurSigma = 8.0,
    this.lockIconSize = 24.0,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) => child;
}

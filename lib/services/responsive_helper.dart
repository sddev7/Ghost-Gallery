import 'package:flutter/material.dart';

enum ScreenType { watch, mobile, tablet, tv }

class ResponsiveHelper {
  static const double watchBreakpoint = 300.0;
  static const double tabletBreakpoint = 600.0;
  static const double tvBreakpoint = 1024.0;

  static ScreenType getScreenType(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < watchBreakpoint) return ScreenType.watch;
    if (width < tabletBreakpoint) return ScreenType.mobile;
    if (width < tvBreakpoint) return ScreenType.tablet;
    return ScreenType.tv;
  }

  static bool isWatch(BuildContext context) =>
      MediaQuery.sizeOf(context).width < watchBreakpoint;

  static bool isMobile(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= watchBreakpoint && width < tabletBreakpoint;
  }

  static bool isTablet(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= tabletBreakpoint && width < tvBreakpoint;
  }

  static bool isTV(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= tvBreakpoint;

  static int responsiveGridColumns(
    BuildContext context, {
    int baseColumns = 3,
    int? watch,
    int? mobile,
    int? tablet,
    int? tv,
    int min = 1,
    int max = 10,
  }) {
    final type = getScreenType(context);
    switch (type) {
      case ScreenType.watch:
        if (watch != null) return watch.clamp(min, max);
        break;
      case ScreenType.mobile:
        if (mobile != null) return mobile.clamp(min, max);
        break;
      case ScreenType.tablet:
        if (tablet != null) return tablet.clamp(min, max);
        break;
      case ScreenType.tv:
        if (tv != null) return tv.clamp(min, max);
        break;
    }
    final width = MediaQuery.sizeOf(context).width;
    if (width < 220) return 1;
    if (width < watchBreakpoint) return 2.clamp(min, max);
    if (width < tabletBreakpoint) return baseColumns.clamp(min, max);
    if (width < tvBreakpoint) {
      return (width / 140).floor().clamp(3, max);
    }
    return (width / 160).floor().clamp(4, max);
  }

  static double responsivePadding(
    BuildContext context, {
    double watch = 8,
    double mobile = 16,
    double tablet = 24,
    double tv = 32,
  }) {
    final type = getScreenType(context);
    switch (type) {
      case ScreenType.watch:
        return watch;
      case ScreenType.mobile:
        return mobile;
      case ScreenType.tablet:
        return tablet;
      case ScreenType.tv:
        return tv;
    }
  }

  static double responsiveFontSize(BuildContext context, double baseSize) {
    if (isWatch(context)) return (baseSize * 0.75).clamp(10.0, 24.0);
    if (isTV(context)) return (baseSize * 1.15).clamp(12.0, 48.0);
    return baseSize;
  }

  static T responsiveValue<T>(
    BuildContext context, {
    required T mobile,
    T? watch,
    T? tablet,
    T? tv,
  }) {
    final type = getScreenType(context);
    switch (type) {
      case ScreenType.watch:
        return watch ?? mobile;
      case ScreenType.mobile:
        return mobile;
      case ScreenType.tablet:
        return tablet ?? mobile;
      case ScreenType.tv:
        return tv ?? tablet ?? mobile;
    }
  }
}

class ResponsiveContainer extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  const ResponsiveContainer({
    super.key,
    required this.child,
    this.maxWidth = 800,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final mediaPadding = padding ??
        EdgeInsets.symmetric(
          horizontal: ResponsiveHelper.responsivePadding(context),
        );
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: mediaPadding,
          child: child,
        ),
      ),
    );
  }
}

extension ResponsiveContext on BuildContext {
  bool get isWatch => ResponsiveHelper.isWatch(this);
  bool get isMobile => ResponsiveHelper.isMobile(this);
  bool get isTablet => ResponsiveHelper.isTablet(this);
  bool get isTV => ResponsiveHelper.isTV(this);
  ScreenType get screenType => ResponsiveHelper.getScreenType(this);
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;
  T responsive<T>({required T mobile, T? watch, T? tablet, T? tv}) =>
      ResponsiveHelper.responsiveValue(
        this,
        mobile: mobile,
        watch: watch,
        tablet: tablet,
        tv: tv,
      );
}

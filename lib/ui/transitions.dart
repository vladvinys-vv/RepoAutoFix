import 'package:flutter/material.dart';

// Shared route transitions for the whole app.
// Pass these directly as `PageRouteBuilder.transitionsBuilder` so every
// screen pushes and pops with the same motion.

/// Content/detail pages: quick fade with a subtle rise.
Widget fadeRiseTransition(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
  final Animation<double> curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0.0, 0.045), end: Offset.zero).animate(curved),
      child: child,
    ),
  );
}

/// Modal-like pages (settings, editors, onboarding): rise from the bottom
/// with a fade instead of a hard full-height slide.
Widget slideUpTransition(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
  final Animation<double> curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0.0, 0.15), end: Offset.zero).animate(curved),
      child: child,
    ),
  );
}

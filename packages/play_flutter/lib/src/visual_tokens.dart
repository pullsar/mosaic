import 'package:flutter/material.dart';

abstract final class MosaicVisualTokens {
  static const Color surface = Color(0xFF090909);
  static const Color foreground = Color(0xFFF7F7F7);
  static const Color secondary = Color(0xB3FFFFFF);
  static const Color controlSurface = Color(0x70000000);
  static const double controlRadius = 22;
  static const double horizontalInset = 20;
  static const Duration fastFeedback = Duration(milliseconds: 140);
  static const Duration revealTransition = Duration(milliseconds: 180);
  static const Offset revealDisplacement = Offset(0, 0.04);
}

abstract final class MosaicTextBudget {
  static const int promptWords = 14;
  static const int scenarioWords = 24;
}

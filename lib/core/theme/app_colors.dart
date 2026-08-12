import 'package:flutter/material.dart';

/// Industrial palette for FactoryFlow — PRD Ch. 9
class AppColors {
  AppColors._();

  // Brand — deeper, more confident steel blue
  static const Color steelBlue = Color(0xFF2B4C7E);
  static const Color steelBlueLight = Color(0xFF4A6FA5);
  static const Color steelBlueMid = Color(0xFF3D5A80);

  // Semantic
  static const Color amberAlert = Color(0xFFE09F3E);
  static const Color dangerRed = Color(0xFFCF3030);
  static const Color successGreen = Color(0xFF1E9E8F);
  static const Color warningAmber = Color(0xFFF59E0B);

  // Light theme
  // Warm, low-contrast surfaces keep data-heavy factory screens calm while
  // semantic colors remain reserved for actual operational meaning.
  static const Color lightBackground = Color(0xFFF7F7F5);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFF1F2F0);
  static const Color lightOnSurface = Color(0xFF0F1923);
  static const Color lightBorder = Color(0xFFE2E8F0);

  // Dark theme
  static const Color darkBackground = Color(0xFF0D1117);
  static const Color darkSurface = Color(0xFF161B22);
  static const Color darkSurfaceVariant = Color(0xFF21262D);
  static const Color darkSurfaceElevated = Color(0xFF2D333B);
  static const Color darkOnSurface = Color(0xFFE6EDF3);
  static const Color darkBorder = Color(0xFF30363D);

  // Stock stage colors
  static const Color rawMaterial = Color(0xFF6B9080);
  static const Color bpStock = Color(0xFF2B4C7E);
  static const Color atFaco = Color(0xFFE09F3E);
  static const Color pendingAp = Color(0xFFF4A261);
  static const Color approvedAp = Color(0xFF1E9E8F);
  static const Color rtvStock = Color(0xFFCF3030);
}

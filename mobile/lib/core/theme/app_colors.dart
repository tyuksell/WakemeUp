import 'package:flutter/material.dart';

class AppColors {
  // Neon Accents
  static const Color neonCyan = Color(0xFF00F2FE);
  static const Color neonBlue = Color(0xFF4FACFE);
  static const Color neonPink = Color(0xFFFF0844);
  static const Color neonOrange = Color(0xFFFFB199);
  
  // Theme Backgrounds
  static const Color darkBg = Color(0xFF0B0C10);
  static const Color darkCard = Color(0xFF1F2833);
  static const Color lightBg = Color(0xFFF4F6F9);
  static const Color lightCard = Color(0xFFFFFFFF);

  // Text Colors
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textDark = Color(0xFF1F2833);
  static const Color textGrey = Color(0xFFC5C6C7);

  // Gradients
  static const Gradient neonBlueCyan = LinearGradient(
    colors: [neonBlue, neonCyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const Gradient neonPinkOrange = LinearGradient(
    colors: [neonPink, neonOrange],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

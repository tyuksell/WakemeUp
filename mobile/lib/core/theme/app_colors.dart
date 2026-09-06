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

  // Text Colors
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textGrey = Color(0xFFC5C6C7);
  // Açıklama/tagline metinleri için daha yumuşak, "premium" ikincil ton.
  static const Color textSecondary = Color(0xFF9CA3AF);
  // Tarih, adres gibi üçüncül/meta bilgiler için en soluk ton.
  static const Color textMuted = Color(0xFF7C8592);

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

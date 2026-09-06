import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  /// Başlıklar ve öne çıkan sayılar (uygulama adı, büyük mesafe okuması,
  /// buton etiketleri) için karakterli görüntü fontu.
  static TextStyle sora({
    required Color color,
    required double fontSize,
    FontWeight fontWeight = FontWeight.w700,
    double? letterSpacing,
  }) =>
      GoogleFonts.sora(color: color, fontSize: fontSize, fontWeight: fontWeight, letterSpacing: letterSpacing);

  static ThemeData get darkTheme {
    // Manrope, tema genelinde varsayılan gövde fontu olarak kullanılır;
    // Sora yalnızca headlineMedium'da (bkz. sora() yardımcı fonksiyonu diğer yerlerde) devreye girer.
    final manropeFamily = GoogleFonts.manrope().fontFamily;

    return ThemeData(
      brightness: Brightness.dark,
      fontFamily: manropeFamily,
      scaffoldBackgroundColor: AppColors.darkBg,
      primaryColor: AppColors.neonBlue,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.neonBlue,
        secondary: AppColors.neonCyan,
        error: AppColors.neonPink,
        surface: AppColors.darkCard,
      ),
      cardTheme: CardThemeData(
        color: AppColors.darkCard,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      appBarTheme: AppBarTheme(
        titleTextStyle: sora(color: AppColors.textWhite, fontSize: 19),
      ),
      textTheme: TextTheme(
        headlineMedium: sora(color: AppColors.textWhite, fontSize: 28, fontWeight: FontWeight.w800),
        bodyLarge: GoogleFonts.manrope(color: AppColors.textWhite, fontSize: 16),
        bodyMedium: GoogleFonts.manrope(color: AppColors.textGrey, fontSize: 14),
      ),
    );
  }
}

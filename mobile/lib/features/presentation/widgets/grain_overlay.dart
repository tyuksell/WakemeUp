import 'package:flutter/material.dart';

/// Koyu arka planlara ince bir film grain dokusu ekler (premium/derinlik hissi).
/// Etkileşimi engellememesi için [IgnorePointer] içinde, çok düşük opaklıkta
/// döşenmiş küçük bir gürültü görseli kullanır.
class GrainOverlay extends StatelessWidget {
  const GrainOverlay({super.key, this.opacity = 0.035});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Image.asset(
            'assets/noise.png',
            repeat: ImageRepeat.repeat,
            filterQuality: FilterQuality.none,
          ),
        ),
      ),
    );
  }
}

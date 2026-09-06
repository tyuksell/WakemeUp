import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../widgets/neon_button.dart';
import '../widgets/grain_overlay.dart';
import 'map_page.dart';
import 'settings_page.dart';
import 'history_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient blobs for a premium modern feel
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.neonBlue.withOpacity(isDark ? 0.15 : 0.08),
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            right: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.neonCyan.withOpacity(isDark ? 0.15 : 0.08),
              ),
            ),
          ),

          const GrainOverlay(),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Geçmiş Rotalar',
                    icon: const Icon(Icons.history_rounded, color: AppColors.textSecondary),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const HistoryPage()),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Alarm Eşikleri',
                    icon: const Icon(Icons.tune_rounded, color: AppColors.textSecondary),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const SettingsPage()),
                    ),
                  ),
                ],
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  // Premium Logo / Visual Branding
                  Center(
                    child: Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.neonBlue.withValues(alpha: 0.3),
                            blurRadius: 40,
                            offset: const Offset(0, 15),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/logo.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Text(
                    'WakeMeUp',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: 30,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Rotanızı belirleyin, anlık takiplerinizi yapın ve yaklaştığınızdan haberdar olun.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
                      height: 1.65,
                    ),
                  ),
                  const Spacer(),
                  
                  // Center Button
                  NeonButton(
                    text: 'Rota Belirle',
                    onTap: () {
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder: (context, animation, secondaryAnimation) => const MapPage(),
                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
                            var begin = const Offset(0.0, 1.0);
                            var end = Offset.zero;
                            var curve = Curves.easeOutCubic;
                            var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                            return SlideTransition(
                              position: animation.drive(tween),
                              child: child,
                            );
                          },
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Devam etmek için konum izni gereklidir',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

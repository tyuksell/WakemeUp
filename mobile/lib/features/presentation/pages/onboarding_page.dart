import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/hive_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../l10n/app_localizations.dart';
import '../widgets/grain_overlay.dart';
import '../widgets/neon_button.dart';
import 'home_page.dart';

class _OnboardingSlide {
  final IconData icon;
  final Color color;
  final String title;
  final String description;

  const _OnboardingSlide({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
  });
}

List<_OnboardingSlide> _buildSlides(AppLocalizations l10n) => [
      _OnboardingSlide(
        icon: Icons.alarm_on_rounded,
        color: AppColors.neonBlue,
        title: l10n.onboardingSlide1Title,
        description: l10n.onboardingSlide1Description,
      ),
      _OnboardingSlide(
        icon: Icons.location_on_rounded,
        color: AppColors.neonCyan,
        title: l10n.onboardingSlide2Title,
        description: l10n.onboardingSlide2Description,
      ),
      _OnboardingSlide(
        icon: Icons.notifications_active_rounded,
        color: AppColors.neonOrange,
        title: l10n.onboardingSlide3Title,
        description: l10n.onboardingSlide3Description,
      ),
    ];

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    // Bildirim izni burada, düşük sürtünmeli bir adımda istenir; konum ve
    // pil optimizasyonu izinleri ise ilk rota başlatıldığında (bkz.
    // RouteLauncher) bağlama uygun şekilde ayrıca istenir.
    await NotificationService.requestPermissions();
    await HiveService.setHasSeenOnboarding(true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final slides = _buildSlides(l10n);
    final bool isLastSlide = _index == slides.length - 1;

    return Scaffold(
      body: Stack(
        children: [
          const GrainOverlay(),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: TextButton(
                      onPressed: _finish,
                      child: Text(l10n.onboardingSkip, style: const TextStyle(color: AppColors.textMuted)),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: slides.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) {
                      final slide = slides[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                color: slide.color.withOpacity(0.12),
                                shape: BoxShape.circle,
                                border: Border.all(color: slide.color.withOpacity(0.4), width: 1.5),
                              ),
                              child: Icon(slide.icon, color: slide.color, size: 44),
                            ),
                            const SizedBox(height: 32),
                            Text(
                              slide.title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              slide.description,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 14,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(slides.length, (i) {
                    final active = i == _index;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: active ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: active ? slides[_index].color : Colors.white24,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: NeonButton(
                    text: isLastSlide ? l10n.onboardingStart : l10n.onboardingContinue,
                    onTap: () {
                      if (isLastSlide) {
                        _finish();
                      } else {
                        _controller.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

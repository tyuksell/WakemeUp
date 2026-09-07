import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/hive_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';
import '../widgets/grain_overlay.dart';
import '../widgets/center_toast.dart';

/// Kademeli alarmın hangi mesafelerde tetikleneceğini kullanıcının
/// ayarlamasını sağlar. Değerler yalnızca yeni başlatılan rotalara uygulanır;
/// zaten takip edilmekte olan bir rota kendi eşiklerini korur.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  double _farM = 1000;
  double _midM = 500;
  double _nearM = 250;
  double _alarmVolume = 1.0;
  bool _alarmVibrate = true;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final thresholds = await HiveService.getThresholds();
    final volume = await HiveService.getAlarmVolume();
    final vibrate = await HiveService.getAlarmVibrate();
    if (!mounted) return;
    setState(() {
      _farM = thresholds.farM.toDouble();
      _midM = thresholds.midM.toDouble();
      _nearM = thresholds.nearM.toDouble();
      _alarmVolume = volume;
      _alarmVibrate = vibrate;
      _isLoading = false;
    });
  }

  /// Ses düzeyi ve titreşim tercihinin, mesafe eşiklerinin aksine geçerlilik
  /// kontrolüne ihtiyacı yok — bu yüzden "Kaydet" düğmesini beklemeden
  /// değiştirildikleri anda kaydedilirler.
  Future<void> _setAlarmVolume(double value) async {
    setState(() => _alarmVolume = value);
    await HiveService.setAlarmVolume(value);
  }

  Future<void> _setAlarmVibrate(bool value) async {
    setState(() => _alarmVibrate = value);
    await HiveService.setAlarmVibrate(value);
  }

  bool get _isValid => _farM > _midM && _midM > _nearM;

  Future<void> _save() async {
    if (!_isValid) return;
    setState(() => _isSaving = true);
    await HiveService.setThresholds(AlarmThresholds(
      farM: _farM.round(),
      midM: _midM.round(),
      nearM: _nearM.round(),
    ));
    if (!mounted) return;
    setState(() => _isSaving = false);
    CenterToast.show(
      context,
      message: 'Alarm eşikleri kaydedildi. Yeni rotalarda geçerli olacak.',
      type: ToastType.success,
    );
    Navigator.pop(context);
  }

  String _formatMeters(double m) {
    if (m >= 1000) return '${(m / 1000).toStringAsFixed(2)} km';
    return '${m.round()} m';
  }

  Widget _buildSlider({
    required String label,
    required Color color,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            ),
            const SizedBox(width: 8),
            Text(
              _formatMeters(value),
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: color,
            thumbColor: color,
            overlayColor: color.withValues(alpha: 0.2),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / 25).round(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarm Eşikleri'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          const GrainOverlay(),
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'WakeMeUp, hedefinize yaklaştıkça üç aşamada sizi uyarır. '
                      'Bu mesafeleri kendi tercihinize göre ayarlayabilirsiniz.',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.6),
                    ),
                    const SizedBox(height: 24),
                    GlassCard(
                      child: Column(
                        children: [
                          _buildSlider(
                            label: 'Uzak Mesafe Uyarısı',
                            color: AppColors.neonBlue,
                            value: _farM,
                            min: 500,
                            max: 5000,
                            onChanged: (v) => setState(() => _farM = v),
                          ),
                          const SizedBox(height: 16),
                          _buildSlider(
                            label: 'Orta Mesafe Uyarısı',
                            color: AppColors.neonCyan,
                            value: _midM,
                            min: 100,
                            max: 3000,
                            onChanged: (v) => setState(() => _midM = v),
                          ),
                          const SizedBox(height: 16),
                          _buildSlider(
                            label: 'Yakın Mesafe Uyarısı (Yüksek Öncelikli)',
                            color: AppColors.neonPink,
                            value: _nearM,
                            min: 50,
                            max: 1500,
                            onChanged: (v) => setState(() => _nearM = v),
                          ),
                        ],
                      ),
                    ),
                    if (!_isValid)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text(
                          'Uzak mesafe > orta mesafe > yakın mesafe olmalıdır.',
                          style: TextStyle(color: AppColors.neonPink, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 36),
                    const Text(
                      'Alarm Sesi ve Titreşim',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Değişiklikler anında kaydedilir.',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.volume_up_rounded, color: AppColors.neonOrange, size: 20),
                                  SizedBox(width: 10),
                                  Text('Alarm Ses Düzeyi',
                                      style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                                ],
                              ),
                              Text(
                                '${(_alarmVolume * 100).round()}%',
                                style: const TextStyle(
                                    color: AppColors.neonOrange, fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ],
                          ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: AppColors.neonOrange,
                              thumbColor: AppColors.neonOrange,
                              overlayColor: AppColors.neonOrange.withValues(alpha: 0.2),
                              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                            ),
                            child: Slider(
                              value: _alarmVolume.clamp(0.1, 1.0),
                              min: 0.1,
                              max: 1.0,
                              divisions: 9,
                              onChanged: _setAlarmVolume,
                            ),
                          ),
                          const Divider(height: 24, color: Colors.white12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.vibration_rounded, color: AppColors.neonOrange, size: 20),
                                  SizedBox(width: 10),
                                  Text('Alarm Titreşimi',
                                      style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                                ],
                              ),
                              Switch(
                                value: _alarmVibrate,
                                activeThumbColor: AppColors.neonOrange,
                                onChanged: _setAlarmVibrate,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    _isSaving
                        ? const Center(child: CircularProgressIndicator())
                        : Opacity(
                            opacity: _isValid ? 1.0 : 0.4,
                            child: IgnorePointer(
                              ignoring: !_isValid,
                              child: NeonButton(text: 'Kaydet', onTap: _save),
                            ),
                          ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

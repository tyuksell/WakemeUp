import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/hive_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/services/background_service.dart';
import '../../../../core/utils/constants.dart';
import '../widgets/glass_card.dart';
import '../widgets/hold_to_confirm_button.dart';
import '../widgets/grain_overlay.dart';
import '../widgets/center_toast.dart';
import 'home_page.dart';
import '../../../l10n/app_localizations.dart';

/// Susturma onaylandıktan sonra, geri alınamaz eylemler (backend'e "bir daha
/// asla tetikleme" bildirimi, servisi durdurma) uygulanmadan önce kullanıcıya
/// tanınan "Geri Al" penceresi.
const _kMuteUndoWindow = Duration(seconds: 5);

class TrackingPage extends StatefulWidget {
  const TrackingPage({super.key});

  @override
  State<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends State<TrackingPage> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  String _destinationName = "Hedef";

  /// null: GPS'ten henüz gerçek mesafe gelmedi → UI'da "Hesaplanıyor..." gösterilir.
  /// Sıfır olmayan ilk gerçek değer geldiğinde null olmaktan çıkar.
  double? _distanceMeters;

  bool _isMuted = false;

  /// Hold-to-confirm susturma onaylandı ama "Geri Al" penceresi henüz dolmadı.
  /// Bu sırada tracking/backend/Hive durumu HİÇ değişmemiştir — bu yüzden geri
  /// alma tamamen ücretsizdir (bkz. _confirmMute / _cancelPendingMute).
  bool _mutePending = false;
  Timer? _muteUndoTimer;

  /// `alarm` paketinden gelen, o an çalmakta olan bir alarm var mı bilgisi.
  bool _alarmIsRinging = false;
  StreamSubscription<AlarmSet>? _alarmRingingSub;

  /// Arka plan servisi, GPS sinyali zayıf/kaybolmuşsa (kötü doğruluk ya da
  /// uzun süredir hiç konum gelmemesi) bunu bildirir — ör. tünel/metro.
  bool _gpsSignalWeak = false;

  /// Varış noktasına ulaşıldığında (mesafe <= 5m) true olur.
  /// Takip devam eder; yalnızca UI etiketi gösterilir.
  bool _hasArrived = false;

  /// İlerleme çubuğu için başlangıç mesafesi.
  /// Yalnızca sıfırdan büyük ilk gerçek GPS mesafesiyle set edilir.
  /// Hardcoded 1000.0 KULLANILMIYOR.
  double? _initialDistance;

  // Hız bilgisi kaldırıldı

  Timer? _syncTimer;
  int _syncRetryCount = 0;
  bool _syncFailed = false;

  @override
  void initState() {
    super.initState();
    _loadInitialState();
    _setupBackgroundListener();

    _alarmIsRinging = Alarm.ringing.value.alarms.isNotEmpty;
    _alarmRingingSub = Alarm.ringing.listen((alarmSet) {
      if (!mounted) return;
      setState(() => _alarmIsRinging = alarmSet.alarms.isNotEmpty);
    });

    // Arka plan servisinden taze veri iste (eğer zaten çalışıyorsa)
    _triggerSync();

    // Dayanıklı tasarım: Mesafe hesaplanana kadar exponential backoff ile 'sync' isteğini tekrarla.
    _startSyncTimer();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _muteUndoTimer?.cancel();
    _alarmRingingSub?.cancel();
    super.dispose();
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    if (_distanceMeters != null) return;

    if (_syncRetryCount >= 10) {
      debugPrint(
        '[TrackingPage] Konum verisi alınamadı (Maksimum deneme sınırına ulaşıldı).',
      );
      if (mounted) {
        setState(() {
          _syncFailed = true;
        });
      }
      return;
    }

    final delaySeconds = (1 << _syncRetryCount).clamp(1, 30);
    _syncTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_distanceMeters == null) {
        _syncRetryCount++;
        debugPrint(
          '[TrackingPage] Mesafe henüz gelmedi, sync tetikleniyor... (Deneme: $_syncRetryCount, Sonraki gecikme: ${delaySeconds}s)',
        );
        _triggerSync();
        _startSyncTimer();
      }
    });
  }

  Future<void> _triggerSync() async {
    final routeId = await HiveService.getActiveRouteId() ?? kOfflineRouteId;
    final name = await HiveService.getDestName() ?? l10n.commonDefaultDestination;
    final lat = await HiveService.getDestLatitude() ?? 0.0;
    final lng = await HiveService.getDestLongitude() ?? 0.0;
    final deviceId = await HiveService.getOrCreateDeviceId();
    final thresholds = await HiveService.getThresholds();

    FlutterBackgroundService().invoke('sync', {
      'routeId': routeId,
      'name': name,
      'latitude': lat,
      'longitude': lng,
      'deviceId': deviceId,
      'thresholdFarM': thresholds.farM,
      'thresholdMidM': thresholds.midM,
      'thresholdNearM': thresholds.nearM,
    });
  }

  Future<void> _loadInitialState() async {
    final dest = await HiveService.getDestName() ?? l10n.commonDefaultDestination;
    final isMuted = await HiveService.getIsMuted();
    final lastDistance = await HiveService.getLastDistance();
    debugPrint('[TrackingPage] Hive lastDistance: $lastDistance');

    setState(() {
      _destinationName = dest;
      _isMuted = isMuted;

      if (lastDistance != null && lastDistance > 0) {
        _distanceMeters = lastDistance;
        _initialDistance ??= lastDistance;
      }
    });
  }

  void _setupBackgroundListener() {
    final service = FlutterBackgroundService();

    service.on('update').listen((event) {
      if (event != null) {
        // Background service'ten gelen gerçek GPS mesafesi (metre).
        final dynamic rawDist = event['distance'];
        if (rawDist == null) return; // Geçersiz event → yoksay

        final double dist = (rawDist as num).toDouble();

        debugPrint(
          '[TrackingPage] BG update: dist=${dist.toStringAsFixed(1)}m',
        );

        // UI'ın kendi isolate'inde güvenle diske kaydet (deadlock'u önler)
        HiveService.setLastDistance(dist);

        _syncRetryCount = 0;
        _syncFailed = false;
        _syncTimer?.cancel();

        if (!mounted) return;
        setState(() {
          if (dist > 0) {
            _distanceMeters = dist;
            // İlk gerçek mesafe geldiğinde _initialDistance'ı kilitle.
            _initialDistance ??= dist;
          }
          // dist == 0: konum alındı ama varış noktasında — 0 göster
          if (dist == 0) _distanceMeters = 0;

          // arrived flag'i arka plan servisinden oku
          final dynamic rawArrived = event['arrived'];
          if (rawArrived == true) {
            if (!_hasArrived) _markHistoryArrived();
            _hasArrived = true;
          }
        });
      }
    });

    service.on('gpsWarning').listen((event) {
      if (!mounted || event == null) return;
      final bool weak = event['weak'] as bool? ?? false;
      setState(() => _gpsSignalWeak = weak);
    });

    service.on('backendMute').listen((event) async {
      debugPrint('[TrackingPage] Servisten backendMute uyarısı alındı.');
      await HiveService.setIsMuted(true);
      await NotificationService.cancelAll();
      await _markHistoryMuted();
      if (mounted) {
        setState(() {
          _isMuted = true;
        });
      }
    });
  }

  /// Varış noktasına ulaşıldığında yerel geçmiş kaydını günceller.
  Future<void> _markHistoryArrived() async {
    final historyId = await HiveService.getActiveHistoryId();
    if (historyId != null) {
      await HiveService.updateHistoryEntryStatus(historyId, status: 'ARRIVED');
    }
  }

  /// Alarm susturulduğunda (kullanıcı ya da backend tarafından) yerel geçmiş
  /// kaydını günceller.
  Future<void> _markHistoryMuted() async {
    final historyId = await HiveService.getActiveHistoryId();
    if (historyId != null) {
      await HiveService.updateHistoryEntryStatus(
        historyId,
        status: 'MUTED',
        isMuted: true,
      );
    }
  }

  /// SORUN 3 DÜZELTMESİ (adım 1/2): Kullanıcı düğmeyi 3 saniye basılı tutup
  /// onayladıktan SONRA çağrılır. Henüz hiçbir kalıcı/geri dönüşü olmayan
  /// eylem (Hive, backend, servis durdurma) yapılmaz — sadece o an çalan
  /// alarm sesi susturulur ve [_kMuteUndoWindow] kadar "Geri Al" penceresi
  /// açılır. Bu sayede yarı uykulu bir kullanıcının erken tetiklenen bir
  /// alarmı yanlışlıkla kalıcı olarak durdurması engellenmiş olur.
  void _confirmMute() {
    if (_mutePending) return;

    NotificationService.cancelAll();
    setState(() => _mutePending = true);

    CenterToast.show(
      context,
      message: l10n.toastMuting,
      type: ToastType.error,
      duration: _kMuteUndoWindow,
      actionLabel: l10n.commonUndo,
      onAction: _cancelPendingMute,
    );

    _muteUndoTimer = Timer(_kMuteUndoWindow, _finalizeMute);
  }

  /// "Geri Al"a basıldığında: henüz hiçbir kalıcı değişiklik yapılmadığı için
  /// bekleyen zamanlayıcıyı iptal etmek tek başına yeterlidir; takip
  /// kesintisiz devam eder.
  void _cancelPendingMute() {
    _muteUndoTimer?.cancel();
    _muteUndoTimer = null;
    if (!mounted) return;
    setState(() => _mutePending = false);
    _showInfoSnackBar(l10n.toastMuteCancelled);
  }

  /// Çalan alarmı hemen susturur ama takibi susturmaz: arka plan servisi,
  /// en son tetiklenen aşamayı 2 dakika sonra tekrar tetiklenebilir hale
  /// getirir (bkz. background_service.dart `snoozeAlarm`).
  void _snoozeAlarm() {
    Alarm.stopAll();
    FlutterBackgroundService().invoke('snoozeAlarm');
    _showInfoSnackBar(l10n.toastSnoozed);
  }

  /// SORUN 3 DÜZELTMESİ (adım 2/2): "Geri Al" penceresi dolunca asıl (kalıcı)
  /// susturma burada uygulanır — eski _muteAlarm ile aynı geri dönüşü olmayan
  /// adımlar (Hive, backend "bir daha tetikleme", servisi durdurma).
  Future<void> _finalizeMute() async {
    _muteUndoTimer = null;

    await HiveService.setIsMuted(true);
    await NotificationService.cancelAll();
    await _markHistoryMuted();

    if (mounted) {
      setState(() {
        _isMuted = true;
        _mutePending = false;
      });
    }

    FlutterBackgroundService().invoke('stopService');

    final routeId = await HiveService.getActiveRouteId();
    if (routeId != null && routeId != kOfflineRouteId) {
      try {
        final deviceId = await HiveService.getOrCreateDeviceId();
        await http
            .post(
              Uri.parse(
                '${MyBackgroundService.serverBaseUrl}/routes/$routeId/mute',
              ),
              headers: MyBackgroundService.apiHeaders(deviceId),
            )
            .timeout(const Duration(seconds: 4));
      } catch (e) {
        // Silent catch for offline capability
      }
    }

    if (mounted) {
      _showInfoSnackBar(l10n.toastMutedAndStopped);
    }
  }

  Future<void> _stopTrackingSession() async {
    _muteUndoTimer?.cancel();
    _muteUndoTimer = null;

    // Yalnızca hâlâ "ACTIVE" durumundaysa (yani ne varışa ulaşılmış ne de
    // susturulmuşsa) geçmişte "İptal Edildi" olarak işaretle — aksi halde
    // zaten kazanılmış olan ARRIVED/MUTED durumunun üzerine yazılmasın.
    final historyId = await HiveService.getActiveHistoryId();
    if (historyId != null) {
      final history = await HiveService.getHistory();
      final current = history.where((e) => e.id == historyId);
      if (current.isNotEmpty && current.first.status == 'ACTIVE') {
        await HiveService.updateHistoryEntryStatus(
          historyId,
          status: 'MUTED',
          isMuted: false,
        );
      }
    }

    await HiveService.stopTracking();
    await NotificationService.cancelAll();
    FlutterBackgroundService().invoke('stopService');

    if (mounted) {
      // popUntil(isFirst) yerine: uygulama bir bildirimden doğrudan bu
      // sayfayla (main.dart'taki startOnTracking) başlamış olabilir — bu
      // durumda TrackingPage zaten "ilk" rotadır ve popUntil hiçbir şey
      // yapmaz. pushAndRemoveUntil her durumda ana sayfaya döner.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
    }
  }

  void _showInfoSnackBar(String message) {
    CenterToast.show(context, message: message, type: ToastType.info);
  }

  /// Mesafeyi kullanıcı dostu formatta döndürür.
  /// null → henüz GPS verisi yok.
  String _formatDistance(double? meters) {
    if (meters == null) return l10n.trackingCalculating;
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    } else {
      return '${meters.toStringAsFixed(0)} m';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // İlerleme oranı: gerçek veri yoksa 0.0 (çubuk boş).
    // _initialDistance ve _distanceMeters null ise animasyon bekler.
    double progress = 0.0;
    if (_initialDistance != null &&
        _initialDistance! > 0 &&
        _distanceMeters != null) {
      progress = (1.0 - (_distanceMeters! / _initialDistance!)).clamp(0.0, 1.0);
    }

    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient blobs
          Positioned(
            top: -50,
            right: -50,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.neonPink.withOpacity(isDark ? 0.12 : 0.06),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -80,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.neonBlue.withOpacity(isDark ? 0.12 : 0.06),
              ),
            ),
          ),

          const GrainOverlay(),

          SafeArea(
            // Ekran, tüm bileşenlerin toplam boyu ekrandan kısa kaldığında bile
            // (ör. alarm çalmadığı için susturma bölümü gizliyken) altta boş
            // siyah alan kalmasın diye LayoutBuilder + Spacer ile dolduruluyor;
            // içerik ekrandan uzun olduğunda ise normal şekilde kaydırılabilir.
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Custom Premium Header
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_back_ios_new),
                                  onPressed: _stopTrackingSession,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _isMuted
                                        ? AppColors.neonPink.withOpacity(0.1)
                                        : AppColors.neonCyan.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: _isMuted
                                          ? AppColors.neonPink
                                          : AppColors.neonCyan,
                                      width: 1,
                                    ),
                                  ),
                                  child: Text(
                                    _isMuted ? l10n.trackingStatusMuted : l10n.trackingStatusActive,
                                    style: TextStyle(
                                      color: _isMuted
                                          ? AppColors.neonPink
                                          : AppColors.neonCyan,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 30),

                            // Alarm o an çalıyorsa: uygulama ön plandaysa bildirimin
                            // kendi "Durdur" düğmesini beklemeden buradan da durdurulabilir.
                            if (_alarmIsRinging)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 24),
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: AppColors.neonPink.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: AppColors.neonPink,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.alarm,
                                            color: AppColors.neonPink,
                                            size: 26,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              l10n.trackingAlarmRinging,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 15,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ),
                                          GestureDetector(
                                            onTap: () => Alarm.stopAll(),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 14,
                                                vertical: 8,
                                              ),
                                              decoration: BoxDecoration(
                                                color: AppColors.neonPink,
                                                borderRadius: BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                l10n.trackingStop,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      GestureDetector(
                                        onTap: _snoozeAlarm,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(vertical: 10),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.08),
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(color: Colors.white24),
                                          ),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              const Icon(Icons.snooze_rounded, color: Colors.white, size: 18),
                                              const SizedBox(width: 8),
                                              Text(
                                                l10n.trackingSnooze,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                            if (_gpsSignalWeak)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 24),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: AppColors.neonOrange.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: AppColors.neonOrange.withOpacity(0.5)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.gps_off_rounded, color: AppColors.neonOrange, size: 20),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          l10n.trackingGpsWeakWarning,
                                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                            // Distance display
                            Center(
                              child: Column(
                                children: [
                                  Text(
                                    l10n.trackingRemainingDistance,
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1.6,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _syncFailed
                                        ? l10n.trackingLocationUnavailable
                                        : _formatDistance(_distanceMeters),
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                          fontSize:
                                              (_distanceMeters == null ||
                                                  _syncFailed)
                                              ? 28
                                              : 56,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -1.0,
                                          color: _syncFailed
                                              ? Colors.redAccent
                                              : null,
                                        ),
                                  ),
                                  if (_syncFailed)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        l10n.trackingCheckConnection,
                                        style: const TextStyle(
                                          color: Colors.redAccent,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  // Varış etiketi — takip devam ederken gösterilir
                                  if (_hasArrived && !_syncFailed)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const Icon(
                                            Icons.location_on,
                                            color: AppColors.neonCyan,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            l10n.trackingArrived,
                                            style: const TextStyle(
                                              color: AppColors.neonCyan,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  // Hız göstergesi kaldırıldı
                                ],
                              ),
                            ),
                            const SizedBox(height: 40),

                            // Glassmorphism Center Panel
                            GlassCard(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.location_on,
                                        color: AppColors.neonBlue,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _destinationName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 18,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 30),

                                  // Custom approach progress indicator
                                  Stack(
                                    children: [
                                      Container(
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                      AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 500,
                                        ),
                                        height: 8,
                                        width:
                                            MediaQuery.of(context).size.width *
                                            0.75 *
                                            progress,
                                        decoration: BoxDecoration(
                                          gradient: AppColors.neonBlueCyan,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: AppColors.neonCyan
                                                  .withOpacity(0.4),
                                              blurRadius: 8,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        l10n.trackingStartLabel,
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        l10n.trackingDestinationLabel,
                                        style: TextStyle(
                                          color: theme.colorScheme.secondary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  // Bu uyarı yalnızca "Alarmı Sustur" düğmesi
                                  // görünürken (alarm çalarken ya da susturma
                                  // beklemedeyken) bir anlam ifade eder.
                                  if (!_isMuted &&
                                      (_mutePending || _alarmIsRinging)) ...[
                                    const SizedBox(height: 40),
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: AppColors.neonOrange.withOpacity(
                                          0.06,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: AppColors.neonOrange
                                              .withOpacity(0.25),
                                          width: 1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.warning_amber_rounded,
                                            color: AppColors.neonOrange,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              l10n.trackingMuteInstructions(
                                                _kMuteUndoWindow.inSeconds,
                                                l10n.commonUndo,
                                              ),
                                              style: const TextStyle(
                                                color: AppColors.textSecondary,
                                                fontSize: 12,
                                                height: 1.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 40),
                            const Spacer(),

                            // Mute / Stop Action Buttons — alarm çalmıyorken (ve
                            // susturma zaten beklemedeyken değilse) bu düğmenin
                            // gösterilmesine gerek yok.
                            if (!_isMuted &&
                                (_mutePending || _alarmIsRinging)) ...[
                              if (_mutePending)
                                Container(
                                  height: 60,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppColors.neonPink.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(30),
                                    border: Border.all(
                                      color: AppColors.neonPink,
                                      width: 1,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Text(
                                      l10n.trackingMutePendingBanner(l10n.commonUndo),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                )
                              else
                                HoldToConfirmButton(
                                  text: l10n.trackingHoldToMute,
                                  holdingText: l10n.trackingHolding,
                                  gradient: AppColors.neonPinkOrange,
                                  holdDuration: const Duration(seconds: 3),
                                  onConfirmed: _confirmMute,
                                ),
                              const SizedBox(height: 16),
                            ],

                            TextButton(
                              onPressed: _stopTrackingSession,
                              child: Text(
                                l10n.trackingEndTracking,
                                style: TextStyle(
                                  color: _isMuted
                                      ? theme.colorScheme.primary
                                      : AppColors.textGrey,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

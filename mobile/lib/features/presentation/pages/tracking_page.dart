import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/hive_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/services/background_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';

class TrackingPage extends StatefulWidget {
  const TrackingPage({Key? key}) : super(key: key);

  @override
  State<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends State<TrackingPage> {
  String _destinationName = "Hedef";

  /// null: GPS'ten henüz gerçek mesafe gelmedi → UI'da "Hesaplanıyor..." gösterilir.
  /// Sıfır olmayan ilk gerçek değer geldiğinde null olmaktan çıkar.
  double? _distanceMeters;

  bool _isMuted = false;

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
    
    // Arka plan servisinden taze veri iste (eğer zaten çalışıyorsa)
    _triggerSync();

    // Dayanıklı tasarım: Mesafe hesaplanana kadar exponential backoff ile 'sync' isteğini tekrarla.
    _startSyncTimer();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    if (_distanceMeters != null) return;

    if (_syncRetryCount >= 10) {
      debugPrint('[TrackingPage] Konum verisi alınamadı (Maksimum deneme sınırına ulaşıldı).');
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
        debugPrint('[TrackingPage] Mesafe henüz gelmedi, sync tetikleniyor... (Deneme: $_syncRetryCount, Sonraki gecikme: ${delaySeconds}s)');
        _triggerSync();
        _startSyncTimer();
      }
    });
  }

  Future<void> _triggerSync() async {
    final routeId = await HiveService.getActiveRouteId() ?? 9999;
    final name = await HiveService.getDestName() ?? "Hedef";
    final lat = await HiveService.getDestLatitude() ?? 0.0;
    final lng = await HiveService.getDestLongitude() ?? 0.0;

    FlutterBackgroundService().invoke('sync', {
      'routeId': routeId,
      'name': name,
      'latitude': lat,
      'longitude': lng,
    });
  }

  Future<void> _loadInitialState() async {
    final dest = await HiveService.getDestName() ?? "Hedef";
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

        debugPrint('[TrackingPage] BG update: dist=${dist.toStringAsFixed(1)}m');

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
          if (rawArrived == true) _hasArrived = true;
        });
      }
    });

    service.on('backendMute').listen((event) async {
      debugPrint('[TrackingPage] Servisten backendMute uyarısı alındı.');
      await HiveService.setIsMuted(true);
      await NotificationService.cancelAll();
      if (mounted) {
        setState(() {
          _isMuted = true;
        });
      }
    });
  }

  Future<void> _muteAlarm() async {
    // 1. Set local database state
    await HiveService.setIsMuted(true);
    await NotificationService.cancelAll();
    
    setState(() {
      _isMuted = true;
    });

    // 2. Stop Background Service
    FlutterBackgroundService().invoke('stopService');

    // 3. Notify Backend
    final routeId = await HiveService.getActiveRouteId();
    if (routeId != null && routeId != 9999) {
      try {
        await http.post(
          Uri.parse('${MyBackgroundService.serverBaseUrl}/api/routes/$routeId/mute/'),
          headers: {
            "Content-Type": "application/json",
            "ngrok-skip-browser-warning": "true",
          },
        ).timeout(const Duration(seconds: 4));
      } catch (e) {
        // Silent catch for offline capability
      }
    }

    _showInfoSnackBar("Alarm susturuldu ve geofence takibi sonlandırıldı.");
  }

  Future<void> _stopTrackingSession() async {
    await HiveService.stopTracking();
    await NotificationService.cancelAll();
    FlutterBackgroundService().invoke('stopService');

    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _showInfoSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.neonBlue,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Mesafeyi kullanıcı dostu formatta döndürür.
  /// null → henüz GPS verisi yok.
  String _formatDistance(double? meters) {
    if (meters == null) return 'Hesaplanıyor...';
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
    if (_initialDistance != null && _initialDistance! > 0 && _distanceMeters != null) {
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

          SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
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
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: _isMuted 
                                ? AppColors.neonPink.withOpacity(0.1) 
                                : AppColors.neonCyan.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _isMuted ? AppColors.neonPink : AppColors.neonCyan,
                              width: 1,
                            ),
                          ),
                          child: Text(
                            _isMuted ? 'SUSTURULDU' : 'TAKİP EDİLİYOR',
                            style: TextStyle(
                              color: _isMuted ? AppColors.neonPink : AppColors.neonCyan,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),

                    // Distance display
                    Center(
                      child: Column(
                        children: [
                          const Text(
                            'Kalan Mesafe',
                            style: TextStyle(
                              color: AppColors.textGrey,
                              fontSize: 16,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _syncFailed ? 'Konum Alınamadı' : _formatDistance(_distanceMeters),
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontSize: (_distanceMeters == null || _syncFailed) ? 28 : 56,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -1.0,
                              color: _syncFailed ? Colors.redAccent : null,
                            ),
                          ),
                          if (_syncFailed)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'Lütfen GPS veya internet bağlantınızı kontrol edin.',
                                style: TextStyle(color: Colors.redAccent, fontSize: 13),
                              ),
                            ),
                          // Varış etiketi — takip devam ederken gösterilir
                          if (_hasArrived && !_syncFailed)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.location_on,
                                    color: AppColors.neonCyan,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Varış Noktasına Ulaşıldı',
                                    style: TextStyle(
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
                              const Icon(Icons.location_on, color: AppColors.neonBlue),
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
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 500),
                                height: 8,
                                width: MediaQuery.of(context).size.width * 0.75 * progress,
                                decoration: BoxDecoration(
                                  gradient: AppColors.neonBlueCyan,
                                  borderRadius: BorderRadius.circular(4),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.neonCyan.withOpacity(0.4),
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
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Başlangıç', style: TextStyle(color: AppColors.textGrey, fontSize: 12)),
                              Text('Hedef', style: TextStyle(color: theme.colorScheme.secondary, fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 40),

                          // Kullanıcı dostu uyarı kutusu
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.neonOrange.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppColors.neonOrange.withOpacity(0.25),
                                width: 1,
                              ),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.warning_amber_rounded,
                                    color: AppColors.neonOrange, size: 20),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Alarmı susturursan takip tamamen durur ve tekrar otomatik başlamaz.',
                                    style: TextStyle(
                                      color: AppColors.textGrey,
                                      fontSize: 12,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),

                    // Mute / Stop Action Buttons
                    if (!_isMuted) ...[
                      NeonButton(
                        text: 'Alarmı Sustur (Manuel)',
                        gradient: AppColors.neonPinkOrange,
                        onTap: _muteAlarm,
                      ),
                      const SizedBox(height: 16),
                    ],

                    TextButton(
                      onPressed: _stopTrackingSession,
                      child: Text(
                        'Takibi Tamamen Sonlandır',
                        style: TextStyle(
                          color: _isMuted ? theme.colorScheme.primary : AppColors.textGrey,
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
        ],
      ),
    );
  }
}


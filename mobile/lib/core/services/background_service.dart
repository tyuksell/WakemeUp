import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'hive_service.dart';
import 'notification_service.dart';
import 'crash_reporter.dart';
import '../utils/distance_calculator.dart';
import '../utils/constants.dart';
import '../../l10n/app_localizations.dart';

@pragma('vm:entry-point')
class MyBackgroundService {
  // Production URL — Supabase Edge Functions
  static const String serverBaseUrl = 'https://livhwiwziyzzlpsnzqsr.supabase.co/functions/v1';
  static const String supabaseApiKey = 'sb_publishable_pa0-uZqAaaRUPtILAZHvYQ_85brCyux';

  static Map<String, String> apiHeaders(String deviceId) => {
        'Content-Type': 'application/json',
        'apikey': supabaseApiKey,
        'Authorization': 'Bearer $supabaseApiKey',
        'X-Device-Id': deviceId,
      };

  // In-memory state for the background isolate to bypass cross-isolate Hive deadlock issues
  static double? _destLat;
  static double? _destLng;
  static String? _destName;
  static int? _routeId;
  static String? _deviceId;
  static bool _isTracking = false;
  static bool _isMuted = false;
  static AlarmThresholds _thresholds = AlarmThresholds.defaults;

  // Local notification triggers in-memory
  static bool _notified1km = false;
  static bool _notified500m = false;
  static bool _notified250m = false;
  static bool _notifiedArrival = false; // Varış noktasına ulaşıldığında tetiklenir

  // ── SORUN 4 DÜZELTMESİ: ETA (tahmini varış süresi) güvenlik ağı ──────────
  // Sabit metre eşikleri taşıma aracından bağımsız değildir: 1000m eşiği bir
  // yürüyüşte ~12 dakika önceden uyarırken, saatte 120km giden bir trende
  // sadece ~30 saniye önceden uyarır — tam da uyuyakalma riskinin en yüksek
  // olduğu durumda en az reaksiyon süresini bırakır. Aşağıdaki ETA eşikleri
  // mesafe eşiklerinin YERİNE değil, ONLARA EK bir güvenlik ağı olarak
  // çalışır (bkz. _maybeEscalateByEta): hız yüksekse ilgili aşama, mesafe
  // eşiği henüz aşılmamış olsa bile erken tetiklenir.
  static double? _smoothedSpeedMps;

  /// Kalıcı bildirimdeki ilerleme çubuğu için: oturumun ilk gerçek mesafesi.
  static double? _initialDistanceForProgress;
  static const Duration _etaFar = Duration(minutes: 5);
  static const Duration _etaMid = Duration(minutes: 2);
  static const Duration _etaNear = Duration(seconds: 45);

  /// GPS "speed" bu değerin altındayken (dururken/çok yavaşken) ETA
  /// hesaplanmaz — mesafe/hız bölmesi anlamsız derecede büyük/gürültülü
  /// sürelere yol açar.
  static const double _minSpeedForEtaMps = 1.0; // ~3.6 km/h

  // ── GPS Sinyal Kalitesi Takibi ─────────────────────────────────────────
  // Zayıf/kaybolmuş GPS sinyalini (ör. tünel/metro) kullanıcıya bildirmek için:
  // konum doğruluğu bu değerden kötüyse VEYA bu süre boyunca hiç konum
  // gelmediyse UI'a bir uyarı gönderilir.
  static const double _poorAccuracyThresholdM = 100.0;
  static const Duration _staleLocationThreshold = Duration(seconds: 25);
  static DateTime? _lastPositionAt;
  static bool _gpsWarningActive = false;
  static Timer? _gpsWatchdogTimer;

  // ── Alarm Erteleme (Snooze) ────────────────────────────────────────────
  // En son hangi aşamanın tetiklendiğini tutar; "Ertele" ile bu aşamanın
  // bildirim bayrağı [_snoozeDuration] sonra sıfırlanıp tekrar tetiklenebilir
  // hale getirilir (bkz. onSnoozeAlarm).
  static String? _lastFiredStage; // STAGE_FAR | STAGE_MID | STAGE_NEAR | ARRIVED
  static const Duration _snoozeDuration = Duration(minutes: 2);

  /// O an hangi dil seçiliyse (Hive'daki tercih) buna göre bir
  /// [AppLocalizations] örneği döndürür. Bu, ana UI'dan ayrı bir Dart izolatı
  /// olduğu için `BuildContext`/`Localizations.of` kullanılamaz — bunun
  /// yerine üretilen `lookupAppLocalizations` doğrudan çağrılır.
  static Future<AppLocalizations> _loadL10n() async {
    final code = await HiveService.getLanguageCode();
    return lookupAppLocalizations(Locale(code));
  }

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();
    final l10n = await _loadL10n();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: NotificationService.serviceChannelId,
        initialNotificationTitle: l10n.notifServiceInitialTitle,
        initialNotificationContent: l10n.notifServiceInitialContent,
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    debugPrint('[BgService] onStart entry point.');

    // Bu, ana UI'dan ayrı bir Dart izolatı olduğundan .env ve Sentry'nin
    // burada da ayrıca başlatılması gerekir (statik durum izolatlar arasında
    // paylaşılmaz — bkz. crash_reporter.dart).
    try {
      await dotenv.load(fileName: '.env');
      await CrashReporter.initBackgroundIsolate();
    } catch (e) {
      debugPrint('[BgService] .env/CrashReporter başlatılamadı: $e');
    }

    // Initialize notifications only since it's stateless and doesn't hit database locks
    try {
      await NotificationService.init();
      debugPrint('[BgService] NotificationService initialized successfully.');
    } catch (e, st) {
      debugPrint('[BgService] NotificationService init failed: $e');
      CrashReporter.capture(e, st, hint: 'NotificationService.init failed in background isolate');
    }

    // GPS sinyali belirli bir süre hiç gelmezse (ör. tünel/metroda) UI'a
    // uyarı gönderen bekçi zamanlayıcı. Konum doğruluğu kötüyse bunu ayrıca
    // _processPosition içinde anında bildiriyoruz.
    _gpsWatchdogTimer?.cancel();
    _gpsWatchdogTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isTracking || _isMuted) return;
      final lastAt = _lastPositionAt;
      final bool stale = lastAt == null || DateTime.now().difference(lastAt) > _staleLocationThreshold;
      if (stale && !_gpsWarningActive) {
        _gpsWarningActive = true;
        service.invoke('gpsWarning', {'weak': true, 'reason': 'stale'});
      }
    });

    // Register all listeners synchronously so they receive events immediately
    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });
      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    service.on('stopService').listen((event) async {
      debugPrint('[BgService] stopService tetiklendi.');
      _isTracking = false;
      _gpsWatchdogTimer?.cancel();
      service.stopSelf();
    });

    // Kullanıcı "Ertele"ye bastığında: en son tetiklenen aşamanın bildirim
    // bayrağı [_snoozeDuration] sonra sıfırlanır, böylece hâlâ o mesafe
    // aralığındaysa (ve susturulmadıysa/varılmadıysa) alarm tekrar çalar.
    // Sesin kendisi zaten UI tarafından (Alarm.stopAll()) anında durdurulur.
    service.on('snoozeAlarm').listen((event) async {
      final stage = _lastFiredStage;
      debugPrint('[BgService] snoozeAlarm tetiklendi. stage=$stage, ${_snoozeDuration.inMinutes}dk sonra tekrar tetiklenebilir.');
      if (stage == null) return;
      Timer(_snoozeDuration, () async {
        debugPrint('[BgService] Snooze süresi doldu, aşama tekrar tetiklenebilir hale getiriliyor: $stage');
        switch (stage) {
          case 'STAGE_FAR':
            _notified1km = false;
            break;
          case 'STAGE_MID':
            _notified500m = false;
            break;
          case 'STAGE_NEAR':
            _notified250m = false;
            break;
          case 'ARRIVED':
            _notifiedArrival = false;
            break;
        }
        // Online modda gerçek tetikleme kararı backend'deki notified_* bayrağına
        // göre verildiğinden, o kaydı da aynı şekilde sıfırlamamız gerekir.
        if (_routeId != null && _routeId != kOfflineRouteId && _deviceId != null) {
          try {
            await http
                .post(
                  Uri.parse('$serverBaseUrl/routes/$_routeId/snooze'),
                  headers: apiHeaders(_deviceId!),
                  body: jsonEncode({'stage': stage}),
                )
                .timeout(const Duration(seconds: 8));
          } catch (e, st) {
            debugPrint('[BgService] Snooze backend isteği başarısız: $e');
            CrashReporter.capture(e, st, hint: 'snooze backend request failed');
          }
        }
      });
    });

    service.on('sync').listen((event) async {
      debugPrint('[BgService] sync tetiklendi.');
      if (event != null) {
        _routeId = event['routeId'] as int? ?? _routeId;
        _destName = event['name'] as String? ?? _destName;
        _destLat = (event['latitude'] as num?)?.toDouble() ?? _destLat;
        _destLng = (event['longitude'] as num?)?.toDouble() ?? _destLng;
        _deviceId = event['deviceId'] as String? ?? _deviceId;
        _thresholds = _thresholdsFromEvent(event) ?? _thresholds;
        _isTracking = true;
        debugPrint('[BgService] sync update: Hedef=$_destName, Lat=$_destLat, Lng=$_destLng');
      }
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        await _processPosition(service, position);
      } catch (e) {
        debugPrint('[BgService] sync konum alınamadı: $e');
        try {
          final lastPosition = await Geolocator.getLastKnownPosition();
          if (lastPosition != null) {
            debugPrint('[BgService] sync fallback olarak son bilinen konum kullanılıyor.');
            await _processPosition(service, lastPosition);
          }
        } catch (err) {
          debugPrint('[BgService] sync fallback de başarısız: $err');
        }
      }
    });

    service.on('startTracking').listen((event) async {
      debugPrint('[BgService] startTracking tetiklendi.');
      if (event != null) {
        _routeId = event['routeId'] as int?;
        _destName = event['name'] as String?;
        _destLat = (event['latitude'] as num?)?.toDouble();
        _destLng = (event['longitude'] as num?)?.toDouble();
        _deviceId = event['deviceId'] as String? ?? _deviceId;
        _thresholds = _thresholdsFromEvent(event) ?? AlarmThresholds.defaults;
        _isTracking = true;
        _isMuted = false;
        _notified1km = false;
        _notified500m = false;
        _notified250m = false;
        _notifiedArrival = false; // Yeni oturumda varış bildirimi sıfırla
        _smoothedSpeedMps = null; // Yeni oturumda ETA hız ortalaması sıfırla
        _lastFiredStage = null;
        _initialDistanceForProgress = null; // Bildirimdeki ilerleme çubuğu için sıfırla
        _gpsWarningActive = false;
        debugPrint('[BgService] startTracking: Hedef=$_destName, Lat=$_destLat, Lng=$_destLng');
        await _acquireAndProcess(service);
      }
    });

    // ── Sürekli konum akışı (her 15 metrede bir) ───────────────────────────
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((Position position) async {
      debugPrint('[BgService] Stream üzerinden yeni konum geldi.');

      // İzolat yeniden başlatılmışsa (_isTracking false iken stream gelirse)
      // Hive'dan tracking durumunu ve koordinatları yükle.
      if (!_isTracking) {
        try {
          final bool isTracking = await HiveService.getIsTracking();
          if (isTracking) {
            _routeId ??= await HiveService.getActiveRouteId();
            _destName ??= await HiveService.getDestName();
            _destLat ??= await HiveService.getDestLatitude();
            _destLng ??= await HiveService.getDestLongitude();
            _deviceId ??= await HiveService.getDeviceId();
            _thresholds = await HiveService.getThresholds();
            final bool isMuted = await HiveService.getIsMuted();
            _isTracking = true;
            _isMuted = isMuted;
            debugPrint('[BgService] Stream: Hive\'dan takip durumu geri yüklendi — '
                'Hedef=$_destName Lat=$_destLat Lng=$_destLng');
          }
        } catch (e) {
          debugPrint('[BgService] Stream: Hive okuma hatası: $e');
        }
      }

      await _processPosition(service, position);
    });
  }

  /// Taze konum alır ve işler.
  static Future<void> _acquireAndProcess(ServiceInstance service) async {
    try {
      debugPrint('[BgService] Mevcut konum alınıyor...');
      final Position initialPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      debugPrint('[BgService] Mevcut konum alındı, işleniyor.');
      await _processPosition(service, initialPosition);
    } catch (e) {
      debugPrint('[BgService] Konum alınamadı (Initial): $e');
      try {
        final lastPosition = await Geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          debugPrint('[BgService] Initial fallback olarak son bilinen konum kullanılıyor.');
          await _processPosition(service, lastPosition);
        }
      } catch (err) {
        debugPrint('[BgService] Initial fallback de başarısız: $err');
      }
    }
  }

  /// Tek bir konum güncellemesini işler:
  /// mesafe hesaplar, UI'ı günceller, API'ye bildirir.
  static Future<void> _processPosition(
    ServiceInstance service,
    Position position,
  ) async {
    if (!_isTracking || _isMuted) {
      debugPrint('[BgService] Konum işleme pas geçildi: _isTracking=$_isTracking, _isMuted=$_isMuted');
      return;
    }

    // SORUN 4 DÜZELTMESİ: Koordinatlar null ise Hive'dan fallback olarak yükle.
    // Bu durum; servis event kaybından (race condition), izolat yeniden başlatılmasından
    // veya cihaz uyanmasından kaynaklanabilir.
    if (_destLat == null || _destLng == null || _routeId == null) {
      debugPrint('[BgService] Koordinatlar null — Hive\'dan yüklemeye çalışılıyor...');
      try {
        _routeId ??= await HiveService.getActiveRouteId();
        _destName ??= await HiveService.getDestName();
        _deviceId ??= await HiveService.getDeviceId();
        _thresholds = await HiveService.getThresholds();
        final double? hiveLat = await HiveService.getDestLatitude();
        final double? hiveLng = await HiveService.getDestLongitude();
        if (hiveLat != null && hiveLat != 0.0) _destLat = hiveLat;
        if (hiveLng != null && hiveLng != 0.0) _destLng = hiveLng;
        debugPrint('[BgService] Hive fallback: Hedef=$_destName, '
            'Lat=$_destLat, Lng=$_destLng, RouteId=$_routeId');
      } catch (e) {
        debugPrint('[BgService] Hive fallback okuma hatası: $e');
      }
    }

    if (_destLat == null || _destLng == null || _routeId == null) {
      debugPrint('[BgService] UYARI: destLat/destLng/routeId Hive\'dan da alınamadı — mesafe hesaplanamıyor.');
      return;
    }

    // LOGLAMA: Koordinatların doğru geçtiğini doğrula
    debugPrint('[BgService] Mevcut: lat=${position.latitude.toStringAsFixed(6)}, '
        'lng=${position.longitude.toStringAsFixed(6)}, '
        'accuracy=${position.accuracy.toStringAsFixed(1)}m');
    debugPrint('[BgService] Hedef : lat=${_destLat!.toStringAsFixed(6)}, '
        'lng=${_destLng!.toStringAsFixed(6)}');

    // Güvenlik: Null Island (0,0) kontrolü
    if (position.latitude == 0.0 && position.longitude == 0.0) {
      debugPrint('[BgService] UYARI: Mevcut konum (0,0) — GPS sinyali yok!');
    }

    // Bildirim metinleri için o an seçili dil (bkz. _loadL10n).
    final l10n = await _loadL10n();
    final String destinationName = _destName ?? l10n.commonDefaultDestination;

    // GPS sinyal kalitesi: hem doğruluk (accuracy) kötüyse hem de bekçi
    // zamanlayıcısının tetiklediği "uzun süredir konum yok" durumunu bu konum
    // gelince temizlemek için kullanılır.
    _lastPositionAt = DateTime.now();
    final bool poorAccuracy = position.accuracy > _poorAccuracyThresholdM;
    if (poorAccuracy && !_gpsWarningActive) {
      _gpsWarningActive = true;
      service.invoke('gpsWarning', {'weak': true, 'reason': 'accuracy', 'accuracy': position.accuracy});
    } else if (!poorAccuracy && _gpsWarningActive) {
      _gpsWarningActive = false;
      service.invoke('gpsWarning', {'weak': false});
    }

    // 1. Haversine ile kuş uçuşu mesafeyi hesapla
    final double distance = DistanceCalculator.calculateDistance(
      position.latitude,
      position.longitude,
      _destLat!,
      _destLng!,
    );

    debugPrint('[BgService] Hesaplanan mesafe: ${distance.toStringAsFixed(1)} m');

    // ETA güvenlik ağı: online/offline modundan bağımsız olarak her konum
    // güncellemesinde çalışır; mesafe bazlı tetikleme (backend ya da yerel
    // fallback) ile aynı _notifiedXXX bayraklarını paylaştığı için aynı
    // aşamanın iki kez tetiklenmesi mümkün değildir.
    _maybeEscalateByEta(distance, position.speed, destinationName, l10n);

    // Invoke UI update — 5m veya daha az kaldıysa arrived:true ilet
    debugPrint('[BgService] UI güncelleniyor: distance=$distance');
    service.invoke('update', {
      "latitude": position.latitude,
      "longitude": position.longitude,
      "distance": distance,
      "arrived": distance <= 5,
    });

    // Kalıcı bildirimde canlı mesafeyi ve ilerleme çubuğunu göster (yalnızca
    // Android foreground service). İlerleme, oturumun ilk gerçek mesafesine
    // göre hesaplanır — tracking_page.dart'taki ilerleme çubuğuyla aynı mantık.
    if (distance > 0) {
      _initialDistanceForProgress ??= distance;
    }
    int progressPercent = 0;
    final initial = _initialDistanceForProgress;
    if (initial != null && initial > 0) {
      progressPercent = (100 * (1.0 - (distance / initial))).clamp(0, 100).round();
    }
    if (service is AndroidServiceInstance) {
      await NotificationService.updateTrackingProgress(
        title: l10n.notifPersistentTitle(destinationName),
        content: l10n.notifPersistentContent(_formatDistanceForNotification(distance)),
        progressPercent: progressPercent,
      );
    }

    // 2. Synchronize with django server API
    if (_routeId != kOfflineRouteId) {
      try {
        final response = await http.post(
          Uri.parse('$serverBaseUrl/routes/$_routeId/update-location'),
          headers: apiHeaders(_deviceId ?? ''),
          body: jsonEncode({
            "current_latitude": position.latitude,
            "current_longitude": position.longitude,
          }),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final bool backendMuted = data['is_muted'] ?? false;
          final bool triggerAlarm = data['trigger_alarm'] ?? false;
          final String targetStage = data['target_stage'] ?? 'OUT_OF_RANGE';

          if (backendMuted) {
            _isMuted = true;
            service.invoke('backendMute');
            service.stopSelf();
            return;
          }

          if (triggerAlarm) {
            _triggerIsolateNotification(targetStage, destinationName, l10n);
          }
        } else {
          _handleLocalGeofence(distance, destinationName, l10n);
        }
      } catch (e) {
        _handleLocalGeofence(distance, destinationName, l10n);
      }
    } else {
      _handleLocalGeofence(distance, destinationName, l10n);
    }
  }

  /// 'sync'/'startTracking' olayıyla gelen eşik verisini [AlarmThresholds]'e çevirir.
  /// Üçü de eksiksiz gelmediyse null döner (çağıran taraf mevcut/varsayılan değeri korur).
  static AlarmThresholds? _thresholdsFromEvent(Map? event) {
    if (event == null) return null;
    final far = (event['thresholdFarM'] as num?)?.toInt();
    final mid = (event['thresholdMidM'] as num?)?.toInt();
    final near = (event['thresholdNearM'] as num?)?.toInt();
    if (far == null || mid == null || near == null) return null;
    return AlarmThresholds(farM: far, midM: mid, nearM: near);
  }

  static String _formatDistanceForNotification(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  /// SORUN 4 DÜZELTMESİ: Mesafe eşiklerine ek bir güvenlik ağı. GPS
  /// "speed" alanından (Doppler tabanlı, cihaz tarafından hesaplanır) EMA ile
  /// yumuşatılmış bir hız çıkarır ve tahmini varış süresi (ETA = mesafe/hız)
  /// [_etaFar]/[_etaMid]/[_etaNear] eşiklerinin altına düşerse ilgili aşamayı,
  /// mesafe eşiği henüz aşılmamış olsa bile erken tetikler. Böylece hızlı bir
  /// taşıma aracında (tren/otobüs) sabit metre eşiğinin bırakacağı reaksiyon
  /// süresi, yürüyüşe kıyasla orantısız şekilde kısalmaz.
  static void _maybeEscalateByEta(
    double distanceMeters,
    double? rawSpeedMps,
    String destination,
    AppLocalizations l10n,
  ) {
    if (rawSpeedMps == null || rawSpeedMps < 0) return;

    _smoothedSpeedMps = _smoothedSpeedMps == null
        ? rawSpeedMps
        : (_smoothedSpeedMps! * 0.7 + rawSpeedMps * 0.3);

    final double speed = _smoothedSpeedMps!;
    // Dururken/çok yavaşken (ör. yürüyüş molası) ETA anlamsız derecede büyük
    // veya gürültülü olur; bu aşamada yalnızca mesafe eşiklerine güvenilir.
    if (speed < _minSpeedForEtaMps) return;

    final Duration eta = Duration(seconds: (distanceMeters / speed).round());

    if (eta <= _etaNear && !_notified250m) {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'STAGE_NEAR';
      debugPrint('[BgService] ETA güvenlik ağı: ~${eta.inSeconds}sn kaldı (hız=${speed.toStringAsFixed(1)}m/s) — NEAR erken tetiklendi.');
      NotificationService.ringAlarm(
        id: 3,
        title: l10n.notifNearTitleEtaSeconds(eta.inSeconds),
        body: l10n.notifNearBodyEtaSeconds(destination, eta.inSeconds),
      );
    } else if (eta <= _etaMid && !_notified500m) {
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'STAGE_MID';
      debugPrint('[BgService] ETA güvenlik ağı: ~${eta.inMinutes}dk kaldı (hız=${speed.toStringAsFixed(1)}m/s) — MID erken tetiklendi.');
      NotificationService.showAlert(
        id: 2,
        title: l10n.notifMidTitleEtaMinutes(eta.inMinutes),
        body: l10n.notifMidBodyEtaMinutes(destination, eta.inMinutes),
      );
    } else if (eta <= _etaFar && !_notified1km) {
      _notified1km = true;
      _lastFiredStage = 'STAGE_FAR';
      debugPrint('[BgService] ETA güvenlik ağı: ~${eta.inMinutes}dk kaldı (hız=${speed.toStringAsFixed(1)}m/s) — FAR erken tetiklendi.');
      NotificationService.showAlert(
        id: 1,
        title: l10n.notifFarTitleEtaMinutes(eta.inMinutes),
        body: l10n.notifFarBodyEtaMinutes(destination, eta.inMinutes),
      );
    }
  }

  static void _handleLocalGeofence(double distance, String destination, AppLocalizations l10n) {
    // Varış noktası: 5 metre veya daha az kaldığında bir kez bildir
    if (distance <= 5 && !_notifiedArrival) {
      _notifiedArrival = true;
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'ARRIVED';
      // SORUN 1/2 DÜZELTMESİ: Tek seferlik bildirim yerine, kullanıcı
      // durdurana kadar döngüyle çalan gerçek alarm (bkz. NotificationService.ringAlarm).
      NotificationService.ringAlarm(
        id: 4,
        title: l10n.notifArrivedTitle,
        body: l10n.notifArrivedBody(destination),
      );
    } else if (distance <= _thresholds.nearM && !_notified250m) {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'STAGE_NEAR';
      NotificationService.ringAlarm(
        id: 3,
        title: l10n.notifNearTitleMeters(_thresholds.nearM),
        body: l10n.notifNearBodyMeters(destination, _thresholds.nearM),
      );
    } else if (distance <= _thresholds.midM && !_notified500m) {
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'STAGE_MID';
      NotificationService.showAlert(
        id: 2,
        title: l10n.notifMidTitleMeters(_thresholds.midM),
        body: l10n.notifMidBodyMeters(destination, _thresholds.midM),
      );
    } else if (distance <= _thresholds.farM && !_notified1km) {
      _notified1km = true;
      _lastFiredStage = 'STAGE_FAR';
      NotificationService.showAlert(
        id: 1,
        title: l10n.notifFarTitleMeters(_thresholds.farM),
        body: l10n.notifFarBodyMeters(destination, _thresholds.farM),
      );
    }
  }

  static void _triggerIsolateNotification(String stage, String destination, AppLocalizations l10n) {
    if (stage == 'STAGE_NEAR') {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'STAGE_NEAR';
      NotificationService.ringAlarm(
        id: 3,
        title: l10n.notifNearTitleMeters(_thresholds.nearM),
        body: l10n.notifNearBodyMeters(destination, _thresholds.nearM),
      );
    } else if (stage == 'STAGE_MID') {
      _notified500m = true;
      _notified1km = true;
      _lastFiredStage = 'STAGE_MID';
      NotificationService.showAlert(
        id: 2,
        title: l10n.notifMidTitleMeters(_thresholds.midM),
        body: l10n.notifMidBodyMeters(destination, _thresholds.midM),
      );
    } else if (stage == 'STAGE_FAR') {
      _notified1km = true;
      _lastFiredStage = 'STAGE_FAR';
      NotificationService.showAlert(
        id: 1,
        title: l10n.notifFarTitleMeters(_thresholds.farM),
        body: l10n.notifFarBodyMeters(destination, _thresholds.farM),
      );
    }
  }
}

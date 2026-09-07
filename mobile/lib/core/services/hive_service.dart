import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

/// Kademeli alarmın üç mesafe eşiği (metre). Ayarlar ekranından değiştirilebilir;
/// backend'e rota oluşturulurken gönderilir ve offline modda yerel geofence
/// hesabında da aynı değerler kullanılır.
class AlarmThresholds {
  final int farM;
  final int midM;
  final int nearM;

  const AlarmThresholds({required this.farM, required this.midM, required this.nearM});

  static const AlarmThresholds defaults = AlarmThresholds(farM: 1000, midM: 500, nearM: 250);
}

/// Kullanıcının sık kullandığı bir hedefi (ör. ev, iş) temsil eder.
class FavoriteDestination {
  final String name;
  final double lat;
  final double lng;

  const FavoriteDestination({required this.name, required this.lat, required this.lng});

  Map<String, dynamic> toMap() => {'name': name, 'lat': lat, 'lng': lng};

  factory FavoriteDestination.fromMap(Map map) => FavoriteDestination(
        name: map['name'] as String,
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
      );
}

/// Bir takip oturumunun geçmiş kaydı. Sunucudan bağımsız olarak, tamamen
/// cihazın kendi hafızasında (Hive) tutulur; böylece backend'in ücretsiz
/// katmanı (Render) yeniden başladığında ya da internet olmadığında geçmiş
/// kaybolmaz. [id], oturum başlatılırken üretilen bir UUID'dir — backend
/// route id'siyle karışmaması için ayrıdır (offline rotalar sabit bir
/// route id paylaşır).
class RouteHistoryEntry {
  final String id;
  final String destinationName;
  final double lat;
  final double lng;
  final String status;
  final bool isMuted;
  final DateTime createdAt;

  const RouteHistoryEntry({
    required this.id,
    required this.destinationName,
    required this.lat,
    required this.lng,
    required this.status,
    required this.isMuted,
    required this.createdAt,
  });

  RouteHistoryEntry copyWith({String? status, bool? isMuted}) => RouteHistoryEntry(
        id: id,
        destinationName: destinationName,
        lat: lat,
        lng: lng,
        status: status ?? this.status,
        isMuted: isMuted ?? this.isMuted,
        createdAt: createdAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'destinationName': destinationName,
        'lat': lat,
        'lng': lng,
        'status': status,
        'isMuted': isMuted,
        'createdAt': createdAt.toIso8601String(),
      };

  factory RouteHistoryEntry.fromMap(Map map) => RouteHistoryEntry(
        id: map['id'] as String,
        destinationName: map['destinationName'] as String? ?? 'Hedef',
        lat: (map['lat'] as num?)?.toDouble() ?? 0.0,
        lng: (map['lng'] as num?)?.toDouble() ?? 0.0,
        status: map['status'] as String? ?? 'PENDING',
        isMuted: map['isMuted'] as bool? ?? false,
        createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
}

class HiveService {
  static const String boxName = 'geofence_alarm_box';

  static const String keyDeviceId = 'deviceId';
  static const String keyIsMuted = 'isMuted';
  static const String keyActiveRouteId = 'activeRouteId';
  static const String keyDestLatitude = 'destLatitude';
  static const String keyDestLongitude = 'destLongitude';
  static const String keyDestName = 'destName';
  static const String keyIsTracking = 'isTracking';
  static const String keyLastDistance = 'lastDistance';

  static const String keyNotified1km = 'notified_1km';
  static const String keyNotified500m = 'notified_500m';
  static const String keyNotified250m = 'notified_250m';

  static const String keyThresholdFarM = 'thresholdFarM';
  static const String keyThresholdMidM = 'thresholdMidM';
  static const String keyThresholdNearM = 'thresholdNearM';

  static const String keyFavorites = 'favorites';
  static const int maxFavorites = 8;

  static const String keyRouteHistory = 'routeHistory';
  static const String keyActiveHistoryId = 'activeHistoryId';
  static const int maxHistoryEntries = 50;

  static const String keyAlarmVolume = 'alarmVolume';
  static const String keyAlarmVibrate = 'alarmVibrate';
  static const double defaultAlarmVolume = 1.0;
  static const bool defaultAlarmVibrate = true;

  // Initialize Hive
  static Future<void> init() async {
    await Hive.initFlutter();
    await openBox();
  }

  static Future<Box> openBox() async {
    return await Hive.openBox(boxName);
  }

  /// Backend'e gönderilen isteklerde rota sahipliğini kanıtlamak için kullanılan,
  /// cihaza özgü kalıcı bir kimlik. İlk çağrıda üretilip Hive'a yazılır, sonraki
  /// çağrılarda aynı değer döner. Uygulama açılışında (main.dart) bir kez
  /// çağrılarak arka plan izolatının Hive'a eşzamanlı yazma yapması engellenir;
  /// diğer yerler yalnızca [getDeviceId] ile okur.
  static Future<String> getOrCreateDeviceId() async {
    final box = await openBox();
    String? id = box.get(keyDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await box.put(keyDeviceId, id);
    }
    return id;
  }

  static Future<String?> getDeviceId() async {
    final box = await openBox();
    return box.get(keyDeviceId);
  }

  // Setters
  static Future<void> setIsMuted(bool value) async {
    final box = await openBox();
    await box.put(keyIsMuted, value);
  }

  static Future<void> setTrackingState({
    required int routeId,
    required String name,
    required double lat,
    required double lng,
  }) async {
    final box = await openBox();
    await box.put(keyActiveRouteId, routeId);
    await box.put(keyDestName, name);
    await box.put(keyDestLatitude, lat);
    await box.put(keyDestLongitude, lng);
    await box.put(keyIsTracking, true);
    await box.put(keyIsMuted, false);
    // Önceki oturumun eski mesafesini sil → yeni TrackingPage "Hesaplanıyor..." göstersin
    await box.delete(keyLastDistance);
    
    // Reset notification trigger flags
    await box.put(keyNotified1km, false);
    await box.put(keyNotified500m, false);
    await box.put(keyNotified250m, false);
  }

  static Future<void> stopTracking() async {
    final box = await openBox();
    await box.put(keyIsTracking, false);
    await box.put(keyActiveRouteId, null);
  }

  static Future<void> setLastDistance(double distance) async {
    final box = await openBox();
    await box.put(keyLastDistance, distance);
  }

  static Future<void> setNotified1km(bool value) async {
    final box = await openBox();
    await box.put(keyNotified1km, value);
  }

  static Future<void> setNotified500m(bool value) async {
    final box = await openBox();
    await box.put(keyNotified500m, value);
  }

  static Future<void> setNotified250m(bool value) async {
    final box = await openBox();
    await box.put(keyNotified250m, value);
  }

  // Getters
  static Future<bool> getIsMuted() async {
    final box = await openBox();
    return box.get(keyIsMuted, defaultValue: false);
  }

  static Future<int?> getActiveRouteId() async {
    final box = await openBox();
    return box.get(keyActiveRouteId);
  }

  static Future<String?> getDestName() async {
    final box = await openBox();
    return box.get(keyDestName);
  }

  static Future<double?> getDestLatitude() async {
    final box = await openBox();
    return box.get(keyDestLatitude);
  }

  static Future<double?> getDestLongitude() async {
    final box = await openBox();
    return box.get(keyDestLongitude);
  }

  static Future<bool> getIsTracking() async {
    final box = await openBox();
    return box.get(keyIsTracking, defaultValue: false);
  }

  static Future<double?> getLastDistance() async {
    final box = await openBox();
    return box.get(keyLastDistance);
  }

  static Future<bool> getNotified1km() async {
    final box = await openBox();
    return box.get(keyNotified1km, defaultValue: false);
  }

  static Future<bool> getNotified500m() async {
    final box = await openBox();
    return box.get(keyNotified500m, defaultValue: false);
  }

  static Future<bool> getNotified250m() async {
    final box = await openBox();
    return box.get(keyNotified250m, defaultValue: false);
  }

  // ── Alarm Eşikleri ──────────────────────────────────────────────
  static Future<void> setThresholds(AlarmThresholds thresholds) async {
    final box = await openBox();
    await box.put(keyThresholdFarM, thresholds.farM);
    await box.put(keyThresholdMidM, thresholds.midM);
    await box.put(keyThresholdNearM, thresholds.nearM);
  }

  static Future<AlarmThresholds> getThresholds() async {
    final box = await openBox();
    return AlarmThresholds(
      farM: box.get(keyThresholdFarM, defaultValue: AlarmThresholds.defaults.farM),
      midM: box.get(keyThresholdMidM, defaultValue: AlarmThresholds.defaults.midM),
      nearM: box.get(keyThresholdNearM, defaultValue: AlarmThresholds.defaults.nearM),
    );
  }

  // ── Favori Hedefler ─────────────────────────────────────────────
  static Future<List<FavoriteDestination>> getFavorites() async {
    final box = await openBox();
    final List raw = box.get(keyFavorites, defaultValue: const []);
    return raw
        .whereType<Map>()
        .map((m) => FavoriteDestination.fromMap(m))
        .toList(growable: false);
  }

  static Future<void> addFavorite(FavoriteDestination favorite) async {
    final box = await openBox();
    final favorites = await getFavorites();
    // Aynı isimde bir favori varsa güncelle, yoksa başa ekle.
    final updated = [
      favorite,
      ...favorites.where((f) => f.name != favorite.name),
    ].take(maxFavorites).toList();
    await box.put(keyFavorites, updated.map((f) => f.toMap()).toList());
  }

  static Future<void> removeFavorite(String name) async {
    final box = await openBox();
    final favorites = await getFavorites();
    final updated = favorites.where((f) => f.name != name).toList();
    await box.put(keyFavorites, updated.map((f) => f.toMap()).toList());
  }

  static Future<void> clearAll() async {
    final box = await openBox();
    await box.clear();
  }

  // ── Geçmiş Rotalar (cihazda yerel olarak saklanır) ──────────────
  static Future<void> setActiveHistoryId(String id) async {
    final box = await openBox();
    await box.put(keyActiveHistoryId, id);
  }

  static Future<String?> getActiveHistoryId() async {
    final box = await openBox();
    return box.get(keyActiveHistoryId);
  }

  static Future<List<RouteHistoryEntry>> getHistory() async {
    final box = await openBox();
    final List raw = box.get(keyRouteHistory, defaultValue: const []);
    return raw
        .whereType<Map>()
        .map((m) => RouteHistoryEntry.fromMap(m))
        .toList(growable: false);
  }

  static Future<void> addHistoryEntry(RouteHistoryEntry entry) async {
    final box = await openBox();
    final history = await getHistory();
    // Yeni kayıt en başa eklenir (en yeniden en eskiye sıralama).
    final updated = [entry, ...history].take(maxHistoryEntries).toList();
    await box.put(keyRouteHistory, updated.map((e) => e.toMap()).toList());
  }

  static Future<void> updateHistoryEntryStatus(
    String id, {
    required String status,
    bool? isMuted,
  }) async {
    final box = await openBox();
    final history = await getHistory();
    final updated = history
        .map((e) => e.id == id ? e.copyWith(status: status, isMuted: isMuted) : e)
        .toList();
    await box.put(keyRouteHistory, updated.map((e) => e.toMap()).toList());
  }

  /// Yeni bir takip oturumu başlarken, hâlâ "ACTIVE" görünen eski geçmiş
  /// kayıtlarını "Susturuldu" olarak kapatır. Backend de aynı şeyi
  /// (aynı cihazın önceki aktif rotasını MUTED yapar) kendi tarafında
  /// yaptığından, yerel geçmiş sonsuza dek "Takip Ediliyor" göstermesin.
  static Future<void> closeStaleActiveHistoryEntries() async {
    final box = await openBox();
    final history = await getHistory();
    final updated = history
        .map((e) => e.status == 'ACTIVE' ? e.copyWith(status: 'MUTED', isMuted: true) : e)
        .toList();
    await box.put(keyRouteHistory, updated.map((e) => e.toMap()).toList());
  }

  static Future<void> removeHistoryEntry(String id) async {
    final box = await openBox();
    final history = await getHistory();
    final updated = history.where((e) => e.id != id).toList();
    await box.put(keyRouteHistory, updated.map((e) => e.toMap()).toList());
  }

  static Future<void> clearHistory() async {
    final box = await openBox();
    await box.put(keyRouteHistory, <Map>[]);
  }

  // ── Alarm Sesi ve Titreşim ───────────────────────────────────────
  static Future<double> getAlarmVolume() async {
    final box = await openBox();
    return box.get(keyAlarmVolume, defaultValue: defaultAlarmVolume);
  }

  static Future<void> setAlarmVolume(double volume) async {
    final box = await openBox();
    await box.put(keyAlarmVolume, volume.clamp(0.1, 1.0));
  }

  static Future<bool> getAlarmVibrate() async {
    final box = await openBox();
    return box.get(keyAlarmVibrate, defaultValue: defaultAlarmVibrate);
  }

  static Future<void> setAlarmVibrate(bool vibrate) async {
    final box = await openBox();
    await box.put(keyAlarmVibrate, vibrate);
  }
}

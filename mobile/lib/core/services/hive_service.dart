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
}

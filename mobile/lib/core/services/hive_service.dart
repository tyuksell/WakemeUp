import 'package:hive_flutter/hive_flutter.dart';

class HiveService {
  static const String boxName = 'geofence_alarm_box';
  
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

  // Initialize Hive
  static Future<void> init() async {
    await Hive.initFlutter();
    await openBox();
  }

  static Future<Box> openBox() async {
    return await Hive.openBox(boxName);
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

  static Future<void> clearAll() async {
    final box = await openBox();
    await box.clear();
  }
}

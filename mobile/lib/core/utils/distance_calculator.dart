import 'dart:math';

/// Haversine formülüyle iki GPS koordinatı arasındaki kuş uçuşu
/// (as-the-crow-flies) mesafeyi metre cinsinden hesaplar.
///
/// ⚠️ ÖNEMLİ — SORUN 2 NOTU:
/// Bu fonksiyon **kuş uçuşu** mesafe döndürür, gerçek yol mesafesi değil.
/// Kızılay → Bahçelievler örneğinde kuş uçuşu ~4.8 km, yol mesafesi ~7-9 km
/// olabilir; bu fark kullanıcıya "yanlış hesaplıyor" gibi görünür.
///
/// Gerçek yol mesafesi için Mapbox Directions API kullanılmalı;
/// ancak bu uygulama offline-first geofence uyarıları için mesafe hesapladığından
/// (yaklaşma tespiti) Haversine yeterlidir. Ekran gösterimi için kullanıcı bilgilendirilmeli.
///
/// Koordinatlar: lat/lng sıralaması doğru (lat1, lon1, lat2, lon2).
/// Birim: metre → km dönüşümü /1000 ile yapılmalı (mil KULLANILMIYOR).
class DistanceCalculator {
  /// [lat1], [lon1]: Başlangıç noktası (enlem, boylam) — Türkiye: 36-42°N, 26-45°E
  /// [lat2], [lon2]: Varış noktası (enlem, boylam)
  /// Dönüş: metre cinsinden kuş uçuşu mesafe.
  static double calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    // SORUN 2 GÜVENLİK: Null Island (0,0) koordinat kontrolü
    if ((lat1 == 0.0 && lon1 == 0.0) || (lat2 == 0.0 && lon2 == 0.0)) {
      // ignore: avoid_print
      print(
        '[DistanceCalculator] UYARI: Null Island koordinatı tespit edildi! '
        'lat1=$lat1,lon1=$lon1 → lat2=$lat2,lon2=$lon2. '
        'GPS sinyali veya destination eksik olabilir.',
      );
    }

    const double r = 6371000.0; // Dünya yarıçapı (metre)

    // Sıra kontrolü: dLat = lat2 - lat1, dLon = lon2 - lon1 (enlem/boylam
    // yer değiştirilmemiş — lat birincil, lon ikincil parametre)
    final double dLat = _toRadians(lat2 - lat1);
    final double dLon = _toRadians(lon2 - lon1);

    final double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c; // Sonuç: metre (km için /1000 kullan)
  }

  /// Dereceyi radyana çevirir.
  static double _toRadians(double degree) => degree * pi / 180.0;
}

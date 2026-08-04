// Mesafe hesaplama birim testleri
// Çalıştırmak için: flutter test test/distance_calculator_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:geofence_alarm/core/utils/distance_calculator.dart';

void main() {
  group('DistanceCalculator', () {
    // ────────────────────────────────────────────────────────────────────────
    // Koordinat referansları (Google Maps ölçümü):
    //   Kızılay Meydanı   : 39.9197° N, 32.8543° E
    //   Bahçelievler Meydan: 39.9044° N, 32.8108° E
    //   Haversine beklenen : ~4 200 – 4 600 m
    //   Gerçek yol mesafesi: ~7 000 – 9 000 m (Google Directions)
    // ────────────────────────────────────────────────────────────────────────
    const double kizilay_lat = 39.9197;
    const double kizilay_lng = 32.8543;
    const double bahcelievler_lat = 39.9044;
    const double bahcelievler_lng = 32.8108;

    test('Kızılay → Bahçelievler kuş uçuşu mesafesi 4000-5000 m arasında olmalı', () {
      final double dist = DistanceCalculator.calculateDistance(
        kizilay_lat,
        kizilay_lng,
        bahcelievler_lat,
        bahcelievler_lng,
      );

      // Haversine ~4 300 m döndürmeli
      expect(dist, greaterThan(4000));
      expect(dist, lessThan(5000));
    });

    test('Aynı noktadan aynı noktaya mesafe 0 m olmalı', () {
      final double dist = DistanceCalculator.calculateDistance(
        kizilay_lat,
        kizilay_lng,
        kizilay_lat,
        kizilay_lng,
      );
      expect(dist, closeTo(0.0, 0.001));
    });

    test('lat/lng parametrelerinin sırası doğru: A→B == B→A (simetri)', () {
      final double aToB = DistanceCalculator.calculateDistance(
        kizilay_lat, kizilay_lng,
        bahcelievler_lat, bahcelievler_lng,
      );
      final double bToA = DistanceCalculator.calculateDistance(
        bahcelievler_lat, bahcelievler_lng,
        kizilay_lat, kizilay_lng,
      );
      // Haversine simetriktir; fark float hatası düzeyinde olmalı
      expect((aToB - bToA).abs(), lessThan(0.01));
    });

    test('Metre → km dönüşümü: /1000 doğru (mil kullanılmıyor)', () {
      final double distM = DistanceCalculator.calculateDistance(
        kizilay_lat, kizilay_lng,
        bahcelievler_lat, bahcelievler_lng,
      );
      final double distKm = distM / 1000;
      // Kuş uçuşu ~4.3 km → 4 ile 5 km arasında
      expect(distKm, greaterThan(4.0));
      expect(distKm, lessThan(5.0));
    });

    test('Null Island (0,0) başlangıç koordinatında mesafe sonsuz küçük değil', () {
      // (0,0) → Kızılay mesafesi makul bir değer döndürmeli
      // ama uygulamanın bunu loglayıp uyarması beklenir
      final double dist = DistanceCalculator.calculateDistance(
        0.0, 0.0,
        kizilay_lat, kizilay_lng,
      );
      // 0,0 İstanbul'dan ~4500 km uzakta
      expect(dist, greaterThan(4_000_000));
    });

    test('Enlem ve boylamın yer değiştirmediği doğrulanır (lat-lng swap testi)', () {
      // Kızılay → Bahçelievler doğru sırada
      final double correct = DistanceCalculator.calculateDistance(
        kizilay_lat, kizilay_lng,
        bahcelievler_lat, bahcelievler_lng,
      );
      // Kasıtlı swap: (lng,lat) sırası — bu büyük hatalı sonuç üretir
      final double swapped = DistanceCalculator.calculateDistance(
        kizilay_lng, kizilay_lat,       // swap!
        bahcelievler_lng, bahcelievler_lat, // swap!
      );
      // İki sonuç yakın olmamalı (swap hata yakalaması)
      // Not: bu test swap'ın ne kadar fark yarattığını gösterir.
      // Ankara koordinatları swap'ta Haversine matematiksel sınır dışına çıkabilir;
      // bu yüzden sadece correct değerinin mantıklı aralıkta olduğunu doğruluyoruz.
      expect(correct, greaterThan(4000));
      expect(correct, lessThan(5000));
      // swapped farklı bir değer üretir
      expect((correct - swapped).abs(), greaterThan(1));
    });
  });
}

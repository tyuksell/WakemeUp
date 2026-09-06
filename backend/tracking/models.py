from django.db import models
import math

class TargetRoute(models.Model):
    STATUS_CHOICES = [
        ('PENDING', 'Başlatılmadı'),
        ('ACTIVE', 'Takip Ediliyor'),
        ('MUTED', 'Susturuldu / İptal Edildi'),
        ('ARRIVED', 'Varış Noktasına Ulaşıldı'),
    ]

    # Uygulamada hesap sistemi yok; her cihaz ilk açılışta bir UUID üretip saklıyor.
    # Bu alan, rotaların sahiplik kontrolü için kullanılıyor (bkz. views.py).
    device_id = models.CharField(max_length=64, blank=True, default='', db_index=True, verbose_name="Cihaz Kimliği")
    destination_name = models.CharField(max_length=255, verbose_name="Varış Noktası Adı")

    # Koordinatlar
    dest_latitude = models.FloatField(verbose_name="Hedef Enlem")
    dest_longitude = models.FloatField(verbose_name="Hedef Boylam")

    # Rota Durum Kontrolü
    status = models.CharField(max_length=15, choices=STATUS_CHOICES, default='ACTIVE')
    is_muted = models.BooleanField(default=False, verbose_name="Susturuldu mu?")

    # Kademeli tetiklenme durum logları (Tekrar çalmaması için)
    notified_1km = models.BooleanField(default=False)
    notified_500m = models.BooleanField(default=False)
    notified_250m = models.BooleanField(default=False)

    # Kademeli alarm mesafe eşikleri (metre) — kullanıcı Ayarlar ekranından
    # değiştirebilir; belirtilmezse varsayılan 1km/500m/250m kullanılır.
    threshold_far_m = models.PositiveIntegerField(default=1000, verbose_name="Uzak Mesafe Eşiği (m)")
    threshold_mid_m = models.PositiveIntegerField(default=500, verbose_name="Orta Mesafe Eşiği (m)")
    threshold_near_m = models.PositiveIntegerField(default=250, verbose_name="Yakın Mesafe Eşiği (m)")

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def calculate_distance_to(self, current_lat, current_lng):
        """
        Haversine formülü ile iki nokta arasındaki mesafeyi metre cinsinden hesaplar.
        """
        R = 6371000.0  # Dünyanın yarıçapı (metre)

        lat1 = math.radians(current_lat)
        lon1 = math.radians(current_lng)
        lat2 = math.radians(self.dest_latitude)
        lon2 = math.radians(self.dest_longitude)

        dlon = lon2 - lon1
        dlat = lat2 - lat1

        a = math.sin(dlat / 2)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

        return R * c

    def __str__(self):
        return f"{self.destination_name} - {self.status}"

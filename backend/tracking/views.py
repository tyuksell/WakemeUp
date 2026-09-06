import logging

from rest_framework import status
from rest_framework.decorators import api_view
from rest_framework.response import Response
from django.shortcuts import get_object_or_404
from .models import TargetRoute

logger = logging.getLogger(__name__)

DEFAULT_THRESHOLDS = {'far': 1000, 'mid': 500, 'near': 250}
MAX_THRESHOLD_M = 20000  # 20 km — makul bir üst sınır


def _get_device_id(request):
    """Uygulama hesap sistemi kullanmadığı için sahiplik, mobil istemcinin
    ilk açılışta ürettiği ve her istekte gönderdiği X-Device-Id başlığı ile
    kontrol edilir (bkz. mobile/lib/core/services/hive_service.dart).
    """
    return request.headers.get('X-Device-Id', '').strip()


def _parse_coordinate(value, name, min_value, max_value):
    """Bir enlem/boylam değerini doğrular. Geçersizse (None, hata_mesajı) döner."""
    if value is None:
        return None, f"{name} alanı zorunludur."
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None, f"{name} sayısal bir değer olmalıdır."
    if not (min_value <= parsed <= max_value):
        return None, f"{name} {min_value} ile {max_value} arasında olmalıdır."
    return parsed, None


def _parse_thresholds(data):
    """Rota için kademeli alarm eşiklerini doğrular. Hiçbiri gönderilmemişse
    varsayılanlar kullanılır. Gönderilmişse üçü de zorunludur ve
    far > mid > near > 0 sıralamasına uymalıdır. Geçersizse (None, hata_mesajı) döner.
    """
    raw = {
        'far': data.get('threshold_far_m'),
        'mid': data.get('threshold_mid_m'),
        'near': data.get('threshold_near_m'),
    }
    if all(v is None for v in raw.values()):
        return DEFAULT_THRESHOLDS, None
    if any(v is None for v in raw.values()):
        return None, "Eşik değerleri gönderiliyorsa threshold_far_m, threshold_mid_m ve threshold_near_m alanlarının hepsi zorunludur."

    parsed = {}
    for key, value in raw.items():
        try:
            parsed[key] = int(value)
        except (TypeError, ValueError):
            return None, f"threshold_{key}_m tam sayı olmalıdır."
        if not (0 < parsed[key] <= MAX_THRESHOLD_M):
            return None, f"threshold_{key}_m 0 ile {MAX_THRESHOLD_M} arasında olmalıdır."

    if not (parsed['far'] > parsed['mid'] > parsed['near']):
        return None, "Eşikler threshold_far_m > threshold_mid_m > threshold_near_m sıralamasında olmalıdır."

    return parsed, None


@api_view(['GET', 'POST'])
def routes_collection(request):
    if request.method == 'GET':
        return _list_routes(request)
    return _create_route(request)


def _list_routes(request):
    """Cihazın geçmiş rotalarını (en yeniden en eskiye) listeler."""
    device_id = _get_device_id(request)
    if not device_id:
        return Response(
            {"error": "X-Device-Id başlığı zorunludur."},
            status=status.HTTP_400_BAD_REQUEST
        )

    routes = TargetRoute.objects.filter(device_id=device_id).order_by('-created_at')[:50]
    return Response([
        {
            "id": route.id,
            "destination_name": route.destination_name,
            "dest_latitude": route.dest_latitude,
            "dest_longitude": route.dest_longitude,
            "status": route.status,
            "is_muted": route.is_muted,
            "created_at": route.created_at,
        }
        for route in routes
    ], status=status.HTTP_200_OK)


def _create_route(request):
    """
    Kullanıcının yeni bir rota/hedef belirlemesini sağlar.
    """
    device_id = _get_device_id(request)
    if not device_id:
        return Response(
            {"error": "X-Device-Id başlığı zorunludur."},
            status=status.HTTP_400_BAD_REQUEST
        )

    destination_name = request.data.get('destination_name')
    if not destination_name or not str(destination_name).strip():
        return Response(
            {"error": "Lütfen destination_name alanını doldurun."},
            status=status.HTTP_400_BAD_REQUEST
        )

    dest_latitude, lat_error = _parse_coordinate(request.data.get('dest_latitude'), 'dest_latitude', -90, 90)
    if lat_error:
        return Response({"error": lat_error}, status=status.HTTP_400_BAD_REQUEST)

    dest_longitude, lng_error = _parse_coordinate(request.data.get('dest_longitude'), 'dest_longitude', -180, 180)
    if lng_error:
        return Response({"error": lng_error}, status=status.HTTP_400_BAD_REQUEST)

    thresholds, threshold_error = _parse_thresholds(request.data)
    if threshold_error:
        return Response({"error": threshold_error}, status=status.HTTP_400_BAD_REQUEST)

    try:
        # Aynı cihazın eski aktif rotalarını kapat (Aynı anda tek bir aktif rota takibi için).
        # Diğer cihazların rotalarına dokunulmaz.
        TargetRoute.objects.filter(status='ACTIVE', device_id=device_id).update(status='MUTED', is_muted=True)

        route = TargetRoute.objects.create(
            device_id=device_id,
            destination_name=destination_name,
            dest_latitude=dest_latitude,
            dest_longitude=dest_longitude,
            status='ACTIVE',
            is_muted=False,
            threshold_far_m=thresholds['far'],
            threshold_mid_m=thresholds['mid'],
            threshold_near_m=thresholds['near'],
        )
        return Response({
            "id": route.id,
            "destination_name": route.destination_name,
            "dest_latitude": route.dest_latitude,
            "dest_longitude": route.dest_longitude,
            "status": route.status,
            "is_muted": route.is_muted,
            "threshold_far_m": route.threshold_far_m,
            "threshold_mid_m": route.threshold_mid_m,
            "threshold_near_m": route.threshold_near_m,
            "created_at": route.created_at
        }, status=status.HTTP_201_CREATED)
    except Exception:
        logger.exception("create_route beklenmeyen bir hatayla karşılaştı.")
        return Response(
            {"error": "Rota oluşturulurken beklenmeyen bir hata oluştu."},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@api_view(['POST'])
def update_location(request, route_id):
    """
    Mobil cihazdan gelen anlık koordinat bilgisini alır, hedefe olan mesafeyi hesaplar
    ve kademeli geofence tetikleyicilerini kontrol eder.
    """
    device_id = _get_device_id(request)
    if not device_id:
        return Response(
            {"error": "X-Device-Id başlığı zorunludur."},
            status=status.HTTP_400_BAD_REQUEST
        )

    route = get_object_or_404(TargetRoute, pk=route_id)

    if route.device_id != device_id:
        return Response(
            {"error": "Bu rotaya erişim yetkiniz yok."},
            status=status.HTTP_403_FORBIDDEN
        )

    current_lat, lat_error = _parse_coordinate(request.data.get('current_latitude'), 'current_latitude', -90, 90)
    if lat_error:
        return Response({"error": lat_error}, status=status.HTTP_400_BAD_REQUEST)

    current_lng, lng_error = _parse_coordinate(request.data.get('current_longitude'), 'current_longitude', -180, 180)
    if lng_error:
        return Response({"error": lng_error}, status=status.HTTP_400_BAD_REQUEST)

    try:
        # Susturma durumu kontrolü (Kritik susturma kuralı)
        if route.is_muted or route.status == 'MUTED':
            return Response({
                "route_id": route.id,
                "distance_meters": route.calculate_distance_to(current_lat, current_lng),
                "status": "MUTED",
                "is_muted": True,
                "trigger_alarm": False,
                "target_stage": "MUTED",
                "message": "Takip susturulmuş durumda. Alarm tetiklenmeyecek."
            }, status=status.HTTP_200_OK)

        distance = route.calculate_distance_to(current_lat, current_lng)
        trigger_alarm = False
        target_stage = "OUT_OF_RANGE"
        message = "Hedef dışındasınız."

        # Kademeli Tetiklenme Kontrolü (Büyükten küçüğe doğru kontrol edilmelidir).
        # Eşikler rotaya özgüdür (bkz. threshold_far_m/mid_m/near_m — Ayarlar ekranından değiştirilebilir).
        if distance <= route.threshold_near_m:
            if not route.notified_250m:
                route.notified_250m = True
                route.notified_500m = True  # Bypass koruması
                route.notified_1km = True   # Bypass koruması
                route.status = 'ARRIVED'
                route.save()

                trigger_alarm = True
                target_stage = "STAGE_NEAR"
                message = f"Hedefe {route.threshold_near_m} metre veya daha az mesafe kaldı! Yüksek öncelikli alarm çalınmalı."
            else:
                target_stage = "STAGE_NEAR"
                message = "Yakın mesafe alarmı zaten tetiklendi."

        elif distance <= route.threshold_mid_m:
            if not route.notified_500m:
                route.notified_500m = True
                route.notified_1km = True   # Bypass koruması
                route.save()

                trigger_alarm = True
                target_stage = "STAGE_MID"
                message = f"Hedefe {route.threshold_mid_m} metre veya daha az mesafe kaldı! Bildirim/alarm tetiklenmeli."
            else:
                target_stage = "STAGE_MID"
                message = "Orta mesafe alarmı zaten tetiklendi."

        elif distance <= route.threshold_far_m:
            if not route.notified_1km:
                route.notified_1km = True
                route.save()

                trigger_alarm = True
                target_stage = "STAGE_FAR"
                message = f"Hedefe {route.threshold_far_m} metre veya daha az mesafe kaldı! Bildirim/alarm tetiklenmeli."
            else:
                target_stage = "STAGE_FAR"
                message = "Uzak mesafe alarmı zaten tetiklendi."
        else:
            message = f"Hedefe {round(distance, 1)} metre kaldı."

        return Response({
            "route_id": route.id,
            "distance_meters": round(distance, 2),
            "status": route.status,
            "is_muted": route.is_muted,
            "trigger_alarm": trigger_alarm,
            "target_stage": target_stage,
            "message": message
        }, status=status.HTTP_200_OK)

    except Exception:
        logger.exception("update_location beklenmeyen bir hatayla karşılaştı. route_id=%s", route_id)
        return Response(
            {"error": "Konum işlenirken beklenmeyen bir hata oluştu."},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@api_view(['POST'])
def mute_route(request, route_id):
    """
    Kullanıcı alarmı kapattığında (susturduğunda) çağrılır.
    """
    device_id = _get_device_id(request)
    if not device_id:
        return Response(
            {"error": "X-Device-Id başlığı zorunludur."},
            status=status.HTTP_400_BAD_REQUEST
        )

    route = get_object_or_404(TargetRoute, pk=route_id)

    if route.device_id != device_id:
        return Response(
            {"error": "Bu rotaya erişim yetkiniz yok."},
            status=status.HTTP_403_FORBIDDEN
        )

    route.is_muted = True
    route.status = 'MUTED'
    route.save()

    return Response({
        "route_id": route.id,
        "status": route.status,
        "is_muted": route.is_muted,
        "message": "Rota takibi susturuldu. Gelecek alarm tetiklemeleri tamamen kapatıldı."
    }, status=status.HTTP_200_OK)

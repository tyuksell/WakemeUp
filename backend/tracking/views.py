from rest_framework import status
from rest_framework.decorators import api_view
from rest_framework.response import Response
from django.shortcuts import get_object_or_404
from .models import TargetRoute

@api_view(['POST'])
def create_route(request):
    """
    Kullanıcının yeni bir rota/hedef belirlemesini sağlar.
    """
    destination_name = request.data.get('destination_name')
    dest_latitude = request.data.get('dest_latitude')
    dest_longitude = request.data.get('dest_longitude')

    if not destination_name or dest_latitude is None or dest_longitude is None:
        return Response(
            {"error": "Lütfen destination_name, dest_latitude ve dest_longitude alanlarını doldurun."},
            status=status.HTTP_400_BAD_REQUEST
        )

    try:
        # Eski aktif rotaları temizle/kapat (Aynı anda tek bir aktif rota takibi için)
        TargetRoute.objects.filter(status='ACTIVE').update(status='MUTED', is_muted=True)

        route = TargetRoute.objects.create(
            destination_name=destination_name,
            dest_latitude=float(dest_latitude),
            dest_longitude=float(dest_longitude),
            status='ACTIVE',
            is_muted=False
        )
        return Response({
            "id": route.id,
            "destination_name": route.destination_name,
            "dest_latitude": route.dest_latitude,
            "dest_longitude": route.dest_longitude,
            "status": route.status,
            "is_muted": route.is_muted,
            "created_at": route.created_at
        }, status=status.HTTP_201_CREATED)
    except Exception as e:
        return Response({"error": str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


@api_view(['POST'])
def update_location(request, route_id):
    """
    Mobil cihazdan gelen anlık koordinat bilgisini alır, hedefe olan mesafeyi hesaplar
    ve kademeli geofence tetikleyicilerini kontrol eder.
    """
    route = get_object_or_404(TargetRoute, pk=route_id)
    
    current_lat = request.data.get('current_latitude')
    current_lng = request.data.get('current_longitude')

    if current_lat is None or current_lng is None:
        return Response(
            {"error": "Lütfen current_latitude ve current_longitude alanlarını doldurun."},
            status=status.HTTP_400_BAD_REQUEST
        )

    try:
        current_lat = float(current_lat)
        current_lng = float(current_lng)
        
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

        # Kademeli Tetiklenme Kontrolü (Büyükten küçüğe doğru kontrol edilmelidir)
        if distance <= 250:
            if not route.notified_250m:
                route.notified_250m = True
                route.notified_500m = True  # Bypass koruması
                route.notified_1km = True   # Bypass koruması
                route.status = 'ARRIVED'
                route.save()
                
                trigger_alarm = True
                target_stage = "STAGE_250M"
                message = "Hedefe 250 metre veya daha az mesafe kaldı! Yüksek öncelikli alarm çalınmalı."
            else:
                target_stage = "STAGE_250M"
                message = "250m alarmı zaten tetiklendi."
                
        elif distance <= 500:
            if not route.notified_500m:
                route.notified_500m = True
                route.notified_1km = True   # Bypass koruması
                route.save()
                
                trigger_alarm = True
                target_stage = "STAGE_500M"
                message = "Hedefe 500 metre veya daha az mesafe kaldı! Bildirim/alarm tetiklenmeli."
            else:
                target_stage = "STAGE_500M"
                message = "500m alarmı zaten tetiklendi."
                
        elif distance <= 1000:
            if not route.notified_1km:
                route.notified_1km = True
                route.save()
                
                trigger_alarm = True
                target_stage = "STAGE_1KM"
                message = "Hedefe 1 km veya daha az mesafe kaldı! Bildirim/alarm tetiklenmeli."
            else:
                target_stage = "STAGE_1KM"
                message = "1km alarmı zaten tetiklendi."
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
        
    except Exception as e:
        return Response({"error": str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


@api_view(['POST'])
def mute_route(request, route_id):
    """
    Kullanıcı alarmı kapattığında (susturduğunda) çağrılır.
    """
    route = get_object_or_404(TargetRoute, pk=route_id)
    route.is_muted = True
    route.status = 'MUTED'
    route.save()
    
    return Response({
        "route_id": route.id,
        "status": route.status,
        "is_muted": route.is_muted,
        "message": "Rota takibi susturuldu. Gelecek alarm tetiklemeleri tamamen kapatıldı."
    }, status=status.HTTP_200_OK)

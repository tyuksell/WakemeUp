from django.test import TestCase
from rest_framework.test import APIClient

from .models import TargetRoute

# Kadıköy Metro İstasyonu civarı - test koordinatları
DEST_LAT, DEST_LNG = 40.9901, 29.0223


class TargetRouteDistanceTests(TestCase):
    def test_calculate_distance_to_same_point_is_zero(self):
        route = TargetRoute.objects.create(
            device_id='dev-1', destination_name='Test', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        self.assertAlmostEqual(route.calculate_distance_to(DEST_LAT, DEST_LNG), 0.0, delta=0.01)

    def test_calculate_distance_to_known_offset(self):
        # ~1 derece enlem farkı kabaca 111 km'ye denk gelir (Haversine doğrulaması).
        route = TargetRoute.objects.create(
            device_id='dev-1', destination_name='Test', dest_latitude=0.0, dest_longitude=0.0,
        )
        distance = route.calculate_distance_to(1.0, 0.0)
        self.assertAlmostEqual(distance, 111195, delta=500)


class RouteApiTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.device_headers = {'HTTP_X_DEVICE_ID': 'device-a'}
        self.other_device_headers = {'HTTP_X_DEVICE_ID': 'device-b'}

    def test_create_route_requires_device_id(self):
        response = self.client.post('/api/routes/', {
            'destination_name': 'Kadıköy Metro', 'dest_latitude': DEST_LAT, 'dest_longitude': DEST_LNG,
        })
        self.assertEqual(response.status_code, 400)

    def test_create_route_rejects_invalid_coordinates(self):
        response = self.client.post('/api/routes/', {
            'destination_name': 'Kadıköy Metro', 'dest_latitude': 999, 'dest_longitude': DEST_LNG,
        }, **self.device_headers)
        self.assertEqual(response.status_code, 400)

    def test_create_route_only_mutes_same_devices_active_route(self):
        first = TargetRoute.objects.create(
            device_id='device-a', destination_name='Eski Hedef', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
            status='ACTIVE',
        )
        other_devices_route = TargetRoute.objects.create(
            device_id='device-b', destination_name='Başka Cihazın Rotası', dest_latitude=DEST_LAT,
            dest_longitude=DEST_LNG, status='ACTIVE',
        )

        response = self.client.post('/api/routes/', {
            'destination_name': 'Yeni Hedef', 'dest_latitude': DEST_LAT, 'dest_longitude': DEST_LNG,
        }, **self.device_headers)

        self.assertEqual(response.status_code, 201)
        first.refresh_from_db()
        other_devices_route.refresh_from_db()
        self.assertEqual(first.status, 'MUTED')
        self.assertEqual(other_devices_route.status, 'ACTIVE')  # başka cihazın rotasına dokunulmamalı

    def test_update_location_rejects_other_devices_route(self):
        route = TargetRoute.objects.create(
            device_id='device-a', destination_name='Kadıköy Metro', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        response = self.client.post(f'/api/routes/{route.id}/update-location/', {
            'current_latitude': DEST_LAT, 'current_longitude': DEST_LNG,
        }, **self.other_device_headers)
        self.assertEqual(response.status_code, 403)

    def test_update_location_triggers_staged_alarms_once(self):
        route = TargetRoute.objects.create(
            device_id='device-a', destination_name='Kadıköy Metro', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        # ~900m uzakta bir nokta -> 1km eşiği tetiklenmeli
        response = self.client.post(f'/api/routes/{route.id}/update-location/', {
            'current_latitude': DEST_LAT + 0.008, 'current_longitude': DEST_LNG,
        }, **self.device_headers)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['trigger_alarm'])
        self.assertEqual(response.data['target_stage'], 'STAGE_FAR')

        # Aynı mesafede tekrar istek atılırsa alarm bir daha tetiklenmemeli (bypass koruması)
        response2 = self.client.post(f'/api/routes/{route.id}/update-location/', {
            'current_latitude': DEST_LAT + 0.008, 'current_longitude': DEST_LNG,
        }, **self.device_headers)
        self.assertFalse(response2.data['trigger_alarm'])

    def test_mute_route_stops_future_alarms(self):
        route = TargetRoute.objects.create(
            device_id='device-a', destination_name='Kadıköy Metro', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        mute_response = self.client.post(f'/api/routes/{route.id}/mute/', **self.device_headers)
        self.assertEqual(mute_response.status_code, 200)
        self.assertTrue(mute_response.data['is_muted'])

        update_response = self.client.post(f'/api/routes/{route.id}/update-location/', {
            'current_latitude': DEST_LAT, 'current_longitude': DEST_LNG,
        }, **self.device_headers)
        self.assertFalse(update_response.data['trigger_alarm'])
        self.assertEqual(update_response.data['status'], 'MUTED')

    def test_mute_route_rejects_other_devices_route(self):
        route = TargetRoute.objects.create(
            device_id='device-a', destination_name='Kadıköy Metro', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        response = self.client.post(f'/api/routes/{route.id}/mute/', **self.other_device_headers)
        self.assertEqual(response.status_code, 403)

    def test_list_routes_only_returns_own_devices_routes(self):
        TargetRoute.objects.create(
            device_id='device-a', destination_name='Kadıköy Metro', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        TargetRoute.objects.create(
            device_id='device-b', destination_name='Başka Cihazın Rotası', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
        )
        response = self.client.get('/api/routes/', **self.device_headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]['destination_name'], 'Kadıköy Metro')

    def test_create_route_with_custom_thresholds(self):
        response = self.client.post('/api/routes/', {
            'destination_name': 'Kadıköy Metro', 'dest_latitude': DEST_LAT, 'dest_longitude': DEST_LNG,
            'threshold_far_m': 2000, 'threshold_mid_m': 1000, 'threshold_near_m': 300,
        }, **self.device_headers)
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data['threshold_far_m'], 2000)
        self.assertEqual(response.data['threshold_mid_m'], 1000)
        self.assertEqual(response.data['threshold_near_m'], 300)

    def test_create_route_rejects_out_of_order_thresholds(self):
        response = self.client.post('/api/routes/', {
            'destination_name': 'Kadıköy Metro', 'dest_latitude': DEST_LAT, 'dest_longitude': DEST_LNG,
            'threshold_far_m': 300, 'threshold_mid_m': 1000, 'threshold_near_m': 2000,
        }, **self.device_headers)
        self.assertEqual(response.status_code, 400)

    def test_update_location_uses_routes_custom_thresholds(self):
        route = TargetRoute.objects.create(
            device_id='device-a', destination_name='Kadıköy Metro', dest_latitude=DEST_LAT, dest_longitude=DEST_LNG,
            threshold_far_m=2000, threshold_mid_m=1000, threshold_near_m=300,
        )
        # ~900m uzakta bir nokta: varsayılan eşiklerle STAGE_MID (500m alanı) tetiklenirdi,
        # ama bu rotanın özel eşiklerinde 1000m "mid" sınırının içinde -> STAGE_MID yine tetiklenir.
        response = self.client.post(f'/api/routes/{route.id}/update-location/', {
            'current_latitude': DEST_LAT + 0.008, 'current_longitude': DEST_LNG,
        }, **self.device_headers)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['trigger_alarm'])
        self.assertEqual(response.data['target_stage'], 'STAGE_MID')

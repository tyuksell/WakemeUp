import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'core/theme/app_theme.dart';
import 'core/services/hive_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/background_service.dart';
import 'features/presentation/pages/home_page.dart';
import 'features/presentation/pages/tracking_page.dart';
import 'features/presentation/widgets/center_toast.dart';

void main() async {
  // Ensure Flutter engine is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Load .env file (contains MAPBOX_ACCESS_TOKEN)
  await dotenv.load(fileName: '.env');

  // Initialize Mapbox with the token from .env
  final String mapboxToken = dotenv.env['MAPBOX_ACCESS_TOKEN'] ?? '';
  MapboxOptions.setAccessToken(mapboxToken);

  // Initialize Services
  await HiveService.init();
  // Cihaz kimliği burada, tek bir yerde üretilir/okunur — böylece arka plan
  // izolatının Hive'a eşzamanlı yazması gerekmez (bkz. HiveService.getOrCreateDeviceId).
  await HiveService.getOrCreateDeviceId();
  await NotificationService.init();
  await MyBackgroundService.initializeService();

  // Uygulama tamamen kapatılıp arka plan bildirimine (takip bildirimi ya da
  // alarm) dokunularak yeniden açıldığında ana isolate sıfırdan burada
  // başlar. Böyle bir anda hâlâ aktif bir takip varsa kullanıcıyı açılış
  // sayfası yerine doğrudan takip ekranına götürüyoruz.
  final bool startOnTracking = await HiveService.getIsTracking();

  runApp(MyApp(startOnTracking: startOnTracking));
}

class MyApp extends StatelessWidget {
  final bool startOnTracking;

  const MyApp({super.key, this.startOnTracking = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geofence Smart Alarm',
      debugShowCheckedModeBanner: false,
      // Uygulama kimliği koyu/neon temaya göre tasarlandı; açık tema desteklenmiyor.
      theme: AppTheme.darkTheme,
      navigatorObservers: [ToastDismissObserver()],
      home: startOnTracking ? const TrackingPage() : const HomePage(),
    );
  }
}

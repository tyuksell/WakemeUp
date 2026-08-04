import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'core/theme/app_theme.dart';
import 'core/services/hive_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/background_service.dart';
import 'features/presentation/pages/home_page.dart';

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
  await NotificationService.init();
  await MyBackgroundService.initializeService();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geofence Smart Alarm',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark, // Defaulting to Dark Mode for premium neon visual effect
      home: const HomePage(),
    );
  }
}

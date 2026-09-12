import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'core/theme/app_theme.dart';
import 'core/services/hive_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/background_service.dart';
import 'core/services/crash_reporter.dart';
import 'core/locale_controller.dart';
import 'features/presentation/pages/home_page.dart';
import 'features/presentation/pages/onboarding_page.dart';
import 'features/presentation/pages/tracking_page.dart';
import 'features/presentation/widgets/center_toast.dart';
import 'l10n/app_localizations.dart';

void main() async {
  // Ensure Flutter engine is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Load .env file (contains MAPBOX_ACCESS_TOKEN, opsiyonel SENTRY_DSN)
  await dotenv.load(fileName: '.env');

  // CrashReporter, .env'de SENTRY_DSN tanımlıysa uygulamanın geri kalanını
  // Sentry'nin hata yakalama zone'u içinde çalıştırır; tanımlı değilse
  // appRunner'ı doğrudan (sarmalamadan) çalıştırır.
  await CrashReporter.initMainIsolate(() async {
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
    final bool hasSeenOnboarding = await HiveService.getHasSeenOnboarding();
    final String languageCode = await HiveService.getLanguageCode();
    appLocale.value = Locale(languageCode);

    runApp(MyApp(
      startOnTracking: startOnTracking,
      hasSeenOnboarding: hasSeenOnboarding,
    ));
  });
}

class MyApp extends StatelessWidget {
  final bool startOnTracking;
  final bool hasSeenOnboarding;

  const MyApp({
    super.key,
    this.startOnTracking = false,
    this.hasSeenOnboarding = true,
  });

  @override
  Widget build(BuildContext context) {
    // Öncelik sırası: aktif bir takip varsa (bildirimden dönülmüş olabilir)
    // doğrudan ona git; yoksa ve ilk kullanımsa tanıtım akışını göster;
    // aksi halde doğrudan ana sayfa.
    final Widget home = startOnTracking
        ? const TrackingPage()
        : (hasSeenOnboarding ? const HomePage() : const OnboardingPage());

    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
        debugShowCheckedModeBanner: false,
        // Uygulama kimliği koyu/neon temaya göre tasarlandı; açık tema desteklenmiyor.
        theme: AppTheme.darkTheme,
        navigatorObservers: [ToastDismissObserver()],
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );
  }
}

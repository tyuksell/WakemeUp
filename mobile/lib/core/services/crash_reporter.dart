import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sentry entegrasyonu — `.env` dosyasında `SENTRY_DSN` tanımlıysa etkinleşir;
/// tanımlı değilse tüm çağrılar sessizce hiçbir şey yapmaz (uygulama normal
/// çalışmaya devam eder). Arka plan servis, ana UI'dan ayrı bir Dart izolatı
/// olduğundan (bkz. background_service.dart) kendi başlatmasını
/// [initBackgroundIsolate] ile ayrıca yapması gerekir — izolatlar arasında
/// statik durum paylaşılmaz.
class CrashReporter {
  CrashReporter._();

  static String get _dsn => dotenv.env['SENTRY_DSN']?.trim() ?? '';

  /// Bu izolatta Sentry etkin mi? `.env`'de DSN yoksa false döner.
  static bool get isEnabled => _dsn.isNotEmpty;

  /// Ana (UI) izolatında çağrılır. `.env` zaten yüklenmiş olmalı. DSN yoksa
  /// [appRunner] doğrudan, Sentry sarmalaması olmadan çalıştırılır.
  static Future<void> initMainIsolate(Future<void> Function() appRunner) async {
    if (!isEnabled) {
      await appRunner();
      return;
    }
    await SentryFlutter.init((options) {
      options.dsn = _dsn;
      options.tracesSampleRate = 0.0;
    }, appRunner: appRunner);
  }

  /// Arka plan servis izolatında çağrılır — bu isolate `flutter run`/UI'dan
  /// bağımsız olarak yeniden başlatılabildiğinden Sentry'yi kendi başına
  /// ayrıca başlatması gerekir.
  static Future<void> initBackgroundIsolate() async {
    if (!isEnabled) return;
    try {
      await Sentry.init((options) => options.dsn = _dsn);
    } catch (_) {
      // Sentry başlatılamazsa bile takip işlevselliği asla etkilenmemeli.
    }
  }

  /// Beklenmeyen bir hatayı Sentry'ye bildirir (DSN yoksa no-op).
  static void capture(Object error, StackTrace stackTrace, {String? hint}) {
    if (!isEnabled) return;
    if (hint != null) {
      Sentry.addBreadcrumb(Breadcrumb(message: hint));
    }
    Sentry.captureException(error, stackTrace: stackTrace);
  }
}

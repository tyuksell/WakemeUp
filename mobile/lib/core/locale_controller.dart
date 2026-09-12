import 'package:flutter/material.dart';
import 'services/hive_service.dart';

/// Uygulama genelinde aktif dili tutan paylaşılan durum. `main.dart`'taki
/// `MaterialApp`, `locale` parametresini bir `ValueListenableBuilder` ile
/// buna bağlar; dili değiştirmek isteyen herhangi bir yer (ör. Ayarlar
/// ekranı) [setAppLocale] çağırması yeterlidir — hem anlık UI güncellenir
/// hem de tercih Hive'a kalıcı olarak yazılır.
final ValueNotifier<Locale> appLocale = ValueNotifier<Locale>(
  Locale(HiveService.defaultLanguageCode),
);

Future<void> setAppLocale(String languageCode) async {
  appLocale.value = Locale(languageCode);
  await HiveService.setLanguageCode(languageCode);
}

// WakeMeUp açılış ekranı için temel bir smoke test: uygulama çöküyor mu ve
// giriş ekranındaki temel öğeler görünüyor mu kontrol eder.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geofence_alarm/features/presentation/pages/home_page.dart';
import 'package:geofence_alarm/l10n/app_localizations.dart';

void main() {
  testWidgets('HomePage başlık ve rota belirleme butonunu gösterir', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('tr'),
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomePage(),
    ));

    expect(find.text('WakeMeUp'), findsOneWidget);
    expect(find.text('Rota Belirle'), findsOneWidget);
  });
}

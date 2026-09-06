// WakeMeUp açılış ekranı için temel bir smoke test: uygulama çöküyor mu ve
// giriş ekranındaki temel öğeler görünüyor mu kontrol eder.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geofence_alarm/features/presentation/pages/home_page.dart';

void main() {
  testWidgets('HomePage başlık ve rota belirleme butonunu gösterir', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('WakeMeUp'), findsOneWidget);
    expect(find.text('Rota Belirle'), findsOneWidget);
  });
}

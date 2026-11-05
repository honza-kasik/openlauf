import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navia_control/controller.dart';
import 'package:navia_control/main.dart';
import 'package:noventa_protocol/noventa_protocol.dart';
import 'support/fake_mobile_ble.dart';

void main() {
  testWidgets('Stop stays enabled while an ordinary operation is busy', (
    tester,
  ) async {
    final ble = FakeMobileBle()..stateCode = 4;
    final model = AppModel(ble: ble)
      ..client = (NaviaClient(ble)..state = DeviceState(4, 0, 0, 0, 0))
      ..ready = true;
    addTearDown(model.dispose);
    final gate = Completer<void>();
    final operation = model.run(() => gate.future);
    await tester.pumpWidget(NaviaApp(model: model));
    final stop = find.ancestor(
      of: find.text('Stop'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(stop).onPressed, isNotNull);
    await tester.tap(stop);
    await tester.pump();
    expect(ble.writes.where((f) => f.command == 0x26).single.payload, [5, 0]);
    gate.complete();
    await operation;
    // Stream cleanup needs the real async zone rather than the widget test clock.
    await tester.runAsync(model.pause);
  });
  testWidgets('slider previews do not write until drag ends', (tester) async {
    final writes = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommitSlider(value: 4, min: 1, max: 7, onCommit: writes.add),
        ),
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(6);
    expect(writes, isEmpty);
    slider.onChangeEnd!(6);
    expect(writes, [6]);
  });
  testWidgets('permission denial clears busy flag and reports error', (
    tester,
  ) async {
    final ble = FakeMobileBle()..allowed = false;
    final model = AppModel(ble: ble);
    await model.scan();
    expect(model.busy, isFalse);
    expect(model.scanning, isFalse);
    expect(model.error, contains('Povol'));
    model.dispose();
  });
  testWidgets('stale discovery is rejected without a native connection', (
    tester,
  ) async {
    final ble = FakeMobileBle();
    final model = AppModel(ble: ble);
    model.devices['synthetic'] = {
      'seenAt': DateTime.now().subtract(const Duration(seconds: 10)),
    };
    await model.connect('synthetic');
    expect(ble.connectedIds, isEmpty);
    expect(model.ready, isFalse);
    expect(model.error, contains('znovu'));
    model.dispose();
  });
  testWidgets('offline navigation and disabled descaling', (tester) async {
    final model = AppModel(ble: FakeMobileBle());
    await tester.pumpWidget(NaviaApp(model: model));
    expect(find.text('OpenLauf'), findsOneWidget);
    expect(find.text('Vyhledat WC'), findsOneWidget);
    await tester.tap(find.text('Údržba'));
    await tester.pumpAndSettle();
    expect(find.text('Odvápnění'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Připravit odvápnění'),
    );
    expect(start.onPressed, isNull);
    expect(find.text('Zastavit odvápnění'), findsNothing);
    await tester.tap(find.text('Diagnostika'));
    await tester.pumpAndSettle();
    expect(find.text('Firmware: —'), findsOneWidget);
  });
  testWidgets('language changes all navigation labels', (tester) async {
    final model = AppModel(ble: FakeMobileBle())..english = true;
    await tester.pumpWidget(NaviaApp(model: model));
    expect(find.text('Find toilet'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Care'), findsOneWidget);
  });
}

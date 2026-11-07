import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:navia_control/controller.dart';
import 'package:noventa_protocol/noventa_protocol.dart';

import 'support/fake_mobile_ble.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeMobileBle ble;
  late AppModel model;
  setUp(() {
    ble = FakeMobileBle();
    model = AppModel(ble: ble)..selectedId = 'synthetic';
  });
  tearDown(() async {
    await model.pause();
    model.dispose();
    await tick();
  });

  test('resume waits for an old operation and then starts discovery', () async {
    final gate = Completer<void>();
    final operation = model.run(() => gate.future);
    await model.pause();
    final resumed = model.resume();
    await tick();
    expect(ble.scans, 0);
    gate.complete();
    await Future.wait([operation, resumed]);
    expect(ble.scans, 1);
    expect(ble.discoveries.hasListener, isTrue);
  });

  test('old pause completes before the new discovery subscription', () async {
    ble.disconnectGate = Completer<void>();
    final paused = model.pause();
    final resumed = model.resume();
    await tick();
    expect(ble.scans, 0);
    ble.disconnectGate!.complete();
    await Future.wait([paused, resumed]);
    await tick();
    expect(ble.scans, 1);
    expect(ble.discoveries.hasListener, isTrue);
    expect(model.scanning, isTrue);
  });

  test('another pause cancels a deferred resume', () async {
    final gate = Completer<void>();
    final operation = model.run(() => gate.future);
    await model.pause();
    final resumed = model.resume();
    await model.pause();
    gate.complete();
    await Future.wait([operation, resumed]);
    expect(ble.scans, 0);
    expect(model.scanning, isFalse);
    await model.resume();
    expect(ble.scans, 1);
  });

  test('permission completion after pause cannot start a stale scan', () async {
    ble.permissionGate = Completer<bool>();
    final oldScan = model.scan();
    await tick();
    await model.pause();
    final resumed = model.resume();
    ble.permissionGate!.complete(true);
    await Future.wait([oldScan, resumed]);
    expect(ble.scans, 1);
    expect(model.scanning, isTrue);
  });

  test(
    'Stop is accepted during another operation and coalesces taps',
    () async {
      final session = NaviaClient(ble)..state = DeviceState(4, 0, 0, 0, 0);
      model.client = session;
      model.ready = true;
      final gate = Completer<void>();
      final operation = model.run(() => gate.future);
      expect(model.busy, isTrue);
      expect(model.canStop, isTrue);
      final stop = model.stopShower();
      final duplicate = model.stopShower();
      await Future.wait([stop, duplicate]);
      expect(model.busy, isTrue);
      expect(ble.writes.where((f) => f.command == 0x26), hasLength(1));
      expect(session.state!.code, 2);
      gate.complete();
      await operation;
    },
  );

  test('Stop is unavailable during descaling', () async {
    model.client = NaviaClient(ble)..state = DeviceState(16, 0, 0, 0, 0);
    model.ready = true;
    expect(model.canStop, isFalse);
    await model.stopShower();
    expect(ble.writes, isEmpty);
  });

  for (final kind in DeviceReset.values) {
    test(
      '${kind.name} reset clears the session and requires a fresh scan',
      () async {
        final session = NaviaClient(ble);
        await session.initialize();
        model.client = session;
        model.ready = true;
        ble.writes.clear();
        await model.resetDevice(kind);
        expect(model.ready, isFalse);
        expect(model.client, isNull);
        expect(model.selectedId, isNull);
        expect(model.busy, isFalse);
        expect(model.resetting, isFalse);
        expect(model.error, contains('potvrdilo'));
        expect(ble.disconnects, greaterThan(0));
        final resets = ble.writes.where(
          (frame) => frame.command == 0x17 || frame.command == 0x26,
        );
        expect(resets, hasLength(1));
        expect(
          resets.single.payload,
          kind == DeviceReset.factory ? [0x52, 0] : isEmpty,
        );
        await model.pause();
        await model.resume();
        expect(ble.scans, 0);
      },
    );
  }

  test('reset disconnection is shown as unconfirmed', () async {
    final session = NaviaClient(ble);
    await session.initialize();
    model.client = session;
    model.ready = true;
    ble.dropOnReset = true;
    await model.resetDevice(DeviceReset.factory);
    expect(model.ready, isFalse);
    expect(model.client, isNull);
    expect(model.error, contains('výsledek není známý'));
    expect(model.error, isNot(contains('Zařízení potvrdilo')));
  });

  test(
    'reset is unavailable during active operations and unknown states',
    () async {
      final session = NaviaClient(ble);
      await session.initialize();
      model.client = session;
      model.ready = true;
      ble.writes.clear();
      for (final code in [3, 4, 12, 13, 15, 16, 17, 28]) {
        session.state = DeviceState(code, 0, 0, 0, 0);
        expect(model.canReset, isFalse);
        await model.resetDevice(DeviceReset.factory);
      }
      expect(ble.writes, isEmpty);
    },
  );

  test(
    'reset blocks Stop and duplicate taps; pause never schedules replay',
    () async {
      final session = NaviaClient(ble);
      await session.initialize();
      model.client = session;
      model.ready = true;
      ble.writes.clear();
      ble.resetGate = Completer<void>();
      final reset = model.resetDevice(DeviceReset.factory);
      await tick();
      expect(model.resetting, isTrue);
      expect(model.canStop, isFalse);
      expect(model.canReset, isFalse);
      await model.resetDevice(DeviceReset.factory);
      await model.pause();
      await model.resume();
      ble.resetGate!.complete();
      await reset;
      await tick();
      expect(ble.scans, 0);
      expect(ble.writes.where((frame) => frame.command == 0x26), hasLength(1));
      expect(model.ready, isFalse);
    },
  );
}

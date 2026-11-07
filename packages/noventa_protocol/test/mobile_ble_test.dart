import 'dart:async';
import 'package:noventa_protocol/mobile_ble.dart';
import 'package:noventa_protocol/noventa_protocol.dart';
import 'package:test/test.dart';

class FakeBackend implements MobileBleBackend {
  final devices = StreamController<NearbyDevice>.broadcast(sync: true);
  final links = StreamController<LinkState>.broadcast(sync: true);
  final values = StreamController<List<int>>.broadcast(sync: true);
  final writes = <(String, List<int>)>[];
  bool allowed = true, failConnect = false;
  Completer<Stream<List<int>>>? delayedSubscription;
  String? connectedId;
  @override
  Future<bool> requestPermissions() async => allowed;
  @override
  Stream<NearbyDevice> scan() => devices.stream;
  @override
  Stream<LinkState> connect(String id) {
    if (failConnect) throw StateError('backend failed synchronously');
    connectedId = id;
    return links.stream;
  }

  @override
  Future<Stream<List<int>>> subscribe(String id) async =>
      await (delayedSubscription?.future ?? Future.value(values.stream));
  @override
  Future<void> write(String id, List<int> bytes) async {
    writes.add((id, bytes));
  }

  @override
  Future<void> dispose() async {
    await devices.close();
    await links.close();
    await values.close();
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

class SlowCancelBackend extends FakeBackend {
  final StreamController<LinkState> connection;
  SlowCancelBackend(Completer<void> gate)
    : connection = StreamController<LinkState>(onCancel: () => gate.future);
  @override
  Stream<LinkState> connect(String id) => connection.stream;
  @override
  Future<void> dispose() async {
    await connection.close();
    await super.dispose();
  }
}

void main() {
  late FakeBackend backend;
  late PluginBleTransport transport;
  late StreamSubscription<List<int>> listener;
  late List<List<int>> received;
  late List<Object> errors;
  setUp(() {
    backend = FakeBackend();
    transport = PluginBleTransport(
      backend,
      connectionTimeout: const Duration(milliseconds: 40),
    );
    received = [];
    errors = [];
    listener = transport.notifications.listen(
      received.add,
      onError: errors.add,
    );
  });
  tearDown(() async {
    await listener.cancel();
    await transport.dispose();
  });
  Future<void> connect([
    String id = '550e8400-e29b-41d4-a716-446655440000',
  ]) async {
    final pending = transport.connect(id);
    await tick();
    backend.links.add(LinkState.connected);
    await pending;
  }

  test('permission denial is forwarded', () async {
    backend.allowed = false;
    expect(await transport.requestPermissions(), isFalse);
  });
  test('scan preserves opaque identifiers, signal and availability', () async {
    final result = transport.scan().first;
    backend.devices.add(
      const NearbyDevice(
        id: 'ios-uuid',
        name: 'Navia',
        rssi: -48,
        connectable: false,
      ),
    );
    final found = await result;
    expect(found.id, 'ios-uuid');
    expect(found.rssi, -48);
    expect(found.connectable, isFalse);
  });
  test(
    'UUID connection, notifications and write use the same device',
    () async {
      await connect();
      backend.values.add([0, 2, 0x82, 4, 1, 0x22, 0x57, 0]);
      await transport.write([1, 2, 3]);
      expect(received.single, [0, 2, 0x82, 4, 1, 0x22, 0x57, 0]);
      expect(backend.writes.single.$1, backend.connectedId);
      expect(backend.writes.single.$2, [1, 2, 3]);
    },
  );
  test('no write before notification subscription is installed', () async {
    backend.delayedSubscription = Completer();
    final pending = transport.connect('uuid');
    await tick();
    backend.links.add(LinkState.connected);
    await tick();
    await expectLater(transport.write([2]), throwsA(isA<ProtocolException>()));
    backend.delayedSubscription!.complete(backend.values.stream);
    await pending;
    await transport.write([2]);
    expect(backend.writes, hasLength(1));
  });
  test('duplicate connected event does not duplicate notifications', () async {
    await connect();
    backend.links.add(LinkState.connected);
    backend.values.add([1]);
    expect(received, [
      [1],
    ]);
  });
  test(
    'disconnect cancels both streams and rejects subsequent writes',
    () async {
      await connect();
      await transport.disconnect();
      expect(backend.links.hasListener, isFalse);
      expect(backend.values.hasListener, isFalse);
      await expectLater(
        transport.write([1]),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test('remote disconnect is reported and cleaned up', () async {
    await connect();
    backend.links.add(LinkState.disconnected);
    await tick();
    expect(errors.single, isA<ProtocolException>());
    expect(backend.links.hasListener, isFalse);
    await expectLater(transport.write([1]), throwsA(isA<ProtocolException>()));
  });
  test('notification error terminates the connection', () async {
    await connect();
    backend.values.addError(StateError('notify failed'));
    await tick();
    expect(errors.single, isA<StateError>());
    expect(backend.links.hasListener, isFalse);
  });
  test('timeout cleans up without sending or replaying data', () async {
    await expectLater(
      transport.connect('uuid'),
      throwsA(isA<TimeoutException>()),
    );
    expect(backend.links.hasListener, isFalse);
    expect(backend.writes, isEmpty);
  });
  test(
    'subscription completing after timeout cannot revive connection',
    () async {
      backend.delayedSubscription = Completer();
      final pending = transport.connect('uuid');
      final assertion = expectLater(pending, throwsA(isA<TimeoutException>()));
      await tick();
      backend.links.add(LinkState.connected);
      await assertion;
      backend.delayedSubscription!.complete(backend.values.stream);
      await tick();
      expect(backend.values.hasListener, isFalse);
      await expectLater(
        transport.write([1]),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test('cancel pending connection completes instead of hanging', () async {
    final pending = transport.connect('uuid');
    final assertion = expectLater(pending, throwsA(isA<ProtocolException>()));
    await tick();
    await transport.disconnect();
    await assertion;
  });
  test(
    'synchronous backend failure is propagated without an orphan timeout',
    () async {
      backend.failConnect = true;
      await expectLater(transport.connect('uuid'), throwsA(isA<StateError>()));
    },
  );
  test('transport can reconnect after a disconnect', () async {
    await connect('android-mac');
    await transport.disconnect();
    await connect('ios-uuid');
    await transport.write([5]);
    expect(backend.writes.single.$1, 'ios-uuid');
  });
  test('overlapping disconnects wait for native cancellation', () async {
    final gate = Completer<void>();
    final slow = SlowCancelBackend(gate);
    final local = PluginBleTransport(slow);
    final connecting = local.connect('uuid');
    await tick();
    slow.connection.add(LinkState.connected);
    await connecting;
    final first = local.disconnect();
    var secondFinished = false;
    final second = local.disconnect().then((_) => secondFinished = true);
    await tick();
    expect(secondFinished, isFalse);
    gate.complete();
    await Future.wait([first, second]);
    expect(secondFinished, isTrue);
    await local.dispose();
  });
}

import 'dart:async';
import 'dart:convert';
import 'package:noventa_protocol/noventa_protocol.dart';
import 'package:test/test.dart';

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

class FakeTransport implements BleTransport {
  final incoming = StreamController<List<int>>.broadcast(sync: true);
  final writes = <Frame>[];
  final decoder = FrameDecoder();
  bool autoReply = true;
  int state = 2, disconnects = 0, timer = 3600;
  int? reject;
  Object? writeError;
  Completer<void>? writeGate;
  final profile = {for (var k = 0; k <= 10; k++) k: 4};
  final settings = {0x10: 2, 0x11: 3, 0x12: 0, 0x20: 3, 0x21: 0, 0x22: 0};
  @override
  Stream<List<int>> get notifications => incoming.stream;
  void receive(Frame frame) => incoming.add(frame.encode());
  @override
  Future<void> write(List<int> bytes) async {
    for (final f in decoder.add(bytes)) {
      writes.add(f);
      if (writeGate != null) await writeGate!.future;
      if (writeError != null) throw writeError!;
      if (f.command >= 128 || !autoReply) continue;
      if (reject == f.command) {
        receive(Frame(f.command | 128, [4]));
        continue;
      }
      List<int> payload;
      switch (f.command) {
        case 2:
          payload = [1];
        case 0x20:
          payload = [
            0,
            13,
            115,
            2,
            2,
            0,
            0,
            ...latin1.encode('H8206014000001\u0000SYNTHETIC\u0000'),
          ];
        case 0x21:
          payload = [state, 0, 0, 0, 0];
        case 0x23:
          final values = f.payload[0] == 255 ? settings : profile;
          payload = [
            f.payload[0],
            ...f.payload.skip(1).map((key) => values[key]!),
          ];
        case 0x25:
          (f.payload[0] == 255 ? settings : profile)[f.payload[1]] =
              f.payload[2];
          payload = [];
        case 0x2c:
          payload = [
            (timer >> 24) & 255,
            (timer >> 16) & 255,
            (timer >> 8) & 255,
            timer & 255,
          ];
        case 0x26:
          if (f.payload[0] == 15) state = state == 2 ? 12 : 16;
          if (f.payload[0] == 5) state = 2;
          payload = [];
        default:
          payload = [];
      }
      receive(Frame(f.command | 128, [0, ...payload]));
    }
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

void main() {
  group('Captured wire frames', () {
    final samples = {
      '0C02A76EA167899B93C0D03300': Frame(2, hex('A76EA167899B93C0')),
      '0521FF6CCA00': Frame(0x21, [255]),
      '03260203AD1900': Frame(0x26, [2, 0]),
      '03260503A55400': Frame(0x26, [5, 0]),
      '02A203B06300': Frame(0xa2, [0]),
      '02A403603700': Frame(0xa4, [0]),
    };
    for (final entry in samples.entries) {
      test(entry.key, () {
        expect(entry.value.encode(), hex(entry.key));
        final decoded = Frame.decode(
          hex(entry.key).sublist(0, hex(entry.key).length - 1),
        );
        expect(decoded.command, entry.value.command);
        expect(decoded.payload, entry.value.payload);
      });
    }
    test(
      'CRC independent check vector',
      () => expect(crc16(ascii.encode('123456789')), 0xde76),
    );
    test('COBS zero and 254-byte boundaries', () {
      for (final bytes in [
        <int>[],
        [0, 0, 0],
        List.filled(254, 1),
        List.filled(255, 1),
        List.generate(1024, (i) => i & 255),
      ]) {
        expect(cobsDecode(cobsEncode(bytes)), bytes);
      }
    });
    test('split and concatenated notifications, leading delimiter', () {
      final d = FrameDecoder();
      expect(d.add(hex('00028204')), isEmpty);
      final frames = d.add(hex('012257000003220401010103D95F00'));
      expect(frames.map((f) => f.command), [0x82, 0x22]);
      expect(frames[0].payload, [0, 1]);
      expect(frames[1].payload, [4, 0, 0, 0, 0]);
    });
    test('corrupt/oversized frames discarded; stream resynchronizes', () {
      final d = FrameDecoder();
      expect(d.add([4, 1, 0]), isEmpty);
      expect(
        d
            .add([
              ...List.filled(5000, 1),
              0,
              ...Frame(0xa6, [0]).encode(),
            ])
            .single
            .command,
        0xa6,
      );
      expect(d.rejected, 2);
    });
    test('product information fields and inverted descaling flag', () {
      final p = [
        0,
        13,
        115,
        2,
        2,
        0x10,
        0,
        ...ascii.encode('ARTICLE\u0000SERIAL\u0000'),
      ];
      final info = DeviceInfo.parse(p);
      expect(info.firmware, '0.13.115');
      expect(info.article, 'ARTICLE');
      expect(info.serial, 'SERIAL');
      expect(info.isNavia, isTrue);
      expect(info.descalingSupported, isFalse);
    });
  });
  group('Session', () {
    late FakeTransport transport;
    late NaviaClient client;
    setUp(() {
      transport = FakeTransport();
      client = NaviaClient(
        transport,
        timeout: const Duration(milliseconds: 30),
      );
    });
    tearDown(() async {
      await client.dispose();
      await transport.incoming.close();
    });
    test('initialize authenticates and reads state/config/timer', () async {
      await client.initialize();
      expect(client.info!.isNavia, isTrue);
      expect(client.state!.code, 2);
      expect(client.profile[10], 4);
      expect(client.settings[0x10], 2);
      expect(client.remainingSeconds, 3600);
    });
    test('event ACK bypasses outstanding request and updates state', () async {
      transport.autoReply = false;
      final request = client.readState();
      await Future<void>.delayed(Duration.zero);
      transport.receive(Frame(0x22, [4, 0, 0, 0, 0]));
      await Future<void>.delayed(Duration.zero);
      expect(transport.writes.last.command, 0xa2);
      transport.receive(Frame(0xa1, [0, 4, 0, 0, 0, 0]));
      await request;
      expect(client.state!.code, 4);
    });
    test('parameter and timer notifications update state', () async {
      transport.receive(Frame(0x24, [0, 0, 7]));
      transport.receive(Frame(0x2d, [2, 0, 0, 0, 120]));
      await Future<void>.delayed(Duration.zero);
      expect(client.profile[0], 7);
      expect(client.remainingSeconds, 120);
      expect(transport.writes.map((f) => f.command), [0xa4, 0xad]);
    });
    test('concurrent requests are serialized', () async {
      await Future.wait([client.readState(), client.readTimer()]);
      expect(transport.writes.map((f) => f.command), [0x21, 0x2c]);
    });
    test('rejected action does not poison queue', () async {
      transport.reject = 0x26;
      await expectLater(client.action(2), throwsA(isA<ProtocolException>()));
      await client.readState();
      expect(client.state!.code, 2);
    });
    test(
      'failed write closes the session and cannot reuse a late ACK',
      () async {
        transport.writeError = StateError('native write completion failed');
        transport.writeGate = Completer<void>();
        final first = expectLater(client.action(2), throwsA(isA<StateError>()));
        await Future<void>.delayed(Duration.zero);
        final queued = expectLater(
          client.action(5),
          throwsA(isA<ProtocolException>()),
        );
        transport.writeGate!.complete();
        await Future.wait([first, queued]);
        expect(client.connected, isFalse);
        expect(transport.disconnects, greaterThan(0));
        transport.writeError = null;
        transport.receive(Frame(0xa6, [0]));
        await expectLater(client.action(5), throwsA(isA<ProtocolException>()));
        expect(transport.writes, hasLength(1));
      },
    );
    test('reply timeout is bounded even if write completion hangs', () async {
      transport.autoReply = false;
      transport.writeGate = Completer<void>();
      await expectLater(client.readState(), throwsA(isA<TimeoutException>()));
      expect(client.connected, isFalse);
      transport.writeGate!.complete();
    });
    test(
      'Stop waits for the active reply then precedes queued reads',
      () async {
        transport.autoReply = false;
        final active = client.readTimer();
        await Future<void>.delayed(Duration.zero);
        final ordinary = client.readConfiguration(0, [0]);
        final stop = client.stopShower();
        await Future<void>.delayed(Duration.zero);
        expect(transport.writes.map((f) => f.command), [0x2c]);
        transport.autoReply = true;
        transport.receive(Frame(0xac, [0, 0, 0, 0, 120]));
        await Future.wait([active, ordinary, stop]);
        expect(transport.writes[1].command, 0x26);
        expect(transport.writes[1].payload, [5, 0]);
        expect(client.state!.code, 2);
      },
    );
    test(
      'queued Stop is rejected if descaling starts before dispatch',
      () async {
        transport.autoReply = false;
        final active = client.readTimer();
        await Future<void>.delayed(Duration.zero);
        final stop = expectLater(
          client.stopShower(),
          throwsA(isA<ProtocolException>()),
        );
        transport.receive(Frame(0x22, [16, 0, 0, 0, 0]));
        transport.autoReply = true;
        transport.receive(Frame(0xac, [0, 0, 0, 0, 120]));
        await Future.wait([active, stop]);
        expect(transport.writes.where((f) => f.command == 0x26), isEmpty);
      },
    );
    test(
      'Stop cancels an unsent START instead of starting after stopping',
      () async {
        final start = expectLater(
          client.action(2),
          throwsA(isA<ProtocolException>()),
        );
        await client.stopShower();
        await start;
        final actions = transport.writes
            .where((f) => f.command == 0x26)
            .toList();
        expect(actions.map((f) => f.payload), [
          [5, 0],
        ]);
      },
    );
    test('timeout disconnects and never replays action', () async {
      transport.autoReply = false;
      await expectLater(client.action(2), throwsA(isA<TimeoutException>()));
      expect(client.connected, isFalse);
      expect(transport.writes.length, 1);
      transport.receive(Frame(0xa6, [0]));
      await expectLater(client.readState(), throwsA(isA<ProtocolException>()));
    });
    test('transport disconnect fails pending request', () async {
      transport.autoReply = false;
      final pending = client.readState();
      final assertion = expectLater(pending, throwsA(isA<ProtocolException>()));
      await Future<void>.delayed(Duration.zero);
      transport.incoming.addError(ProtocolException('lost'));
      await assertion;
      expect(client.connected, isFalse);
    });
    test(
      'settings are written with profile and verified by readback',
      () async {
        await client.setParameter(255, 0x10, 0);
        expect(transport.writes.first.payload, [255, 0x10, 0]);
        expect(client.settings[0x10], 0);
      },
    );
    test('diagnostics omit identifiers and packet payloads', () async {
      await client.initialize();
      final log = client.diagnostics.join();
      expect(log, isNot(contains('SYNTHETIC')));
      expect(log, isNot(contains('H820601')));
      expect(log, isNot(contains('A76E')));
    });
    test('two explicit steps; active cycle blocks normal actions', () async {
      await client.initialize();
      await client.prepareDescaling();
      expect(client.state!.phase, DescalingPhase.preparation);
      await client.startDescaling();
      expect(client.state!.phase, DescalingPhase.active);
      expect(transport.writes.where((f) => f.command == 0x26).length, 2);
      await expectLater(client.action(5), throwsA(isA<ProtocolException>()));
      await expectLater(
        client.setParameter(0, 0, 5),
        throwsA(isA<ProtocolException>()),
      );
    });
    test('automatic start is not started again', () async {
      await client.initialize();
      await client.prepareDescaling();
      transport.state = 16;
      await client.startDescaling();
      expect(transport.writes.where((f) => f.command == 0x26).length, 1);
    });
    test('resume active cycle reads state without starting anything', () async {
      transport.state = 16;
      await client.initialize();
      expect(client.state!.phase, DescalingPhase.active);
      expect(transport.writes.where((f) => f.command == 0x26), isEmpty);
    });
    test('zero timer alone never means complete', () async {
      transport.state = 16;
      transport.timer = 0;
      await client.initialize();
      expect(client.state!.phase, DescalingPhase.active);
    });
    test(
      'unexpected state refuses descaling preparation/continuation',
      () async {
        await client.initialize();
        transport.state = 4;
        await expectLater(
          client.prepareDescaling(),
          throwsA(isA<ProtocolException>()),
        );
        await expectLater(
          client.startDescaling(),
          throwsA(isA<ProtocolException>()),
        );
        expect(transport.writes.where((f) => f.command == 0x26), isEmpty);
      },
    );
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:noventa_protocol/mobile_ble.dart';
import 'package:noventa_protocol/noventa_protocol.dart';

class FakeMobileBle implements MobileBleTransport {
  bool allowed = true;
  int scans = 0, stateCode = 2, disconnects = 0;
  bool dropOnReset = false;
  Completer<void>? resetGate;
  Completer<void>? disconnectGate;
  Completer<bool>? permissionGate;
  final connectedIds = <String>[];
  final discoveries = StreamController<NearbyDevice>.broadcast(sync: true);
  final incoming = StreamController<List<int>>.broadcast(sync: true);
  final writes = <Frame>[];
  final decoder = FrameDecoder();
  final profile = {for (var key = 0; key <= 10; key++) key: 4};
  final settings = {0x10: 2, 0x11: 3, 0x12: 0, 0x20: 3, 0x21: 0, 0x22: 0};
  @override
  Future<bool> requestPermissions() async =>
      permissionGate == null ? allowed : await permissionGate!.future;
  @override
  Stream<NearbyDevice> scan() {
    scans++;
    return discoveries.stream;
  }

  @override
  Future<void> connect(String id) async {
    connectedIds.add(id);
  }

  @override
  Stream<List<int>> get notifications => incoming.stream;
  @override
  Future<void> write(List<int> bytes) async {
    for (final frame in decoder.add(bytes)) {
      writes.add(frame);
      if (frame.command >= 0x80) continue;
      final p = frame.payload;
      final resetting =
          frame.command == 0x17 || (frame.command == 0x26 && p.first == 0x52);
      if (resetting) {
        await resetGate?.future;
        if (dropOnReset) {
          incoming.addError(ProtocolException('Reset disconnected the device'));
          continue;
        }
      }
      final payload = switch (frame.command) {
        2 => [1],
        0x20 => [
          0,
          13,
          115,
          2,
          2,
          0,
          0,
          ...latin1.encode('ARTICLE\u0000SYNTHETIC\u0000'),
        ],
        0x21 => [stateCode, 0, 0, 0, 0],
        0x23 => [
          p[0],
          ...p.skip(1).map((key) => (p[0] == 255 ? settings : profile)[key]!),
        ],
        0x2c => [0, 0, 0, 0],
        _ => <int>[],
      };
      if (frame.command == 0x25) {
        (p[0] == 255 ? settings : profile)[p[1]] = p[2];
      }
      if (frame.command == 0x26 && p[0] == 5) stateCode = 2;
      incoming.add(Frame(frame.command | 0x80, [0, ...payload]).encode());
    }
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    await disconnectGate?.future;
  }

  @override
  Future<void> dispose() async {
    await discoveries.close();
    await incoming.close();
  }
}

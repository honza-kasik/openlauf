// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OpenLauf contributors

library;

import 'dart:async';
import 'dart:convert';

const serviceUuid = 'cedaad00-57a7-40bf-842c-b1c4a1c4624a';
const writeUuid = 'cedaad01-57a7-40bf-842c-b1c4a1c4624a';
const notifyUuid = 'cedaad02-57a7-40bf-842c-b1c4a1c4624a';

int crc16(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  return (~crc) & 0xffff;
}

List<int> cobsEncode(List<int> bytes) {
  final out = <int>[0];
  var index = 0;
  var code = 1;
  for (final b in bytes) {
    if (b == 0) {
      out[index] = code;
      index = out.length;
      out.add(0);
      code = 1;
    } else {
      out.add(b);
      code++;
      if (code == 255) {
        out[index] = code;
        index = out.length;
        out.add(0);
        code = 1;
      }
    }
  }
  out[index] = code;
  return out;
}

List<int> cobsDecode(List<int> bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final code = bytes[i++];
    if (code == 0 || i + code - 1 > bytes.length) {
      throw const FormatException('Invalid COBS frame');
    }
    out.addAll(bytes.sublist(i, i + code - 1));
    i += code - 1;
    if (code < 255 && i < bytes.length) out.add(0);
  }
  return out;
}

class Frame {
  final int command;
  final List<int> payload;
  Frame(this.command, [List<int> payload = const []])
    : payload = List.unmodifiable(payload);

  List<int> encode() {
    final body = [command, ...payload];
    if (body.any((b) => b < 0 || b > 255)) {
      throw const FormatException('Byte out of range');
    }
    final crc = crc16(body);
    return [
      ...cobsEncode([...body, crc & 255, crc >> 8]),
      0,
    ];
  }

  static Frame decode(List<int> encoded) {
    final raw = cobsDecode(encoded);
    if (raw.length < 3) throw const FormatException('Short frame');
    final body = raw.sublist(0, raw.length - 2);
    final crc = raw[raw.length - 2] | raw.last << 8;
    if (crc16(body) != crc) throw const FormatException('CRC mismatch');
    return Frame(body.first, body.sublist(1));
  }
}

/// Delimiters may appear at both ends of a notification. Notifications may
/// contain several frames or only one fragment of a frame.
class FrameDecoder {
  final _pending = <int>[];
  int rejected = 0;
  bool _discarding = false;
  List<Frame> add(List<int> chunk) {
    final frames = <Frame>[];
    for (final byte in chunk) {
      if (byte == 0) {
        if (_pending.isNotEmpty && !_discarding) {
          try {
            frames.add(Frame.decode(_pending));
          } on FormatException {
            rejected++;
          }
        }
        _pending.clear();
        _discarding = false;
      } else if (!_discarding) {
        _pending.add(byte);
        if (_pending.length > 4096) {
          rejected++;
          _pending.clear();
          _discarding = true;
        }
      }
    }
    return frames;
  }
}

abstract interface class BleTransport {
  Stream<List<int>> get notifications;
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
}

class ProtocolException implements Exception {
  final String message;
  ProtocolException(this.message);
  @override
  String toString() => message;
}

class _CommandRejected extends ProtocolException {
  _CommandRejected(int command, int status)
    : super('Device rejected command 0x${command.toRadixString(16)}: $status');
}

enum DeviceReset { bluetooth, factory }

enum ResetResult { acknowledged, unconfirmed }

class DeviceInfo {
  final String firmware, article, serial;
  final int model, flags;
  DeviceInfo(this.firmware, this.article, this.serial, this.model, this.flags);
  bool get isNavia => model == 2;
  bool get descalingSupported => (flags & 0x10) == 0;
  static DeviceInfo parse(List<int> p) {
    if (p.length < 9) throw const FormatException('Short product information');
    final strings = latin1.decode(p.sublist(7)).split('\u0000');
    return DeviceInfo(
      p.take(3).join('.'),
      strings.first,
      strings.length > 1 ? strings[1] : '',
      p[3],
      p[5],
    );
  }
}

enum DescalingPhase { unavailable, idle, preparation, ready, active, unknown }

class DeviceState {
  final int code, user, flags, controllerFlags, subState;
  DeviceState(
    this.code,
    this.user,
    this.flags,
    this.controllerFlags,
    this.subState,
  );
  static DeviceState parse(List<int> p) {
    if (p.length < 5) throw const FormatException('Short product state');
    return DeviceState(p[0], p[1], p[2], p[3], p[4]);
  }

  bool get descaling => const [12, 15, 16].contains(code);
  DescalingPhase get phase => switch (code) {
    12 => DescalingPhase.preparation,
    15 => DescalingPhase.ready,
    16 => DescalingPhase.active,
    1 || 2 => DescalingPhase.idle,
    _ => DescalingPhase.unknown,
  };
}

class _QueuedRequest {
  final int command;
  final List<int> payload;
  final void Function()? beforeSend;
  final bool resetOperation, closeAfterReply;
  final result = Completer<List<int>>();
  _QueuedRequest(
    this.command,
    List<int> payload,
    this.beforeSend, {
    this.resetOperation = false,
    this.closeAfterReply = false,
  }) : payload = List.unmodifiable(payload);
}

/// One outstanding request, because replies have no transaction identifier.
/// A timeout invalidates the connection so a late ACK cannot satisfy a new
/// request. Event acknowledgements bypass the request queue.
class NaviaClient {
  final BleTransport transport;
  final Duration timeout;
  final decoder = FrameDecoder();
  final _updates = StreamController<void>.broadcast();
  Stream<void> get updates => _updates.stream;
  final List<String> diagnostics = [];
  StreamSubscription<List<int>>? _subscription;
  Completer<Frame>? _response;
  int? _expected;
  final _requests = <_QueuedRequest>[];
  final _priorityRequests = <_QueuedRequest>[];
  bool _processing = false;
  Future<void> _writes = Future.value();
  bool _closed = false;
  bool _resetRequested = false;
  int _stateNotifications = 0;
  DeviceInfo? info;
  DeviceState? state;
  int? remainingSeconds;
  DateTime? lastUpdate;
  final Map<int, int> profile = {};
  final Map<int, int> settings = {};

  NaviaClient(this.transport, {this.timeout = const Duration(seconds: 3)}) {
    _subscription = transport.notifications.listen(
      _receive,
      onError: (Object e) => _fail(e),
      onDone: () => _fail(ProtocolException('BLE disconnected')),
    );
  }

  bool get connected => !_closed;
  bool get canReset =>
      connected && info?.isNavia == true && const [1, 2].contains(state?.code);
  void _log(String message) {
    diagnostics.add('${DateTime.now().toIso8601String()} $message');
    if (diagnostics.length > 200) diagnostics.removeAt(0);
  }

  void _changed() {
    lastUpdate = DateTime.now();
    if (!_updates.isClosed) _updates.add(null);
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _log('Session ended: ${error.runtimeType}');
    final response = _response;
    if (response != null && !response.isCompleted) {
      response.completeError(error);
    }
    _changed();
    unawaited(transport.disconnect());
  }

  Future<void> _send(Frame frame) {
    final next = _writes.then((_) async {
      if (_closed) throw ProtocolException('Disconnected');
      _log('TX command=${frame.command.toRadixString(16)}');
      final bytes = frame.encode();
      // Legacy peripherals accept ATT payloads of 20 bytes.
      for (var i = 0; i < bytes.length; i += 20) {
        if (_closed) throw ProtocolException('Disconnected');
        await transport.write(
          bytes.sublist(i, (i + 20).clamp(0, bytes.length)),
        );
      }
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  void _receive(List<int> bytes) {
    if (_closed) return;
    for (final frame in decoder.add(bytes)) {
      _log(
        'RX command=${frame.command.toRadixString(16)} length=${frame.payload.length}',
      );
      try {
        if (const [0x22, 0x24, 0x2d].contains(frame.command)) {
          unawaited(
            _send(
              Frame(frame.command | 0x80, [0]),
            ).catchError((Object e) => _fail(e)),
          );
          if (frame.command == 0x22) {
            state = DeviceState.parse(frame.payload);
            _stateNotifications++;
          }
          if (frame.command == 0x24 && frame.payload.length == 3) {
            final p = frame.payload;
            if (p[0] == 0) profile[p[1]] = p[2];
            if (p[0] == 255) settings[p[1]] = p[2];
          }
          if (frame.command == 0x2d &&
              frame.payload.length == 5 &&
              frame.payload[0] == 2) {
            remainingSeconds = _integer(frame.payload.sublist(1));
          }
          _changed();
        } else if (frame.command == _expected &&
            _response != null &&
            !_response!.isCompleted) {
          _response!.complete(frame);
        }
      } on FormatException {
        _log('Malformed notification');
      }
    }
  }

  Future<List<int>> request(int command, List<int> payload) =>
      _enqueue(command, payload);

  Future<List<int>> _enqueue(
    int command,
    List<int> payload, {
    bool priority = false,
    void Function()? beforeSend,
    bool resetOperation = false,
    bool closeAfterReply = false,
  }) {
    if (_resetRequested && !resetOperation) {
      return Future.error(ProtocolException('Device reset is pending'));
    }
    final request = _QueuedRequest(
      command,
      payload,
      beforeSend,
      resetOperation: resetOperation,
      closeAfterReply: closeAfterReply,
    );
    (priority ? _priorityRequests : _requests).add(request);
    if (!_processing) {
      _processing = true;
      scheduleMicrotask(_drainRequests);
    }
    return request.result.future;
  }

  Future<void> _drainRequests() async {
    while (_priorityRequests.isNotEmpty || _requests.isNotEmpty) {
      final queue = _priorityRequests.isNotEmpty
          ? _priorityRequests
          : _requests;
      final request = queue.removeAt(0);
      try {
        request.result.complete(await _exchange(request));
      } catch (e, stack) {
        request.result.completeError(e, stack);
      }
    }
    _processing = false;
  }

  Future<List<int>> _exchange(_QueuedRequest request) async {
    if (_closed) throw ProtocolException('Disconnected');
    if (_resetRequested && !request.resetOperation) {
      throw ProtocolException('Device reset is pending');
    }
    request.beforeSend?.call();
    final response = Completer<Frame>();
    _response = response;
    _expected = request.command | 0x80;
    final waiting = response.future.timeout(timeout);
    late Frame frame;
    try {
      // Both futures have error handlers immediately. Either a failed write or
      // an expired reply makes the outcome uncertain and invalidates the link.
      final replies = await Future.wait<Object>([
        _send(
          Frame(request.command, request.payload),
        ).then<Object>((_) => true),
        waiting,
      ], eagerError: true);
      frame = replies[1] as Frame;
    } catch (e) {
      _fail(e);
      rethrow;
    } finally {
      _response = null;
      _expected = null;
    }
    // A valid explicit rejection is a known outcome, so the link remains usable.
    if (frame.payload.isEmpty) {
      final error = ProtocolException('Empty command response');
      _fail(error);
      throw error;
    }
    if (frame.payload.first != 0) {
      throw _CommandRejected(request.command, frame.payload.first);
    }
    if (request.closeAfterReply) _fail(ProtocolException('Reset requested'));
    return frame.payload.sublist(1);
  }

  void _requireResettable() {
    if (!canReset) {
      throw ProtocolException('Reset requires an idle, connected Navia');
    }
  }

  /// Send one reset attempt and invalidate the session. A link loss or failed
  /// write cannot prove whether a reset was accepted, so it is never retried.
  Future<ResetResult> resetDevice(DeviceReset kind) async {
    if (_resetRequested) {
      throw ProtocolException('Device reset is already pending');
    }
    _requireResettable();
    _resetRequested = true;
    var attempted = false;
    try {
      await _readState(resetOperation: true);
      _requireResettable();
      await _enqueue(
        kind == DeviceReset.factory ? 0x26 : 0x17,
        kind == DeviceReset.factory ? [0x52, 0] : [],
        resetOperation: true,
        closeAfterReply: true,
        beforeSend: () {
          _requireResettable();
          attempted = true;
        },
      );
      return ResetResult.acknowledged;
    } on _CommandRejected {
      rethrow;
    } catch (_) {
      if (attempted) return ResetResult.unconfirmed;
      rethrow;
    } finally {
      if (attempted) {
        _fail(ProtocolException('Reset requested'));
      } else {
        _resetRequested = false;
      }
    }
  }

  Future<void> initialize() async {
    final auth = await request(2, [
      0xa7,
      0x6e,
      0xa1,
      0x67,
      0x89,
      0x9b,
      0x93,
      0xc0,
    ]);
    if (auth.isEmpty || auth.first != 1) {
      throw ProtocolException('Authentication failed');
    }
    info = DeviceInfo.parse(await request(0x20, [255]));
    if (!info!.isNavia) {
      throw ProtocolException('This release supports Navia only');
    }
    await refresh();
  }

  Future<void> refresh() async {
    await readState();
    await readConfiguration(0, List.generate(11, (i) => i));
    await readConfiguration(255, [0x10, 0x11, 0x12, 0x20, 0x21, 0x22]);
    await readTimer();
  }

  Future<void> readState() => _readState();

  Future<void> _readState({bool resetOperation = false}) async {
    final notifications = _stateNotifications;
    final response = DeviceState.parse(
      await _enqueue(0x21, [255], resetOperation: resetOperation),
    );
    // A state notification received while awaiting this reply is newer than
    // the requested snapshot and must not be overwritten by it.
    if (_stateNotifications == notifications) state = response;
    _changed();
  }

  Future<void> readConfiguration(int id, List<int> keys) async {
    final p = await request(0x23, [id, ...keys]);
    if (p.length != keys.length + 1 || p.first != id) {
      throw const FormatException('Unexpected configuration response');
    }
    final target = id == 255 ? settings : profile;
    for (var i = 0; i < keys.length; i++) {
      target[keys[i]] = p[i + 1];
    }
    _changed();
  }

  Future<void> readTimer() async {
    final p = await request(0x2c, [2, 255]);
    if (p.length != 4) throw const FormatException('Unexpected timer');
    remainingSeconds = _integer(p);
    _changed();
  }

  Future<void> action(int event) async {
    if (event == 5) return stopShower();
    _requireNormalOperation();
    await _enqueue(0x26, [event, 0], beforeSend: _requireNormalOperation);
    await readState();
  }

  void _requireNormalOperation() {
    if (state?.descaling == true) {
      throw ProtocolException('Descaling is in progress');
    }
  }

  /// Finish the in-flight exchange, then stop before any queued ordinary reads
  /// or writes. Never bypass response matching or replay this after reconnect.
  Future<void> stopShower() async {
    _requireNormalOperation();
    // Never execute an unsent START after the higher-priority STOP. The active
    // exchange still owns its reply and must finish before STOP is sent.
    final superseded = _requests.where((r) => r.command == 0x26).toList();
    for (final request in superseded) {
      _requests.remove(request);
      request.result.completeError(
        ProtocolException('Action superseded by Stop'),
      );
    }
    await _enqueue(
      0x26,
      [5, 0],
      priority: true,
      beforeSend: _requireNormalOperation,
    );
    await readState();
  }

  Future<void> setParameter(int id, int key, int value) async {
    if (state?.descaling == true) {
      throw ProtocolException('Descaling is in progress');
    }
    if (value < 0 || value > 255) throw ArgumentError.value(value);
    await _enqueue(0x25, [id, key, value], beforeSend: _requireNormalOperation);
    await readConfiguration(id, [key]);
    if ((id == 255 ? settings : profile)[key] != value) {
      throw ProtocolException('Setting was not confirmed by readback');
    }
  }

  Future<List<int>> readAlarms() => request(0x27, [255]);
  Future<void> prepareDescaling() async {
    await readState();
    if (info?.descalingSupported != true || state?.code != 2) {
      throw ProtocolException('Descaling requires a ready Navia');
    }
    await request(0x26, [15, 0]);
    await readState();
    await readTimer();
  }

  Future<void> startDescaling() async {
    await readState();
    if (state?.code == 16) return;
    if (state?.code != 12 && state?.code != 15) {
      throw ProtocolException('Device is not in descaling preparation');
    }
    await request(0x26, [15, 0]);
    await readState();
    await readTimer();
  }

  Future<void> dispose() async {
    _fail(ProtocolException('Session closed'));
    await _subscription?.cancel();
    await transport.disconnect();
    await _updates.close();
  }

  static int _integer(List<int> bytes) => bytes.fold(0, (v, b) => (v << 8) | b);
}

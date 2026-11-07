// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OpenLauf contributors

import 'dart:async';
import 'noventa_protocol.dart';

/// Platform-neutral discovery. IDs are opaque: Android MAC or CoreBluetooth UUID.
class NearbyDevice {
  final String id, name;
  final int rssi;
  final bool connectable;
  const NearbyDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.connectable,
  });
}

enum LinkState { connecting, connected, disconnected }

/// Implemented by a plugin facade, not by application-specific native code.
abstract interface class MobileBleBackend {
  Future<bool> requestPermissions();
  Stream<NearbyDevice> scan();
  Stream<LinkState> connect(String id);
  Future<Stream<List<int>>> subscribe(String id);
  Future<void> write(String id, List<int> bytes);
  Future<void> dispose();
}

abstract interface class MobileBleTransport implements BleTransport {
  Future<bool> requestPermissions();
  Stream<NearbyDevice> scan();
  Future<void> connect(String id);
  Future<void> dispose();
}

/// Shared connection lifecycle, independently testable without Flutter or radios.
class PluginBleTransport implements MobileBleTransport {
  final MobileBleBackend backend;
  final Duration connectionTimeout;
  final _notifications = StreamController<List<int>>.broadcast(sync: true);
  StreamSubscription<LinkState>? _connection;
  StreamSubscription<List<int>>? _values;
  Completer<void>? _pending;
  String? _id;
  int _generation = 0;
  bool _ready = false, _disposed = false;
  Future<void> _disconnecting = Future.value();
  PluginBleTransport(
    this.backend, {
    this.connectionTimeout = const Duration(seconds: 15),
  });

  @override
  Stream<List<int>> get notifications => _notifications.stream;
  @override
  Future<bool> requestPermissions() => backend.requestPermissions();
  @override
  Stream<NearbyDevice> scan() => backend.scan();

  void _lost(Object error) {
    _ready = false;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
    if (!_disposed) _notifications.addError(error);
    // Cleanup is owned here as well as by NaviaClient, so a dropped connection
    // during authentication cannot leave a live platform subscription behind.
    unawaited(disconnect());
  }

  @override
  Future<void> connect(String id) async {
    if (_disposed) throw StateError('Transport disposed');
    await disconnect();
    final generation = ++_generation;
    final pending = Completer<void>();
    _pending = pending;
    final waiting = pending.future.timeout(connectionTimeout);
    var preparing = false;
    Future<void> prepare() async {
      try {
        final stream = await backend.subscribe(id);
        if (generation != _generation) return;
        _values = stream.listen(
          (bytes) {
            if (generation == _generation) _notifications.add(bytes);
          },
          onError: (Object e) {
            if (generation == _generation) _lost(e);
          },
          onDone: () {
            if (generation == _generation)
              _lost(ProtocolException('Notifications ended'));
          },
        );
        _id = id;
        _ready = true;
        if (!pending.isCompleted) pending.complete();
      } catch (e) {
        if (generation == _generation) _lost(e);
      }
    }

    try {
      try {
        _connection = backend
            .connect(id)
            .listen(
              (state) {
                if (generation != _generation) return;
                if (state == LinkState.connected && !preparing) {
                  preparing = true;
                  unawaited(prepare());
                } else if (state == LinkState.disconnected) {
                  _lost(ProtocolException('BLE disconnected'));
                }
              },
              onError: (Object e) {
                if (generation == _generation) _lost(e);
              },
              onDone: () {
                if (generation == _generation)
                  _lost(ProtocolException('Connection ended'));
              },
            );
      } catch (e) {
        if (!pending.isCompleted) pending.completeError(e);
      }
      await waiting;
    } catch (_) {
      await disconnect();
      rethrow;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    final id = _id;
    if (!_ready || id == null) throw ProtocolException('Disconnected');
    await backend.write(id, bytes).timeout(const Duration(seconds: 3));
  }

  @override
  Future<void> disconnect() {
    _generation++;
    _ready = false;
    _id = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(ProtocolException('Connection cancelled'));
    }
    final values = _values;
    final connection = _connection;
    _values = null;
    _connection = null;
    final cleanup = _disconnecting.then((_) async {
      try {
        await values?.cancel();
      } finally {
        // Cancelling the plugin stream disconnects GATT. All callers wait for
        // earlier cancellations too, including when their own fields are empty.
        await connection?.cancel();
      }
    });
    _disconnecting = cleanup.then<void>((_) {}, onError: (Object _) {});
    return cleanup;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await backend.dispose();
    await _notifications.close();
  }
}

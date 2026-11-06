// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OpenLauf contributors

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:noventa_protocol/mobile_ble.dart';
import 'package:noventa_protocol/noventa_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reactive_ble_backend.dart';

class AppModel extends ChangeNotifier {
  final MobileBleTransport ble;
  AppModel({MobileBleTransport? ble})
    : ble = ble ?? PluginBleTransport(ReactiveBleBackend());
  NaviaClient? client;
  bool english = false, busy = false, scanning = false, ready = false;
  bool stopping = false, resetting = false;
  String stage = 'Offline', error = '';
  final Map<String, Map<dynamic, dynamic>> devices = {};
  String? selectedId, _resumeId;
  SharedPreferences? _preferences;
  StreamSubscription<void>? _updates;
  StreamSubscription<NearbyDevice>? _discoveries;
  Timer? _scanTimer, _poll;
  bool _disposed = false, _foreground = true, _resumePending = false;
  int _generation = 0, _lifecycle = 0;
  Future<void> _cleanup = Future.value();
  Future<void>? _operation, _stopOperation, _resumeWork;

  String t(String cs, String en) => english ? en : cs;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) =>
      !_disposed && _foreground && generation == _generation;

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
    english = _preferences?.getBool('english') ?? false;
    selectedId = _preferences?.getString('selectedDevice');
    changed();
  }

  Future<void> language(bool value) async {
    english = value;
    changed();
    await _preferences?.setBool('english', value);
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy || stopping || _disposed || !_foreground) return;
    final lifecycle = _lifecycle;
    final operation = Completer<void>();
    _operation = operation.future;
    busy = true;
    error = '';
    changed();
    try {
      await action();
    } catch (e) {
      if (!_disposed && _foreground && lifecycle == _lifecycle) {
        error = e.toString();
      }
    } finally {
      busy = false;
      _operation = null;
      operation.complete();
      changed();
      _tryResumeDevice();
    }
  }

  bool get canStop =>
      !_disposed &&
      _foreground &&
      ready &&
      !stopping &&
      !resetting &&
      client?.connected == true &&
      client?.state?.descaling != true;

  bool get canReset =>
      !_disposed &&
      _foreground &&
      ready &&
      !busy &&
      !stopping &&
      !resetting &&
      client?.canReset == true;

  Future<void> resetDevice(DeviceReset kind) async {
    if (!canReset) return;
    final session = client!;
    final previousId = selectedId;
    final lifecycle = _lifecycle;
    await run(() async {
      resetting = true;
      // Pausing during the attempt must not schedule an automatic reconnect.
      selectedId = null;
      _resumeId = null;
      _resumePending = false;
      changed();
      late ResetResult result;
      try {
        result = await session.resetDevice(kind);
      } finally {
        resetting = false;
        if (identical(client, session)) {
          if (session.connected) {
            selectedId = previousId;
          } else {
            _generation++;
            _poll?.cancel();
            ready = false;
            stage = 'Offline';
            devices.clear();
            final updates = _updates;
            _updates = null;
            client = null;
            Object? cleanupFailure;
            _cleanup = _cleanup
                .then((_) => _release(null, updates, session))
                .catchError((Object e) {
                  cleanupFailure = e;
                });
            await _cleanup;
            if (cleanupFailure != null) throw cleanupFailure!;
          }
        }
        if (!session.connected) {
          await _preferences?.remove('selectedDevice');
        }
      }
      if (_disposed || !_foreground || lifecycle != _lifecycle) return;
      stage = t('Vyhledej WC znovu', 'Scan for the toilet again');
      error = result == ResetResult.acknowledged
          ? t(
              'Zařízení potvrdilo příkaz resetu. Nech ho dokončit náběh a potom WC znovu vyhledej.',
              'The device acknowledged the reset command. Let it finish starting up, then scan again.',
            )
          : t(
              'Reset nebyl potvrzený; výsledek není známý. Příkaz nebyl zopakován. Nech WC dokončit náběh a znovu ho vyhledej.',
              'The reset was not acknowledged; its outcome is unknown. The command was not retried. Let the toilet finish starting up, then scan again.',
            );
      changed();
    });
  }

  Future<void> stopShower() async {
    if (!canStop) return;
    final session = client!;
    final lifecycle = _lifecycle;
    final operation = Completer<void>();
    _stopOperation = operation.future;
    stopping = true;
    error = '';
    changed();
    try {
      await session.stopShower();
    } catch (e) {
      if (!_disposed && _foreground && lifecycle == _lifecycle) {
        error = e.toString();
      }
    } finally {
      stopping = false;
      _stopOperation = null;
      operation.complete();
      changed();
      _tryResumeDevice();
    }
  }

  Future<void> scan() => run(() async {
    _resumePending = false;
    final generation = ++_generation;
    await _cleanup;
    if (!_current(generation)) return;
    final allowed = await ble.requestPermissions();
    if (!_current(generation)) return;
    if (!allowed) {
      throw ProtocolException(
        t(
          'Povol přístup k Bluetooth v nastavení telefonu.',
          'Allow Bluetooth access in your phone settings.',
        ),
      );
    }
    final previous = _discoveries;
    _discoveries = null;
    await previous?.cancel();
    if (!_current(generation)) return;
    devices.clear();
    stage = t('Hledání WC', 'Finding toilet');
    scanning = true;
    try {
      _discoveries = ble.scan().listen(
        (device) {
          if (!_current(generation)) return;
          devices[device.id] = {
            'id': device.id,
            'name': device.name,
            'rssi': device.rssi,
            'connectable': device.connectable,
            'seenAt': DateTime.now(),
          };
          _tryResumeDevice();
          changed();
        },
        onError: (Object e) {
          if (!_current(generation)) return;
          error = e.toString();
          scanning = false;
          stage = 'Offline';
          _scanTimer?.cancel();
          final discoveries = _discoveries;
          _discoveries = null;
          unawaited(discoveries?.cancel());
          changed();
        },
        onDone: () {
          if (!_current(generation)) return;
          scanning = false;
          stage = 'Offline';
          changed();
        },
      );
    } catch (_) {
      scanning = false;
      stage = 'Offline';
      rethrow;
    }
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 10), () {
      if (!_current(generation)) return;
      final discoveries = _discoveries;
      _discoveries = null;
      unawaited(discoveries?.cancel());
      scanning = false;
      stage = 'Offline';
      if (devices.isEmpty) {
        error = t(
          'WC nenalezeno. Přibliž telefon a ukonči připojení v ostatních aplikacích.',
          'No toilet found. Move closer and disconnect other apps.',
        );
      }
      changed();
    });
  });

  void _tryResumeDevice() {
    if (_disposed || !_foreground || !scanning || busy || stopping) return;
    final id = _resumeId;
    final device = devices[id];
    final seen = device?['seenAt'] as DateTime?;
    if (id == null || device?['connectable'] != true || seen == null) return;
    if (DateTime.now().difference(seen) > const Duration(seconds: 5)) return;
    _resumeId = null;
    unawaited(connect(id));
  }

  Future<void> connect(String id) => run(() async {
    _resumePending = false;
    final previousGeneration = _generation;
    await _cleanup;
    if (!_current(previousGeneration)) return;
    final lastSeen = devices[id]?['seenAt'] as DateTime?;
    if (lastSeen == null ||
        DateTime.now().difference(lastSeen) > const Duration(seconds: 5)) {
      throw ProtocolException(
        t(
          'Vyhledej WC znovu; poslední signál je starý.',
          'Scan again; the last advertisement is stale.',
        ),
      );
    }
    final generation = ++_generation;
    _scanTimer?.cancel();
    _poll?.cancel();
    scanning = false;
    ready = false;
    final discoveries = _discoveries;
    final updates = _updates;
    final previous = client;
    _discoveries = null;
    _updates = null;
    client = null;
    await _release(discoveries, updates, previous);
    if (!_current(generation)) return;
    stage = t('Připojování', 'Connecting');
    changed();
    try {
      await ble.connect(id);
      if (!_current(generation)) {
        await ble.disconnect();
        return;
      }
      stage = t('Ověření a načtení stavu', 'Authenticating and reading state');
      changed();
      final session = NaviaClient(ble);
      client = session;
      _updates = session.updates.listen((_) {
        if (!_current(generation) || !identical(client, session)) return;
        if (!session.connected) {
          ready = false;
          stage = 'Offline';
        }
        changed();
      });
      try {
        await session.initialize();
      } catch (_) {
        await session.dispose();
        rethrow;
      }
      if (!_current(generation)) {
        await session.dispose();
        return;
      }
      selectedId = id;
      ready = true;
      stage = t('Připojeno', 'Connected');
      await _preferences?.setString('selectedDevice', id);
      if (!_current(generation)) return;
      _poll = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_current(generation) &&
            ready &&
            !busy &&
            !stopping &&
            session.state?.descaling == true) {
          unawaited(
            run(() async {
              await session.readState();
              await session.readTimer();
            }),
          );
        }
      });
    } catch (_) {
      if (_current(generation)) {
        ready = false;
        stage = 'Offline';
      }
      rethrow;
    }
  });

  Future<void> _release(
    StreamSubscription<NearbyDevice>? discoveries,
    StreamSubscription<void>? updates,
    NaviaClient? session,
  ) async {
    Object? failure;
    // Always attempt every cleanup, even if a subscription cancellation fails.
    for (final release in <Future<void> Function()>[
      if (discoveries != null) discoveries.cancel,
      if (updates != null) updates.cancel,
      if (session != null) session.dispose,
      ble.disconnect,
    ]) {
      try {
        await release();
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw failure;
  }

  Future<void> pause() {
    if (_disposed) return Future.value();
    _foreground = false;
    _resumePending = false;
    _lifecycle++;
    _generation++;
    _resumeId = selectedId;
    _poll?.cancel();
    _scanTimer?.cancel();
    scanning = false;
    ready = false;
    stage = 'Offline';
    // Detach this generation's resources before any asynchronous cleanup.
    final discoveries = _discoveries;
    final updates = _updates;
    final session = client;
    _discoveries = null;
    _updates = null;
    client = null;
    _cleanup = _cleanup
        .then((_) => _release(discoveries, updates, session))
        .catchError((Object e) {
          if (!_disposed) {
            error = e.toString();
            changed();
          }
        });
    changed();
    return _cleanup;
  }

  Future<void> resume() {
    if (_disposed) return Future.value();
    _foreground = true;
    if (_resumeId == null) return Future.value();
    _resumePending = true;
    return _resumeWork ??= _resumeWhenReady();
  }

  Future<void> _resumeWhenReady() async {
    try {
      while (_resumePending && _foreground && !_disposed) {
        final cleanup = _cleanup;
        await cleanup;
        await _operation;
        await _stopOperation;
        if (!identical(cleanup, _cleanup)) continue;
        if (!_resumePending || !_foreground || _disposed) return;
        _resumePending = false;
        if (_resumeId != null && !ready) await scan();
      }
    } finally {
      _resumeWork = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _foreground = false;
    _resumePending = false;
    _generation++;
    _poll?.cancel();
    _scanTimer?.cancel();
    final discoveries = _discoveries;
    final updates = _updates;
    final session = client;
    _discoveries = null;
    _updates = null;
    client = null;
    unawaited(
      _cleanup
          .then((_) async {
            try {
              await _release(discoveries, updates, session);
            } finally {
              await ble.dispose();
            }
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}

import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:noventa_protocol/mobile_ble.dart';
import 'package:noventa_protocol/noventa_protocol.dart';
import 'package:permission_handler/permission_handler.dart';

class ReactiveBleBackend implements MobileBleBackend {
  final FlutterReactiveBle ble;
  bool _legacyAndroid = false;
  ReactiveBleBackend({FlutterReactiveBle? ble})
    : ble = ble ?? FlutterReactiveBle();
  static final _service = Uuid.parse(serviceUuid);
  static final _write = Uuid.parse(writeUuid);
  static final _notify = Uuid.parse(notifyUuid);

  @override
  Future<bool> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      _legacyAndroid = sdk < 31;
      final permissions = _legacyAndroid
          ? [Permission.locationWhenInUse]
          : [Permission.bluetoothScan, Permission.bluetoothConnect];
      final results = await permissions.request();
      return results.values.every((status) => status.isGranted);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return (await Permission.bluetooth.request()).isGranted;
    }
    throw UnsupportedError('OpenLauf supports Android and iOS');
  }

  Future<void> _ready() async {
    await ble.initialize();
    var status = ble.status;
    if (status == BleStatus.unknown || status == BleStatus.unauthorized) {
      status = await ble.statusStream
          .firstWhere(
            (s) => s != BleStatus.unknown && s != BleStatus.unauthorized,
          )
          .timeout(const Duration(seconds: 5), onTimeout: () => ble.status);
    }
    if (status != BleStatus.ready) {
      throw ProtocolException('Bluetooth: ${status.name}');
    }
  }

  static NearbyDevice? discovered(DiscoveredDevice device) {
    final data = device.manufacturerData;
    final navia =
        data.length >= 7 && data[0] == 0x1d && data[1] == 0x01 && data[6] == 2;
    if (!device.serviceUuids.contains(_service) && !navia) return null;
    // Some CoreBluetooth versions report connectability as unknown. Preserve
    // an explicit "unavailable", otherwise use manufacturer flags when present.
    final connectable =
        device.connectable != Connectable.unavailable &&
        (device.connectable == Connectable.available ||
            !navia ||
            (data[4] & 1) != 0);
    return NearbyDevice(
      id: device.id,
      name: device.name.isEmpty ? 'Cleanet Navia' : device.name,
      rssi: device.rssi,
      connectable: connectable,
    );
  }

  @override
  Stream<NearbyDevice> scan() async* {
    await _ready();
    await for (final device in ble.scanForDevices(
      withServices: [],
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: _legacyAndroid,
    )) {
      final match = discovered(device);
      if (match != null) yield match;
    }
  }

  @override
  Stream<LinkState> connect(String id) async* {
    await _ready();
    await for (final update in ble.connectToAdvertisingDevice(
      id: id,
      // Manufacturer-only advertisements are valid discovery results too.
      // Keep the prescan unfiltered; the plugin selects this exact device ID.
      withServices: [],
      prescanDuration: const Duration(seconds: 3),
      connectionTimeout: const Duration(seconds: 10),
      servicesWithCharacteristicsToDiscover: {
        _service: [_write, _notify],
      },
    )) {
      yield switch (update.connectionState) {
        DeviceConnectionState.connected => LinkState.connected,
        DeviceConnectionState.disconnected => LinkState.disconnected,
        _ => LinkState.connecting,
      };
    }
  }

  @override
  Future<Stream<List<int>>> subscribe(String id) async {
    // Resolve before subscribing so asynchronous service discovery cannot race
    // the first AUTH_IDENTIFY write. GATT operations are queued by the plugin.
    final characteristic = await ble.resolveSingle(
      QualifiedCharacteristic(
        deviceId: id,
        serviceId: _service,
        characteristicId: _notify,
      ),
    );
    if (!characteristic.isNotifiable) {
      throw ProtocolException('Noventa notifications unavailable');
    }
    return characteristic.subscribe();
  }

  @override
  Future<void> write(String id, List<int> bytes) =>
      ble.writeCharacteristicWithoutResponse(
        QualifiedCharacteristic(
          deviceId: id,
          serviceId: _service,
          characteristicId: _write,
        ),
        value: bytes,
      );
  @override
  Future<void> dispose() => ble.deinitialize();
}

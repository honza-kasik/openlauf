import 'dart:typed_data';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navia_control/reactive_ble_backend.dart';
import 'package:noventa_protocol/mobile_ble.dart';
import 'package:noventa_protocol/noventa_protocol.dart';

DiscoveredDevice device({
  String id = 'ios-peripheral-uuid',
  String name = '',
  List<int> manufacturer = const [],
  List<Uuid> services = const [],
  Connectable connectable = Connectable.unknown,
}) => DiscoveredDevice(
  id: id,
  name: name,
  serviceData: {},
  manufacturerData: Uint8List.fromList(manufacturer),
  rssi: -42,
  serviceUuids: services,
  connectable: connectable,
);

class PrescanBle extends Fake implements FlutterReactiveBle {
  final DiscoveredDevice advertisement;
  PrescanBle(this.advertisement);
  @override
  Future<void> initialize() async {}
  @override
  BleStatus get status => BleStatus.ready;
  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    expect(id, advertisement.id);
    expect(servicesWithCharacteristicsToDiscover?[Uuid.parse(serviceUuid)], [
      Uuid.parse(writeUuid),
      Uuid.parse(notifyUuid),
    ]);
    if (!withServices.every(advertisement.serviceUuids.contains)) {
      return Stream.error(StateError('Prescan excluded this advertisement'));
    }
    return Stream.value(
      ConnectionStateUpdate(
        deviceId: id,
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }
}

void main() {
  test(
    'manufacturer-only discovery also passes the connection prescan',
    () async {
      final advertisement = device(manufacturer: [0x1d, 1, 1, 2, 1, 255, 2, 0]);
      final found = ReactiveBleBackend.discovered(advertisement)!;
      final backend = ReactiveBleBackend(ble: PrescanBle(advertisement));
      expect(await backend.connect(found.id).first, LinkState.connected);
    },
  );
  test(
    'accepts advertised service with opaque iOS UUID and unknown availability',
    () {
      final found = ReactiveBleBackend.discovered(
        device(services: [Uuid.parse(serviceUuid)]),
      );
      expect(found?.id, 'ios-peripheral-uuid');
      expect(found?.name, 'Cleanet Navia');
      expect(found?.connectable, isTrue);
    },
  );
  test('recognizes Noventa manufacturer data including the company prefix', () {
    final found = ReactiveBleBackend.discovered(
      device(manufacturer: [0x1d, 1, 1, 2, 1, 255, 2, 0]),
    );
    expect(found?.connectable, isTrue);
    expect(found?.rssi, -42);
  });
  test('unknown connectability falls back to manufacturer flags', () {
    final found = ReactiveBleBackend.discovered(
      device(manufacturer: [0x1d, 1, 1, 2, 0, 255, 2, 0]),
    );
    expect(found?.connectable, isFalse);
  });
  test('explicitly unavailable radio advertisement remains disabled', () {
    final found = ReactiveBleBackend.discovered(
      device(
        services: [Uuid.parse(serviceUuid)],
        connectable: Connectable.unavailable,
      ),
    );
    expect(found?.connectable, isFalse);
  });
  test('name alone does not identify a supported toilet', () {
    expect(ReactiveBleBackend.discovered(device(name: 'Navia')), isNull);
    expect(
      ReactiveBleBackend.discovered(device(manufacturer: [0x1d, 1])),
      isNull,
    );
  });
}

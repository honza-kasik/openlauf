# Noventa protocol: Navia

Independent implementation based on local APK inspection and a BLE capture.
No original app code or graphics are included. Hardware verification is pending.

Service `CEDAAD00-57A7-40BF-842C-B1C4A1C4624A`; command write characteristic
`CEDAAD01-...` (without response), notifications `CEDAAD02-...`.
Discover UUIDs and CCCD dynamically; capture handles are not portable.

The app uses flutter_reactive_ble on Android and iOS. Its platform implementations
own GATT discovery, notification setup and writes. The shared pure Dart
PluginBleTransport owns connection timeouts, notification forwarding and cleanup;
tests substitute MobileBleBackend. Device IDs must stay opaque, because an iOS
CoreBluetooth UUID is not a Bluetooth MAC address. No radio work is done after
the app pauses; resuming reads state through a new connection.

## Framing and session

`COBS(command + payload + CRC16 little-endian) + 00`.
CRC: reflected polynomial `0x8408`, initial `0`, final XOR `0xffff`.
Check vector `123456789` => `DE76`. Notifications can have a leading delimiter,
split frames or multiple frames. Bad CRC/COBS frames are rejected.

Enable notifications before AUTH_IDENTIFY (`02`, payload `A76EA167899B93C0`).
This is the original application's fixed SERVICE_TOOL identifier, not a user
credential. A successful reply is `82 00 01`. Product info model `02` identifies
Navia. The device info bit `0x10` means descaling **disabled**, despite the
opposite-sounding label in the original metadata.

Replies generally use command OR `80`; first payload byte is status (`00` OK,
`03` invalid parameter, `04` invalid state). One outstanding request at a time;
there is no transaction ID. Timeout invalidates the session; never replay actions.
Send event acknowledgements even while a request is outstanding:

| Notification | Payload | ACK |
|---|---|---|
| `22` state | state, profile, flags, controller flags, substate | `A2 00` |
| `24` configuration | profile, parameter, value | `A4 00` |
| `2D` timer | timer ID, seconds (uint32 BE) | `AD 00` |

Reads: `20 FF` info; `21 FF` state; `23 profile keys...` configuration;
`27 FF` alarms; `2C 02 FF` descaling timer. `AC` response: status + uint32 BE.
Write a setting: `25 profile key value`; read it back. Profile `00` is basic;
`FF` is global. Configuration response: status + profile + values in request order.

| Parameter | Key | Scope |
|---|---|---|
| Rear pressure / position | `00` / `01` | Basic, 1–7 |
| Rear duration | `02` | Read-only pending conflicting metadata resolution |
| Front pressure / position | `05` / `06` | Basic, 1–7 |
| Front duration | `07` | Read-only pending conflicting metadata resolution |
| Water temperature | `0A` | Basic, 1–7; unexpected values preserved |
| Heater | `10` | Global, wire 0 OFF / 1 ECO / 2 ON |
| Water hardness | `11` | Global, 1–4 |

Actions use `26 event 00`. Rear start `02`, lady start `01`, cancel shower `05`,
oscillation toggles `22`/`23`, nozzle extend/retract `0B`/`0A`, appliance flush
`62`, save `50`. Other shared Riva commands are intentionally not exposed.

## Descaling

`26 0F 00` enters preparation and is used again by the original wizard to
continue. State 12 is preparation/descaling, 15 ready, 16 active. Read current
state before each explicit step: if already 16, never send a second start.
There is no active-cycle cancel button. The original `26 10 00` stop command
is not exposed because Navia's manual says an active cycle cannot be interrupted.
The device may advance automatically when the side cover closes. A zero timer
does not prove completion. Resume by reading state and timer, not replaying steps.

## Evidence and sources

Captured vectors in tests cover authentication, state reads, rear start/stop,
notification ACKs and state changes. Product information fixtures use synthetic
identifiers. Configuration writes, front control and descaling are derived from
the original app and must be checked on real hardware before a stable release.

- [Navia operating manual, especially 4.3 and 5.7](https://www.laufen.nl/documents/d/laufen/laufen_cleanet_navia_operating_manual_en_1221)
- Local analysis: Hermes `BleServiceNoventa`, `NoventaHelper`, model 37 definitions,
  `DescalingScreen`. Original artifacts remain outside this public project.

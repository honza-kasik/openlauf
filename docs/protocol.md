# Noventa protocol: Navia

Independent implementation based on local APK inspection and a BLE capture.
No original app code or graphics are included. Full hardware acceptance is pending.
See [models, differences, and support](models-and-support.md) for Riva comparisons
and additional command candidates whose Navia support remains unverified.

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

This identifies the client role; it does not demonstrate authorization by the
appliance owner. See [authentication and access control](#authentication-and-access-control).

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

## Resets

The original Navia catalog defines these commands; full hardware acceptance of
their effects remains pending:

| Reset | Command | Payload | Reply command |
| --- | --- | --- | --- |
| Factory settings (`FactoryResetStart`) | `26` | `52 00` | `A6` |
| Bluetooth communication (`BluetoothReset`) | `17` | Empty | `97` |

Both are exposed in Diagnostics with explicit confirmation. Factory reset warns
that individual settings will be erased. Reset requires a known Navia in Standby
(`1`) or Ready (`2`); state is read again before dispatch, and newer state
notifications take precedence over an older read reply. Active operations,
descaling preparation/cycles, service position and unknown states prevent reset.

Only one attempt is sent. Queued ordinary operations and duplicate resets are
blocked, and the session is invalidated after an attempt. An application-level
ACK means the command was acknowledged, not that all reset effects have been
verified. Disconnect, timeout or write failure without a reply is reported as an
unconfirmed outcome; it never causes an automatic retry. An explicit rejection
is shown as an error. The app clears cached device state and the remembered
selection, then requires a fresh scan and connection.

## Descaling

`26 0F 00` enters preparation and is used again by the original wizard to
continue. State 12 is preparation/descaling, 15 ready, 16 active. Read current
state before each explicit step: if already 16, never send a second start.
There is no active-cycle cancel button. The original `26 10 00` stop command
is not exposed because Navia's manual says an active cycle cannot be interrupted.
The device may advance automatically when the side cover closes. A zero timer
does not prove completion. Resume by reading state and timer, not replaying steps.

In the analyzed original `DescalingScreen`, the timer-completion handler only
returns to the previous screen. It sends no additional completion command.
This static comparison does not establish that every physical stage
completed successfully on a particular appliance.

## Authentication and access control

The analyzed original Noventa adapter declares `authMethod=None` and disables
password validation and password changes. It uses the shared `SERVICE_TOOL`
identifier described above. OpenLauf requires no manufacturer account, and the
handshake contains no owner-specific credential. Account login in the official
app must not be assumed to protect this BLE path.

Reported connection requirements differ between clients: one report describes
connection without physical pairing confirmation, while the original Laufen
Cleanet iOS app reportedly required switching the toilet off for 60 seconds and
back on before connecting. Whether that step opens a connection window or
recovers a failed connection has not been established. The app-level handshake
alone does not establish the appliance's full access-control behavior.

Formal tests with a fresh, unpaired client and recorded appliance firmware are
still pending. In particular, starting an active descaling cycle without any
owner interaction and its potential denial-of-service impact remain unverified.
These observations do not establish the behavior of other models or revisions.

## Alarm reads

The app's **Read alarms** action displays raw decimal values returned by command
`27 FF`; it does not translate them into component diagnoses.
The shared response status byte is removed
before these values are displayed; an empty alarm list was observed in the
supplied original-app capture.

### Alarm 145: pump-related observation

An owner reported raw decimal alarm **145** (`0x91`) on one physical Cleanet
Navia. Its hardware/firmware revision was not recorded for this observation.

Observed sequence:

- Both OpenLauf and the official app reported 145 when the rear shower nozzle
  extended, delivered no water, and retracted. A brief hum preceded the expected
  pumping stage.
- The disconnected pump motor was found mechanically seized. After the motor
  was repaired, the shower worked again.
- The motor was marked Johnson and had two power wires; no separate rotational
  speed sensor was observed. This alone does not establish the controller's
  fault-detection method.

This supports an association between 145 and failed pumping on this appliance.
Two possible detection mechanisms remain unverified:

| Hypothesis | Possible mechanism | Evidence still missing |
| --- | --- | --- |
| Pump motor overcurrent / stall protection | A seized motor could draw excessive current and trigger protection. Current sensing can use the two-wire power path without a separate motor sensor. | Motor current, protection threshold, and a manufacturer definition of 145 were not obtained. |
| Expected water-level change not detected | If the controller expects the tank level to fall during a pumping stage, a stalled pump could cause a timeout when that change does not occur. | The relevant level sensor, expected level change, and timeout behavior have not been confirmed. |

The repair outcome does not distinguish these hypotheses. Alarm 145 must not be
presented as a confirmed manufacturer code for overcurrent or a seized motor,
and other causes of failed pumping may produce the same code. OpenLauf continues
to display the raw value without assigning a component diagnosis.

## Evidence and sources

Captured vectors in tests cover authentication, state reads, rear start/stop,
notification ACKs and state changes. Product information fixtures use synthetic
identifiers. Configuration writes, front control and descaling are derived from
the original app and require full hardware acceptance before a stable release.

- [Navia operating manual, especially 4.3 and 5.7](https://www.laufen.nl/documents/d/laufen/laufen_cleanet_navia_operating_manual_en_1221)
- Local analysis: Hermes `BleServiceNoventa`, `NoventaHelper`, model 37 definitions,
  `DescalingScreen`. Original artifacts remain outside this public project.

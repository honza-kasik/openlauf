# Models, differences, and support

OpenLauf currently targets **Cleanet Navia**. The original app's shared command
catalog is useful for researching other models, but it is not a list of features
confirmed to work on every appliance.

## Model support

| Model | Original app catalog | OpenLauf support | Evidence |
| --- | --- | --- | --- |
| Navia | Noventa, component type `37` | Implemented target; full physical acceptance remains pending | Original app analysis, captured BLE exchanges, and automated tests. |
| Riva, as represented by catalog type `36` | Noventa, component type `36` | Not supported; the client rejects non-Navia product information | Original app metadata and UI analysis; no Riva hardware validation. |
| Other Cleanet models or revisions | Requires identification; the original app contains several different BLE adapters | Not supported | Protocol and hardware capabilities have not been mapped. |

Catalog component IDs `37` and `36` are separate from the model byte returned by
the device's product-information command. The current client recognizes Navia
as model byte `02`; catalog IDs must not be substituted for that byte.

## How to read the evidence

- **Implemented** means OpenLauf contains the feature and tests its software
  behavior. Full operation on a physical appliance can still be unverified.
- **Captured** means the supplied recording contains an exchange with the
  original app. It is not an OpenLauf hardware acceptance test.
- **Static candidate** means a command, parameter, or UI definition exists in
  the original APK. Device support and physical behavior remain unverified.

An accepted command or a returned parameter value alone does not demonstrate
that the requested physical function exists or ran successfully.

## Features and differences

| Feature | Navia in OpenLauf | Original app evidence and model differences |
| --- | --- | --- |
| Rear/lady shower, pressure, position, water temperature, oscillation | Implemented; see the [protocol notes](protocol.md) for captured versus inferred behavior | Basic Navia controls; similar names also occur in Riva's catalog. |
| Nozzle service position, appliance flushing, descaling | Implemented; full physical acceptance pending | Navia-specific flows are described in its manual and original app. |
| Factory settings and Bluetooth reset | Implemented; physical acceptance pending | Defined in Navia's original catalog; confirmed by the user before sending, restricted to idle states, and followed by a fresh scan. See [reset behavior](protocol.md#resets). |
| Pulsating rear/front spray | Static candidate; not exposed | Both catalogs contain `RearWashPulsatingToggle` and `FrontWashPulsatingToggle`. The original action screen adds pulsation controls only for Riva. Navia firmware support is unknown. |
| Shower duration | Read-only | Navia metadata maps values `1`, `2`, `3` to 15, 20, 25 seconds, while Riva's settings UI uses a `1–7` slider. The captured Navia reports `0`; its meaning is unresolved. |
| Additional user profiles | Basic profile only | The shared catalog names `User0Enable` through `User4Enable`; the original app has a Riva profile selector. Additional Navia profiles are not confirmed. |
| Lighting | Static candidate; not exposed | `LightConfiguration` and `LightSaveConfiguration` exist in the shared catalog. The controlled light and supported Navia values are unidentified; this does not establish a night-light feature. |
| Scheduled hygienic/thermal cleaning | Static candidate; not exposed | The original app contains `ThermalCleaningScreen`, `HygienicFlushDelay`, and delay controls. Navia support is unverified. This cycle is distinct from the implemented appliance-flushing command. |
| Dryer, deodorizer, automatic cistern flush | Not exposed | Names occur in the shared catalog. Their presence does not establish that Navia has the required hardware or supports these commands. |
| Demo, registration, debug functions | Static candidates; not exposed | Shared event/command names exist, but payload semantics and model-specific behavior require separate research. |

## Candidate protocol details

These are research references, not additional enabled OpenLauf features.

| Candidate | Known identifiers | What remains to establish |
| --- | --- | --- |
| Pulsation | Command `26`, rear event `24`, front event `25`; profile keys `04`/`09`, bit `02` in the original read converters | Whether Navia accepts the actions and produces pulsing rather than ignoring them. |
| Duration | Profile keys `02`/`07`; increase/decrease events `1E`/`1F` for rear and `20`/`21` for front | Meaning of the captured zero value, supported values, and actual timing. Writing remains disabled. |
| Lighting | Global key `22`; `LightSaveConfiguration` event `42` | Hardware target, value encoding, and persistence. |
| Hygienic cycle | Global key `12`; delay events `32`/`33` | Model support, units, and cycle behavior. Appliance flushing uses event `62` and is a separate operation. |
| Profiles | `User0Enable` through `User4Enable`, events `46` through `4A` | Which profile slots exist on each model and whether their settings persist independently. |

The supplied Navia recording returned zero for duration keys `02` and `07`,
mode bytes `04` and `09`, and global keys `12` and `22`. A zero may mean a
default, an inactive option, or an unsupported field; the recording does not
distinguish these cases. In particular, the duration result does not match the
catalog's documented `1–3` enumeration.

## Adding support for another model

Record the appliance model, hardware/firmware revision, BLE adapter, and observed
product-information values first. Define capabilities per model and revision,
then validate each exposed setting or action with readback and observed behavior.
Shared command names should remain research candidates until that evidence exists.

## Sources

- Original `ch.laufen.smartcontrol` APK `1.7.60` / build `378`: Navia and Riva
  catalog definitions; `ActionDetailScreen`; `NaviaSettingsStructure`;
  `RivaSettingsStructure`; `RivaProfileSelection`; `ThermalCleaningScreen`.
- Supplied Navia Bluetooth capture from 2026-03-16. Original APKs, decompiled
  source, and captures remain outside this repository.
- [Navia operating manual](https://www.laufen.nl/documents/d/laufen/laufen_cleanet_navia_operating_manual_en_1221):
  basic profile, controls, and factory-preset 25-second shower duration.
- [Current client implementation](../packages/noventa_protocol/lib/noventa_protocol.dart)
  and [exposed application controls](../lib/main.dart).

# OpenLauf

<img src="assets/branding/openlauf.png" width="96" height="96" alt="OpenLauf icon">

Independent local Bluetooth controller targeting compatibility with
**LAUFEN Cleanet Navia**, focused on the current Android version and iOS 13+.
The analyzed official app (1.7.60) targets Android 15 (API 35).
Czech/English UI, system light/dark theme.
Licensed under GPLv3 (`GPL-3.0-only`).

**Experimental: full physical BLE and descaling acceptance remains pending.
Not affiliated with or endorsed by LAUFEN.**

## Implemented

- BLE discovery, bounded connection with a fresh advertising scan, service discovery, notification subscription,
  authentication, bounded requests and explicit connection errors.
- Rear/lady shower, stop, pressure and position, temperature, oscillation;
  basic profile save, heater and water hardness, verified setting readback.
- Descaling preparation/continuation, device-based phases and remaining time,
  automatic-start detection, resynchronization after returning from background.
- Nozzle service position, appliance flushing, product info and raw alarm reads.
- Factory and Bluetooth resets with confirmation, idle-state checks, session
  invalidation and manual reconnection; reset commands are never replayed.
- Redacted diagnostic copy: metadata only, never device identifiers or payloads.

The UI, protocol and connection lifecycle are shared by Android and iOS.
`ReactiveBleBackend` uses `flutter_reactive_ble` 5.6.0 for both platforms;
`PluginBleTransport` implements the testable `BleTransport` contract in pure Dart.
Android's MainActivity and iOS's AppDelegate only register Flutter plugins.
No custom Kotlin or Swift Bluetooth implementation is needed. Device IDs are
opaque (MAC on Android, CoreBluetooth UUID on iOS).

Android runtime permissions use `permission_handler` with `device_info_plus`
to choose location permission on Android 8–11 or Nearby devices on Android 12+.
iOS requests Bluetooth access with `NSBluetoothAlwaysUsageDescription`.
There is no Bluetooth background mode; returning to the app scans/reconnects
and reads state without replaying actions.

## Build and test

Flutter 3.47.7 / Dart 3.13.5, JDK 17 or 21, Android compile/target SDK 37, Gradle 9.8.2,
Android Gradle Plugin 9.5.1, Kotlin 2.4.21.
Run `flutter pub get` with network access to fetch the dependencies in
`pubspec.lock`. BLE plugin 5.6.0 supports AGP 9 and Android SDK 37.
Android uses AGP 9's built-in Kotlin support. The BLE plugin still requires
`android.newDsl=false`; Protobuf Gradle plugin `0.10.1` is pinned in the shared
plugin classpath because its requested `0.9.4` cannot configure AGP 9 variants.
The Gradle wrapper scripts and bootstrap JAR are tracked in the repository.
Use a checkout path without apostrophes: the Dart test runner currently generates
invalid imports for such paths. Android SDK/Flutter/pub/Gradle caches must be writable.

```sh
flutter pub get
cd packages/noventa_protocol
dart pub get
dart test
cd ../..
flutter analyze
flutter test
flutter build apk --debug
```

Install `build/app/outputs/flutter-apk/app-debug.apk` on a physical device running
the current Android version. CI uses a standalone Dart SDK to analyze and test
the protocol package on pull requests or manual runs. It installs Dart and the
protocol package's locked dependencies. Run Flutter checks and platform builds
locally.

For a signed release, create your own signing key outside the repository and
set `android/key.properties` with `storeFile`, `storePassword`, `keyAlias`, and
`keyPassword`. Then run `flutter build apk --release`. Never publish the key.
There is no release signing fallback to a debug key.

### iOS

On a Mac with Xcode and CocoaPods:

```sh
flutter pub get
cd ios
pod install
cd ..
flutter build ios --simulator --debug --no-codesign
```

For a physical iPhone open `ios/Runner.xcworkspace`, select your development
team for Runner, then use `flutter run -d <iphone-id>`. Accept the Bluetooth
prompt on first discovery. Test BLE on a physical phone; simulator compilation
does not validate radio communication. The Podfile enables only Bluetooth in
permission_handler's Apple code. The deployment target is iOS 13.0.

## First hardware check

1. Disconnect other BLE clients, enable Bluetooth, grant Nearby devices access.
2. Find Navia, connect and read firmware, state, settings and timer.
3. Repeat connection/disconnection ten times; test permission denial and leaving range.
4. Compare readback after each setting; check rear/lady shower and stop during normal use.
5. Test nozzle extension in standby and retraction in service position.
6. When descaling is due, follow the Navia manual with the prescribed product.
   Verify both preparation stages and automatic start on closing the cover.
7. Lock/reopen the phone and restart the app during the cycle; reconnect and
   verify state/time without sending another start. Confirm actual completion
   from the WC state, not a zero timer.

An active descaling cycle cannot be cancelled according to the Navia manual;
there is deliberately no active-cycle Stop button. The application does not
require a permanent background connection and closing it sends no cancel action.

## Evidence and remaining work

See [protocol documentation](docs/protocol.md) and
[models, differences, and support](docs/models-and-support.md). Captured traffic
verifies auth, rear start/stop and notifications. Other commands derive from
static analysis and need physical validation. Duration writes remain disabled
because original metadata conflicts; existing values are displayed without
overwriting them.
Shared Riva dryer/flush/production commands are not advertised as Navia features.
Manufacturer cloud accounts, firmware flashing and original graphics are not included.

The BLE handshake uses the original app's shared service identifier rather than
an owner-specific credential. See [authentication and access control](docs/protocol.md#authentication-and-access-control)
for the evidence and remaining security checks.

Local verification: 54 pure Dart protocol/session/transport tests and all 25
Flutter controller/backend/widget tests passed. Whole-app analysis and an Android
debug APK build also passed. Tests cover write failures and stale replies,
priority Stop, descaling guards, cancellation, reconnects and manufacturer-only
advertisements. Flutter tests inject a fake BLE transport or plugin facade.
The debug APK was installed on a physical Android device. Full physical
BLE/descaling acceptance and iOS builds remain unverified; iOS builds require
macOS/Xcode.

## App icon

The editable vector source is [openlauf.svg](assets/branding/openlauf.svg).
To regenerate Android icons (including the themed monochrome variant), iOS
icons and the README preview, run `python3 tool/generate_icons.py`.
The script requires `rsvg-convert` (librsvg) and Pillow.

Original APKs, captures and bugreports stay outside this project. Public test
fixtures contain only selected protocol vectors and synthetic device information.

## License

Copyright (c) 2026 OpenLauf contributors.

OpenLauf, including the standalone `noventa_protocol` BLE library, is licensed
under the GNU General Public License version 3 only (`GPL-3.0-only`). See the
[project license](LICENSE) and the [library's license](packages/noventa_protocol/LICENSE).

When distributing a modified or combined derivative program, the covered work
must remain under GPLv3 and its recipients must be able to obtain the
Corresponding Source under GPLv3. Commercial use and charging for copies are
allowed. Third-party dependencies retain their respective licenses.

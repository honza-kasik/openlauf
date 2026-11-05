# OpenLauf

<img src="assets/branding/openlauf.png" width="96" height="96" alt="OpenLauf icon">

Independent local Bluetooth controller targeting compatibility with
**LAUFEN Cleanet Navia**. Android 8+
(API 26, target API 36) and iOS 13+. Primary Android hardware acceptance target:
Pixel 9. Czech/English UI, system light/dark theme. MIT licensed.

**Experimental: physical BLE and descaling acceptance tests have not yet been
performed. Not affiliated with or endorsed by LAUFEN.**

## Implemented

- BLE discovery, bounded connection with a fresh advertising scan, service discovery, notification subscription,
  authentication, bounded requests and explicit connection errors.
- Rear/lady shower, stop, pressure and position, temperature, oscillation;
  basic profile save, heater and water hardness, verified setting readback.
- Descaling preparation/continuation, device-based phases and remaining time,
  automatic-start detection, resynchronization after returning from background.
- Nozzle service position, appliance flushing, product info and raw alarm reads.
- Redacted diagnostic copy: metadata only, never device identifiers or payloads.

The UI, protocol and connection lifecycle are shared by Android and iOS.
`ReactiveBleBackend` uses `flutter_reactive_ble` 5.5.0 for both platforms;
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

Flutter 3.41.6 / Dart 3.11.4, JDK 17 or 21, Android SDK 36, Gradle 8.11.1.
Run `flutter pub get` with network access to fetch the dependencies in
`pubspec.lock`. BLE plugin 5.5.0 supports this Flutter SDK; 5.6.0 requires a newer
Flutter SDK through its native implementation.
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

Install `build/app/outputs/flutter-apk/app-debug.apk` on the Pixel 9. CI runs
the same checks and uploads the debug APK as an artifact. A second macOS job
builds the iOS simulator app without code signing. The workflow assumes
this directory is the root of the published repository.

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

See [protocol documentation](docs/protocol.md). Captured traffic verifies auth,
rear start/stop and notifications. Other commands derive from static analysis
and need physical validation. Duration writes remain disabled because original
metadata conflicts; existing values are displayed without overwriting them.
Shared Riva dryer/flush/production commands are not advertised as Navia features.
Manufacturer cloud accounts, firmware flashing and original graphics are not included.

Local verification: 44 pure Dart protocol/session/transport tests and all 18
Flutter controller/backend/widget tests passed. Whole-app analysis and a debug
Flutter bundle build also passed. Tests cover write failures and stale replies,
priority Stop, descaling guards, cancellation, reconnects and manufacturer-only
advertisements. Flutter tests inject a fake BLE transport or plugin facade.
The standard `flutter test` launcher cannot bind a local socket in this sandbox;
the same test files were compiled and run directly with `flutter_tester` and a
live test binding, without a VM service. The dependency lockfile is resolved.
Android APK builds, iOS builds and physical BLE/descaling acceptance remain
unverified; iOS builds require macOS/Xcode.

## App icon

The editable vector source is [openlauf.svg](assets/branding/openlauf.svg).
To regenerate Android icons (including the themed monochrome variant), iOS
icons and the README preview, run `python3 tool/generate_icons.py`.
The script requires `rsvg-convert` (librsvg) and Pillow.

Original APKs, captures and bugreports stay outside this project. Public test
fixtures contain only selected protocol vectors and synthetic device information.

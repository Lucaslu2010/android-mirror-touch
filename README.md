# Android Mirror/Touch

[![License: CC BY-NC 4.0](https://img.shields.io/badge/License-CC_BY--NC_4.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc/4.0/)

Mirror an Android device on a Mac and control it with a keyboard and mouse through a virtual USB touchscreen.

Android Mirror/Touch combines a native SwiftUI viewer, screen and audio streaming, editable key mappings, and Android Open Accessory (AOA) 2.0 HID input. The phone runs the application; the Mac provides the display and controls. Android root access and a separately installed companion APK are not required.

## Features

- Embedded H.264 screen mirroring with hardware decoding through VideoToolbox.
- Phone audio playback on the Mac, with volume controls.
- Direct clicking and dragging on the mirrored display.
- Editable **Tap**, **Drag**, and **Joystick** areas, including WASD-style movement.
- Mouse lock for continuous dragging within an assigned area.
- A USB HID transport with contact tracking and support for up to ten simultaneous contacts.
- An `aoa-touch` command-line tool for testing the USB input path independently.

## How it works

The project uses two paths over the USB connection:

```text
Android screen/audio → scrcpy server → ADB-forwarded sockets
                                          ↓
                              Native macOS video/audio player

Mac keyboard/mouse → key mappings → libusb → AOA HID reports
                                               ↓
                                Android external touchscreen input
```

### Screen and audio

The app starts the [scrcpy](https://github.com/Genymobile/scrcpy) server on the connected device through ADB. It reads the H.264 video stream directly, decodes it with VideoToolbox, and presents the newest available frame. Pending decoded frames are coalesced to avoid accumulating a playback queue. Audio is received separately as 48 kHz stereo PCM.

The current server launch requests a 60 FPS ceiling; actual frame rate and latency depend on the device and USB connection.

### AOA virtual touchscreen

Yes: the input mechanism is a virtual touchscreen registered through **AOA 2.0 HID**. Android's [AOA specification](https://source.android.com/docs/core/interaction/accessories/aoa2#hid-support) allows the USB host to register an input device, upload its HID descriptor, and send input reports to Android.

The Mac uses `libusb` to query AOA support, switch the phone into accessory mode when needed, reconnect after USB re-enumeration, and register a **Digitizers / Touch Screen** descriptor. Touch down, movement, and release are encoded as HID contact reports.

The current descriptor uses a hybrid multitouch format: one **8-byte contact packet** per report, with the frame's total contact count on its first packet and zero on continuation packets. It advertises up to ten contacts. Coordinates are normalized to `0…1`, encoded into `0…32767`, and adjusted for display rotation in the GUI.

AOA touch is initialized when input is first needed. Video and audio use scrcpy; touch control uses the separate AOA HID path.

## Supported platforms

| Component | Requirements |
| --- | --- |
| Mac host | macOS 13 or later, Swift 5.9 or later, and Xcode/command-line developer tools. Homebrew paths for Apple Silicon and Intel Macs are recognized. |
| Android device | A device supporting AOA 2.0 HID, an authorized ADB connection, and a USB data cable. Touchscreen classification varies by device/ROM. |
| Audio forwarding | Requires compatible device audio capture; upstream scrcpy supports audio on Android 11 or later. See its [audio documentation](https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md). |
| Other desktop hosts | No Windows or Linux host implementation is provided. |

## Deploy and run

Run these commands from the repository root. The existing checkout may still be named `DeltaForceAuto`; the executable remains `AndroidMirror`.

### 1. Install Mac dependencies

```sh
xcode-select --install
brew install libusb pkg-config scrcpy
brew install --cask android-platform-tools
adb version
scrcpy --version
```

**Version compatibility:** the embedded client currently launches the scrcpy server with version **4.0** and parses that protocol. Check the installed version before running. If Homebrew supplies another version, use a matching 4.0 server installation or update the client and parser together. Installing the newest server alone does not establish compatibility.

The app looks for the server at `/opt/homebrew/opt/scrcpy/share/scrcpy/scrcpy-server` or `/usr/local/opt/scrcpy/share/scrcpy/scrcpy-server`.

### 2. Prepare Android

1. Enable **Developer options → USB debugging**.
2. Connect and unlock the phone using a USB data cable.
3. Accept the computer's USB debugging authorization prompt.
4. Verify that the phone appears with state `device`:

```sh
adb devices -l
```

Connect one Android device while first testing: the AOA transport opens the first compatible USB device, which may differ from an ADB selection when several devices are connected.

### 3. Build and launch

```sh
swift build --product AndroidMirror
swift run AndroidMirror
```

For a release build:

```sh
swift build -c release --product AndroidMirror
.build/release/AndroidMirror
```

This is a source deployment. The executable still needs the external ADB, scrcpy server, and `libusb` installation on the Mac.

## Configure controls

1. Select the connected device and wait for its mirrored screen.
2. Click or drag directly on the preview to check touch alignment.
3. Press **⌘K** to open the mapping editor.
4. Add a Tap, Drag, or Joystick area, position it over the corresponding phone control, and assign its keys. Resize areas using their handles or size control.
5. Leave the editor to use the mappings. Select a Drag area and press **Option** to lock the mouse to it; press Option again to release it.

When a locked drag reaches its area's boundary, the app releases the contact and starts another near the area's center so movement can continue. The expand control hides the surrounding UI for a larger preview.

## Test AOA separately

```sh
swift build --product aoa-touch
.build/debug/aoa-touch list
.build/debug/aoa-touch start
```

Wait for the phone to reconnect in accessory mode, then test in a text field or touch visualizer:

```sh
.build/debug/aoa-touch keyboard-test
.build/debug/aoa-touch tap 0.5 0.5
.build/debug/aoa-touch drag 0.2 0.5 0.8 0.5 600
.build/debug/aoa-touch interactive
```

Interactive mode keeps the HID registered between commands. Avoid running the CLI and GUI against the same HID transport at the same time.

## Current limitations and troubleshooting

- **Device missing:** check the cable, USB authorization, and `adb devices -l`. Accessory-mode switching temporarily disconnects and re-enumerates the phone.
- **Video works but touch does not:** ADB and AOA are independent paths. Check AOA support and whether Android recognizes the external device as a touchscreen. While the HID is registered, inspect `adb shell dumpsys input` or `adb shell getevent -lp`; multitouch axes such as `ABS_MT_POSITION_X/Y` help confirm classification. Diagnostic access can vary by ROM.
- **Touch spikes or jitter:** multitouch and coordinate-handling changes are implemented, but the recorded spike issue still needs device retesting. Ten-contact capability is implemented in the transport; reliable behavior across Android models is not established.
- **Version errors:** verify the scrcpy server/client match described above.

Detailed touch tracing is opt-in because it can add overhead:

```sh
ANDROID_MIRROR_TOUCH_TRACE=1 swift run AndroidMirror
```

See the original [AOA design notes](docs/android-aoa-hid-touch-plan.md) for the investigation and [problem notes](problems.md) for debugging history. The current source is authoritative where those earlier notes describe an older report format.

## License

Copyright © 2026 Lucaslu2010, for original contributions.

Except for third-party material and files with a separate license notice, the
original project source code and documentation are licensed under
[Creative Commons Attribution-NonCommercial 4.0 International
(CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/).
See [LICENSE](LICENSE) for the full legal text.

You may share and adapt the covered material for noncommercial purposes, provided
you give appropriate credit, link to the license, and indicate changes. Commercial
uses requiring permission under copyright are not granted by this license; seek
separate permission from the relevant rights holder. The full license, including
its exceptions and limitations, governs.

Third-party code, assets, and dependencies retain their own licenses. This notice
does not replace those licenses or restrict rights they independently grant.

External components such as scrcpy and libusb remain subject to their respective
licenses; they are not relicensed by this repository.

## Acknowledgments

Documentation and publication preparation assisted by OpenAI Codex.

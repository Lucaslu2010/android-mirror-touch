# Android USB Raw Touch Plan

## Goal

Build a macOS-hosted tool that makes a stock Android device receive real touch-class input over USB, using Android Open Accessory 2.0 HID support rather than ADB swipe commands or mouse emulation.

This plan is for legitimate device control, testing, and accessibility-style automation. It does not attempt to hide automation from apps or anti-cheat systems.

## Why this path

The strongest stock-Android path is:

1. USB connection from Mac to Android
2. Switch the Android device into AOA accessory mode
3. Register a HID device over AOA
4. Present that HID device as a touch digitizer
5. Send HID reports for contact down, move, and up

Android's AOA 2.0 spec explicitly supports HID registration and event delivery. Unlike `adb shell input swipe`, this can enter the input pipeline as HID-originated device input.

## What "raw touch" means here

The practical target is not kernel-level secret injection. The target is:

- Android sees a new external HID touch device
- InputReader/InputDispatcher classify it as touch input
- Apps receive touch events sourced from that HID device

If Android classifies the descriptor as a mouse, we fail.
If Android classifies it as a touchscreen or touch digitizer, we win.

## Architecture

### 1. macOS host app

Responsibilities:

- Detect Android USB device with `libusb`
- Read protocol version
- Switch into AOA accessory mode if needed
- Re-enumerate and reconnect after mode switch
- Register one HID device with a stable accessory HID ID
- Upload the HID report descriptor in chunks
- Send HID event reports for touch contact updates
- Provide a local API:
  - `touchDown(id, x, y)`
  - `touchMove(id, x, y)`
  - `touchUp(id)`
  - later: multi-touch variants

Recommended implementation:

- Core app in Swift or SwiftUI if we want UI
- Low-level USB transport in C or Objective-C wrapper over `libusb`
- Keep the HID report builder in plain C or Swift for easy debugging

### 2. Android device behavior

Expected flow:

- User enables USB accessory acceptance if prompted
- Android switches from normal USB mode to AOA accessory mode
- Android exposes the AOA vendor/product IDs
- Host registers HID descriptor and sends reports
- Android input stack creates an external input device

### 3. HID device model

Start with a single-contact touch digitizer, not multi-touch.

Why:

- Much easier to debug classification
- Enough to prove whether Android accepts touch-class HID over AOA
- Easier to inspect with `getevent`, `dumpsys input`, or app-side motion logging

After single-touch works, add:

- contact IDs
- tip switch/contact validity
- pressure if needed
- multi-touch collections

## Milestones

### Milestone 1: AOA transport only

Deliverable:

- macOS CLI can detect Android device
- query AOA version
- send identifying strings
- switch device into accessory mode

Success criteria:

- device disconnects and reconnects in AOA mode
- host can reconnect to the new USB identity

### Milestone 2: HID keyboard sanity check

Deliverable:

- register a known-good HID keyboard descriptor
- send a simple keypress report

Why this matters:

- separates USB/AOA bugs from touch descriptor bugs
- proves our HID registration path is correct before debugging digitizer semantics

Success criteria:

- Android receives keyboard events from the accessory

### Milestone 3: Single-touch HID descriptor

Deliverable:

- replace keyboard descriptor with a touch digitizer descriptor
- send contact down/move/up reports

Success criteria:

- Android creates a touch-class input device
- an event viewer app or test harness sees touch motion, not mouse motion

### Milestone 4: Coordinate calibration

Deliverable:

- map host coordinate space to Android logical display coordinates
- support portrait/landscape rotation
- normalize to descriptor coordinate range

Success criteria:

- touch lands within a few pixels of expected target locations

### Milestone 5: Multi-touch

Deliverable:

- two or more simultaneous contacts
- stable tracking IDs or contact IDs

Success criteria:

- pinch or two-finger gestures work in a test app

## Descriptor strategy

This is the highest-risk part.

We need a HID report descriptor that Android interprets as touch. The likely families to test are:

- touchscreen
- touch digitizer
- touch pad

Preferred order:

1. Single-touch digitizer descriptor
2. Single-touch touchscreen descriptor
3. Minimal multi-touch descriptor if Android ignores the simpler forms

Important fields to get right:

- Usage Page
- Usage
- Tip Switch
- In Range or contact-valid equivalent if needed
- X and Y logical range
- report size and count
- report ID if used

The wrong descriptor will often still "work," but only as pointer or mouse input.

## Debugging plan

### On macOS

- log all control transfers
- hex dump descriptor chunks
- hex dump outbound HID reports
- expose a test command like:
  - `aoa-touch tap 500 900`
  - `aoa-touch drag 300 700 800 700 500ms`

### On Android

Use at least one of:

- `adb shell getevent -lt`
- `adb shell dumpsys input`
- a small debug APK that logs `MotionEvent` source, tool type, pointer count, action, and coordinates

What we want to see:

- source consistent with touch, not mouse
- tool type `finger` if available
- `ACTION_DOWN`, `ACTION_MOVE`, `ACTION_UP`

What would indicate failure:

- hover or pointer events only
- source reported as mouse
- Android never creates a new input device

## Risks

### 1. Android classification risk

AOA HID transport may work while the touch descriptor is still classified as mouse-like or unsupported on some devices.

Mitigation:

- start with a known-good keyboard HID test
- test multiple descriptor variants
- validate on more than one Android device/vendor if possible

### 2. Vendor ROM differences

Samsung, Xiaomi, OnePlus, and others may classify external HID touch differently.

Mitigation:

- begin on a Pixel or near-AOSP device if available
- keep descriptor variants configurable

### 3. USB mode friction

Some devices or cables behave badly during AOA mode switching.

Mitigation:

- use a known-good data cable
- build robust reconnect logic
- surface USB state clearly in the host app

### 4. App-specific behavior

Even if Android receives touch-class input, a specific app may still behave differently from direct panel touch.

Mitigation:

- test first in a simple touch visualizer app
- then in a browser or drawing app
- only then in the target app

## Recommended build order

1. Build a tiny CLI, not a full GUI
2. Implement AOA detection and mode switch
3. Prove HID keyboard injection
4. Add single-touch descriptor and reports
5. Build a tiny Android debug app to inspect received events
6. Only after that, wrap it in a nicer macOS UI

## Concrete first prototype

Target binary:

- `tools/aoa-touch`

Commands:

- `aoa-touch probe`
- `aoa-touch enter-accessory`
- `aoa-touch keyboard-test`
- `aoa-touch touch-test --down 300 500`
- `aoa-touch touch-test --move 600 500`
- `aoa-touch touch-test --up`
- `aoa-touch drag 300 500 900 500 --duration 0.4`

## What I would build next

If we continue in this repo, the first implementation should be:

1. a small `libusb` transport wrapper
2. an AOA command layer
3. a keyboard HID smoke test
4. a descriptor-pluggable HID sender

That gives us a real proof point quickly. If keyboard works but touch does not, we know the transport is healthy and can focus entirely on the descriptor and report format.

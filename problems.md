# Spike Problem Analysis

## Status: multitouch implemented, spike needs re-testing

---

## What was changed (this session)

### 1. Multitouch HID descriptor (HID.swift)
Replaced single-finger 8-byte report with a **10-finger multitouch descriptor** (62-byte report). The descriptor has 10 Finger collections inside the Touch Screen Application collection, matching what Android's `hid-multitouch.c` driver expects for `MT_CLS_WIN_8` devices.

Key change: the Linux kernel's HID multitouch driver applies `MT_QUIRK_SLOT_IS_CONTACTID` and `MT_QUIRK_CONTACT_CNT_ACCURATE` to Touch Screen devices. With the old single-finger descriptor, the kernel might not have classified the device as a proper multitouch device at all.

### 2. TouchInputService rewritten for multitouch
- Tracks multiple simultaneous contacts with finger-slot allocation
- `beginDrag`/`moveDrag`/`endDrag` convenience API preserved (backward compatible)
- New `beginContact`/`moveContact`/`endContact` API for future multi-finger gestures
- `releaseContact` sends UP + EMPTY reports (same protocol as before, but through the multitouch report format)

### 3. Coordinate pipeline fixes (AndroidMirrorView.swift)
From previous session:
- Snapshot is now `bounds.size` only (not window-space rect)
- `convert(event.locationInWindow, from: nil)` for live local coordinates
- Removed `jump <= 0.35` discontinuity guard (was rejecting valid fast movements)
- Removed stale `bounds.minX/minY` subtraction

### 4. AOA diagnostic logging (TouchInputService.swift, AndroidMirrorModel.swift)
- `moveDrag`: logs `SLOW MOVE` if USB transfer takes > 3ms
- `beginDrag`: logs `SLOW BEGIN` if total begin time (including endDrag sleep) takes > 3ms
- `endDrag`: logs `releaseMs` timing
- `sendDirectMouseMove`: logs `usbMs` for each USB transfer

---

## What to look for in logs after re-testing

The touch log is at `.build/android-mirror-logs/touch-input.log`.

**If spikes are GONE**: The old single-finger descriptor wasn't being classified as a proper multitouch device by the kernel. The new 10-finger descriptor fixed it.

**If spikes still happen with `SLOW MOVE` entries**: USB control transfers are stalling. The Android device is intermittently slow to ACK HID reports. Need to add async USB or throttle the send rate.

**If spikes happen with `releaseMs=~16` appearing mid-drag**: `endDrag` is being called unexpectedly during a drag (shouldn't happen in direct touch mode).

**If spikes happen with normal timing**: The coordinate pipeline still has an issue. Check the `local=` / `normalized=` values in the view-layer log for discontinuities.

---

## Backup files
- `AndroidMirrorView.swift.bak`
- `AndroidMirrorModel.swift.bak`

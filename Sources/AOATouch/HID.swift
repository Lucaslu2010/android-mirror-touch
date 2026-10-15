import Foundation

enum HID {
    // MARK: - Keyboard (unchanged)

    static let keyboardDescriptor: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xa1, 0x01,       // Collection (Application)
        0x05, 0x07,       // Usage Page (Keyboard)
        0x19, 0xe0,       // Usage Minimum (Left Control)
        0x29, 0xe7,       // Usage Maximum (Right GUI)
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x08,
        0x81, 0x02,       // Input (Data, Variable, Absolute)
        0x95, 0x01,
        0x75, 0x08,
        0x81, 0x01,       // Input (Constant)
        0x95, 0x06,
        0x75, 0x08,
        0x15, 0x00,
        0x25, 0x65,
        0x05, 0x07,
        0x19, 0x00,
        0x29, 0x65,
        0x81, 0x00,       // Input (Data, Array)
        0xc0
    ]

    // MARK: - Touch (hybrid multitouch, up to 10 fingers)

    /// Maximum number of simultaneous touch contacts.
    static let maxFingers = 10

    /// Hybrid multitouch reports one Finger collection per packet. The first
    /// packet in a frame carries the total Contact Count; continuation packets
    /// carry zero. Contact Count Maximum still advertises ten concurrent
    /// contacts to Android.
    static let touchDescriptor: [UInt8] = {
        var d: [UInt8] = []

        // -- Application collection ----------------------------------------
        d += [0x05, 0x0d]                     // Usage Page (Digitizers)
        d += [0x09, 0x04]                     // Usage (Touch Screen)
        d += [0xa1, 0x01]                     // Collection (Application)
        d += [0x85, 0x01]                     //   Report ID (1)

        // -- One contact per packet ----------------------------------------
        d += [0x09, 0x22]                     //   Usage (Finger)
        d += [0xa1, 0x02]                     //   Collection (Logical)
        d += [0x09, 0x42]                     //     Usage (Tip Switch)
        d += [0x09, 0x32]                     //     Usage (In Range)
        d += [0x15, 0x00]
        d += [0x25, 0x01]
        d += [0x75, 0x01]
        d += [0x95, 0x02]
        d += [0x81, 0x02]
        d += [0x75, 0x06]
        d += [0x95, 0x01]
        d += [0x81, 0x03]
        d += [0x09, 0x51]                     //     Contact Identifier
        d += [0x15, 0x00]
        d += [0x25, 0x09]
        d += [0x75, 0x08]
        d += [0x95, 0x01]
        d += [0x81, 0x02]
        d += [0x05, 0x01]
        d += [0x09, 0x30]
        d += [0x09, 0x31]
        d += [0x16, 0x00, 0x00]
        d += [0x26, 0xff, 0x7f]
        d += [0x75, 0x10]
        d += [0x95, 0x02]
        d += [0x81, 0x02]
        d += [0xc0]                           //   End Collection (Logical)

        // -- Contact Count (outside Finger collections) --------------------
        d += [0x05, 0x0d]                     //   Usage Page (Digitizers)
        d += [0x09, 0x54]                     //   Usage (Contact Count)
        d += [0x15, 0x00]                     //   Logical Minimum (0)
        d += [0x25, UInt8(maxFingers)]        //   Logical Maximum (10)
        d += [0x75, 0x08]                     //   Report Size (8)
        d += [0x95, 0x01]                     //   Report Count (1)
        d += [0x81, 0x02]                     //   Input (Data, Variable, Absolute)

        // -- Contact Count Maximum (Feature report) ------------------------
        d += [0x85, 0x02]                     //   Report ID (2)
        d += [0x09, 0x55]                     //   Usage (Contact Count Maximum)
        d += [0x15, 0x00]                     //   Logical Minimum (0)
        d += [0x25, UInt8(maxFingers)]        //   Logical Maximum (10)
        d += [0x75, 0x08]                     //   Report Size (8)
        d += [0x95, 0x01]                     //   Report Count (1)
        d += [0xb1, 0x02]                     //   Feature (Data, Variable, Absolute)

        d += [0xc0]                           // End Collection (Application)
        return d
    }()

    // MARK: - Touch report builder

    /// Builds one 8-byte contact packet (Report ID 1).
    ///
    /// Layout (all little-endian):
    /// ```
    ///  byte  0       report ID (0x01)
    ///  bytes 1..6    {flags, contactID, x_lo, x_hi, y_lo, y_hi}
    ///  byte  7       contact count (total on first packet, zero thereafter)
    /// ```
    static func touchReport(
        fingerIndex: Int = 0,
        down: Bool,
        x: UInt16,
        y: UInt16,
        contactID: UInt8 = 0,
        contactCount: UInt8 = 1
    ) -> [UInt8] {
        precondition(fingerIndex >= 0 && fingerIndex < maxFingers)
        let reportSize = 8
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = 0x01
        report[1] = down ? 0x03 : 0x00
        report[2] = contactID
        report[3] = UInt8(truncatingIfNeeded: x)
        report[4] = UInt8(truncatingIfNeeded: x >> 8)
        report[5] = UInt8(truncatingIfNeeded: y)
        report[6] = UInt8(truncatingIfNeeded: y >> 8)
        report[7] = contactCount
        return report
    }
}

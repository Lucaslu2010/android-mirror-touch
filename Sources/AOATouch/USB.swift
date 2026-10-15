import CLibUSB
import Foundation

struct USBDeviceInfo {
    let bus: UInt8
    let address: UInt8
    let vendorID: UInt16
    let productID: UInt16

    var identifier: String {
        String(format: "%03d:%03d %04x:%04x", bus, address, vendorID, productID)
    }

    var isAccessoryMode: Bool {
        vendorID == AOA.googleVendorID && AOA.accessoryProductIDs.contains(productID)
    }
}

final class USBContext {
    private var context: OpaquePointer?

    init() throws {
        try requireUSB(libusb_init(&context), "libusb_init")
    }

    deinit {
        libusb_exit(context)
    }

    func devices() throws -> [USBDeviceInfo] {
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count >= 0 else {
            throw AOAError.libusb(operation: "libusb_get_device_list", code: Int32(count))
        }
        defer { libusb_free_device_list(list, 1) }

        var result: [USBDeviceInfo] = []
        for index in 0..<Int(count) {
            guard let device = list?[index] else { continue }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
            result.append(USBDeviceInfo(
                bus: libusb_get_bus_number(device),
                address: libusb_get_device_address(device),
                vendorID: descriptor.idVendor,
                productID: descriptor.idProduct
            ))
        }
        return result
    }

    func openFirstAccessory() throws -> USBHandle {
        let matches = try devices().filter(\.isAccessoryMode)
        guard let info = matches.first else {
            throw AOAError.noDevice("No Android device in AOA accessory mode was found. Run `aoa-touch start` first.")
        }
        return try open(info)
    }

    func openFirstAOACapable() throws -> (USBHandle, USBDeviceInfo, UInt16) {
        for info in try devices() where !info.isAccessoryMode {
            guard let handle = try? open(info), let version = try? handle.aoaProtocolVersion() else {
                continue
            }
            return (handle, info, version)
        }
        throw AOAError.noDevice("No AOA-capable Android device was found. Unlock it and use a USB data cable.")
    }

    private func open(_ info: USBDeviceInfo) throws -> USBHandle {
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count >= 0 else {
            throw AOAError.libusb(operation: "libusb_get_device_list", code: Int32(count))
        }
        defer { libusb_free_device_list(list, 1) }

        for index in 0..<Int(count) {
            guard let device = list?[index],
                  libusb_get_bus_number(device) == info.bus,
                  libusb_get_device_address(device) == info.address else { continue }
            var handle: OpaquePointer?
            try requireUSB(libusb_open(device, &handle), "libusb_open \(info.identifier)")
            guard let handle else {
                throw AOAError.noDevice("libusb returned an empty handle for \(info.identifier).")
            }
            return USBHandle(handle: handle, info: info)
        }
        throw AOAError.noDevice("USB device \(info.identifier) disappeared before it could be opened.")
    }
}

final class USBHandle {
    private let handle: OpaquePointer
    let info: USBDeviceInfo

    init(handle: OpaquePointer, info: USBDeviceInfo) {
        self.handle = handle
        self.info = info
    }

    deinit {
        libusb_close(handle)
    }

    func controlIn(request: UInt8, value: UInt16 = 0, index: UInt16 = 0, length: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let transferred = bytes.withUnsafeMutableBytes { rawBuffer in
            libusb_control_transfer(
                handle,
                UInt8(LIBUSB_ENDPOINT_IN.rawValue | LIBUSB_REQUEST_TYPE_VENDOR.rawValue),
                request,
                value,
                index,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                UInt16(length),
                AOA.controlTimeoutMS
            )
        }
        try requireUSB(transferred, "USB control IN request \(request)")
        return Array(bytes.prefix(Int(transferred)))
    }

    func controlOut(request: UInt8, value: UInt16 = 0, index: UInt16 = 0, bytes: [UInt8] = []) throws {
        var mutableBytes = bytes
        let transferred = mutableBytes.withUnsafeMutableBytes { rawBuffer in
            libusb_control_transfer(
                handle,
                UInt8(LIBUSB_ENDPOINT_OUT.rawValue | LIBUSB_REQUEST_TYPE_VENDOR.rawValue),
                request,
                value,
                index,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                UInt16(bytes.count),
                AOA.controlTimeoutMS
            )
        }
        try requireUSB(transferred, "USB control OUT request \(request)")
        guard transferred == bytes.count else {
            throw AOAError.noDevice("Short USB control transfer: sent \(transferred) of \(bytes.count) bytes.")
        }
    }
}

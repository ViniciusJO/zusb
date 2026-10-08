const clibusb = @import("libusb");
const Direction = @import("fields.zig").Direction;
const TransferType = @import("fields.zig").TransferType;

const Self = @This();

descriptor: *const clibusb.libusb_endpoint_descriptor,

pub fn direction(self: Self) Direction {
    return switch (self.descriptor.*.bEndpointAddress & clibusb.LIBUSB_ENDPOINT_DIR_MASK) {
        clibusb.LIBUSB_ENDPOINT_OUT => Direction.Out,
        clibusb.LIBUSB_ENDPOINT_IN => Direction.In,
        else => Direction.In,
    };
}

pub fn transferType(self: Self) TransferType {
    return switch (self.descriptor.*.bmAttributes & clibusb.LIBUSB_TRANSFER_TYPE_MASK) {
        clibusb.LIBUSB_TRANSFER_TYPE_CONTROL => TransferType.Control,
        clibusb.LIBUSB_TRANSFER_TYPE_ISOCHRONOUS => TransferType.Isochronous,
        clibusb.LIBUSB_TRANSFER_TYPE_BULK => TransferType.Bulk,
        clibusb.LIBUSB_TRANSFER_TYPE_INTERRUPT => TransferType.Interrupt,
        else => TransferType.Interrupt,
    };
}

pub fn number(self: Self) u8 {
    return self.descriptor.*.bEndpointAddress & 0x07;
}

pub fn address(self: Self) u8 {
    return self.descriptor.*.bEndpointAddress;
}

pub fn interval(self: Self) u8 {
    return self.descriptor.*.bInterval;
}

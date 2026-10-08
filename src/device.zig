const clibusb = @import("libusb");
const ConfigDescriptor = @import("config_descriptor.zig");
const Context = @import("context.zig");
const DeviceDescriptor = @import("device_descriptor.zig");
const DeviceHandle = @import("device_handle.zig");
const fromLibusb = @import("constructor.zig").fromLibusb;

const err = @import("error.zig");

const Self = @This();

ctx: *Context,
raw: *clibusb.libusb_device,

pub fn deinit(self: Self) void {
    _ = clibusb.libusb_unref_device(self.raw);
}

pub fn deviceDescriptor(self: Self) err.Error!DeviceDescriptor {
    var descriptor: clibusb.libusb_device_descriptor = undefined;

    try err.failable(clibusb.libusb_get_device_descriptor(
        self.raw,
        &descriptor,
    ));

    return DeviceDescriptor{ .descriptor = descriptor };
}

pub fn configDescriptor(self: Self, config_index: u8) err.Error!ConfigDescriptor {
    var descriptor: ?*clibusb.libusb_config_descriptor = null;

    try err.failable(clibusb.libusb_get_config_descriptor(
        self.raw,
        config_index,
        &descriptor,
    ));

    return ConfigDescriptor{ .descriptor = descriptor.? };
}

pub fn busNumber(self: Self) u8 {
    return clibusb.libusb_get_bus_number(self.raw);
}

pub fn portNumber(self: Self) u8 {
    return clibusb.libusb_get_port_number(self.raw);
}

pub fn address(self: Self) u8 {
    return clibusb.libusb_get_device_address(self.raw);
}

pub fn open(self: Self) err.Error!DeviceHandle {
    var handle: ?*clibusb.libusb_device_handle = null;
    try err.failable(clibusb.libusb_open(self.raw, &handle));

    return fromLibusb(DeviceHandle, .{ self.ctx, handle.? });
}

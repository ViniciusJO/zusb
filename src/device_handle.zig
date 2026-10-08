const clibusb = @import("libusb");
const std = @import("std");
const Context = @import("context.zig");
const Device = @import("device.zig");
const fromLibusb = @import("constructor.zig").fromLibusb;

const err = @import("error.zig");

const Self = @This();

ctx: *Context,
raw: *clibusb.libusb_device_handle,
interfaces: u256,

pub fn deinit(self: *Self) void {
    var iface: u9 = 0;
    while (iface < 256) : (iface += 1) {
        if ((self.interfaces & (@as(u256, 1) << @truncate(iface))) != 0) {
            _ = clibusb.libusb_release_interface(self.raw, @as(c_int, iface));
        }
    }
    clibusb.libusb_close(self.raw);
}

pub fn claimInterface(self: *Self, iface: u8) err.Error!void {
    if (clibusb.libusb_kernel_driver_active(self.raw, @as(c_int, iface)) == 1) {
        try err.failable(clibusb.libusb_detach_kernel_driver(self.raw, @as(c_int, iface)));
    }
    try err.failable(clibusb.libusb_claim_interface(self.raw, @as(c_int, iface)));
    self.interfaces |= @as(u256, 1) << iface;
}

pub fn releaseInterface(self: *Self, iface: u8) err.Error!void {
    try err.failable(clibusb.libusb_release_interface(self.raw, @as(c_int, iface)));
    self.interfaces &= ~(@as(u256, 1) << iface);
}

pub fn device(self: *Self) Device {
    return fromLibusb(Device, .{ self.ctx, clibusb.libusb_get_device(self.raw).? });
}

pub fn setInterfaceAltSetting(self: *Self, iface: u8, setting: u8) err.Error!void {
    try err.failable(clibusb.libusb_set_interface_alt_setting(self.raw, @as(c_int, iface), @as(c_int, setting)));
}

pub fn writeControl(
    self: *Self,
    requestType: u8,
    request: u8,
    value: u16,
    index: u16,
    buf: ?[]const u8,
    timeout_ms: u64,
) (error{Overflow} || err.Error)!usize {
    if (requestType & clibusb.LIBUSB_ENDPOINT_DIR_MASK != clibusb.LIBUSB_ENDPOINT_OUT) {
        return error.InvalidParam;
    }

    const res = if (buf != null)
        clibusb.libusb_control_transfer(
            self.raw,
            requestType,
            request,
            value,
            index,
            @constCast(buf.?.ptr),
            std.math.cast(u16, buf.?.len) orelse return error.Overflow,
            std.math.cast(c_uint, timeout_ms) orelse return error.Overflow,
        )
    else
        clibusb.libusb_control_transfer(
            self.raw,
            requestType,
            request,
            value,
            index,
            null,
            0,
            std.math.cast(c_uint, timeout_ms) orelse return error.Overflow,
        );

    if (res < 0) {
        return err.errorFromLibusb(res);
    } else {
        return @intCast(res);
    }
}

pub fn readBulk(
    self: *Self,
    endpoint: u8,
    buf: []u8,
    timeout_ms: u64,
) (error{Overflow} || err.Error)!usize {
    if (endpoint & clibusb.LIBUSB_ENDPOINT_DIR_MASK != clibusb.LIBUSB_ENDPOINT_IN) {
        return error.InvalidParam;
    }

    var transferred: c_int = 0;

    const ret = clibusb.libusb_bulk_transfer(
        self.raw,
        endpoint,
        buf.ptr,
        std.math.cast(c_int, buf.len) orelse return error.Overflow,
        &transferred,
        std.math.cast(c_uint, timeout_ms) orelse return error.Overflow,
    );

    if (ret == 0 or (ret == clibusb.LIBUSB_ERROR_TIMEOUT and transferred > 0)) {
        return @intCast(transferred);
    } else {
        return err.errorFromLibusb(ret);
    }
}

pub fn writeBulk(
    self: *Self,
    endpoint: u8,
    buf: []const u8,
    timeout_ms: u64,
) (error{Overflow} || err.Error)!usize {
    if (endpoint & clibusb.LIBUSB_ENDPOINT_DIR_MASK != clibusb.LIBUSB_ENDPOINT_OUT) {
        return error.InvalidParam;
    }

    var transferred: c_int = 0;

    const ret = clibusb.libusb_bulk_transfer(
        self.raw,
        endpoint,
        @constCast(buf.ptr),
        std.math.cast(c_int, buf.len) orelse return error.Overflow,
        &transferred,
        std.math.cast(c_uint, timeout_ms) orelse return error.Overflow,
    );

    if (ret == 0 or (ret == clibusb.LIBUSB_ERROR_TIMEOUT and transferred > 0)) {
        return @intCast(transferred);
    } else {
        return err.errorFromLibusb(ret);
    }
}

const clibusb = @import("libusb");
const std = @import("std");
const Context = @import("context.zig");
const Device = @import("device.zig");
const fromLibusb = @import("constructor.zig").fromLibusb;

const err = @import("error.zig");

pub const Devices = struct {
    ctx: *Context,
    devices: []?*clibusb.libusb_device,
    i: usize,

    pub fn next(self: *Devices) ?Device {
        if (self.i < self.devices.len) {
            defer self.i += 1;
            return fromLibusb(Device, .{ self.ctx, self.devices[self.i].? });
        } else {
            return null;
        }
    }
};

const Self = @This();

ctx: *Context,
list: [*c]?*clibusb.libusb_device,
len: usize,

pub fn init(ctx: *Context) err.Error!Self {
    var list: [*c]?*clibusb.libusb_device = undefined;
    const n = clibusb.libusb_get_device_list(ctx.raw, &list);

    if (n < 0) {
        return err.errorFromLibusb(@intCast(n));
    } else {
        return Self{
            .ctx = ctx,
            .list = list,
            .len = @intCast(n),
        };
    }
}

pub fn deinit(self: Self) void {
    clibusb.libusb_free_device_list(self.list, 1);
}

pub fn devices(self: Self) Devices {
    return Devices{
        .ctx = self.ctx,
        .devices = self.list[0..self.len],
        .i = 0,
    };
}

const clibusb = @import("libusb");
const std = @import("std");
const Interface = @import("interface_descriptor.zig");

const Self = @This();

descriptor: *clibusb.libusb_config_descriptor,

pub fn deinit(self: Self) void {
    _ = clibusb.libusb_free_config_descriptor(self.descriptor);
}

pub fn interfaces(self: Self) Interfaces {
    return Interfaces{
        .interfaces = self.descriptor.*.interface[0..self.descriptor.*.bNumInterfaces],
        .i = 0,
    };
}

pub const Interfaces = struct {
    interfaces: []const clibusb.libusb_interface,
    i: usize,

    pub fn next(self: *Interfaces) ?Interface {
        if (self.i < self.interfaces.len) {
            defer self.i += 1;

            const len: usize = @intCast(self.interfaces[self.i].num_altsetting);

            return Interface{
                .iter = self.interfaces[self.i].altsetting[0..len],
            };
        } else {
            return null;
        }
    }
};

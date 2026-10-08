const clibusb = @import("libusb");
const std = @import("std");
const Device = @import("device.zig");

pub fn fromLibusb(comptime T: type, args: anytype) T {
    switch (T) {
        Device => {
            _ = clibusb.libusb_ref_device(args.@"1");
            return .{
                .ctx = args.@"0",
                .raw = args.@"1",
            };
        },
        Device.Handle => {
            return .{
                .ctx = args.@"0",
                .raw = args.@"1",
                .interfaces = 0,
            };
        },
        else => {
            @compileError("Unsupported type");
        },
    }
}

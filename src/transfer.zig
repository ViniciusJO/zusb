const clibusb = @import("libusb");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Device = @import("device.zig");
const PacketDescriptor = @import("packet_descriptor.zig").PacketDescriptor;
const PacketDescriptors = @import("packet_descriptor.zig").PacketDescriptors;

const err = @import("error.zig");

/// WIP
pub fn Transfer(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        buf: []u8,
        transfer: *clibusb.libusb_transfer,
        callback: *const fn (*T, []const u8) void,
        user_data: *T,
        active: bool,
        should_resubmit: bool = true,

        pub fn deinit(self: *const Self) void {
            clibusb.libusb_free_transfer(self.transfer);
            self.allocator.free(self.buf);
            self.allocator.destroy(self);
        }

        pub fn submit(self: *Self) err.Error!void {
            if (!self.should_resubmit) {
                return;
            }
            self.active = true;
            try err.failable(clibusb.libusb_submit_transfer(self.transfer));
        }

        pub fn cancel(self: *Self) err.Error!void {
            self.should_resubmit = false;
            try err.failable(clibusb.libusb_cancel_transfer(self.transfer));
        }

        pub fn buffer(self: Self) []u8 {
            const length = std.math.cast(usize, self.transfer.length) orelse @panic("Buffer length too large");
            return self.transfer.buffer[0..length];
        }

        pub fn isActive(self: Self) bool {
            return self.active;
        }

        pub fn fillIsochronous(
            allocator: Allocator,
            handle: *Device.Handle,
            endpoint: u8,
            packet_size: u16,
            num_packets: u16,
            callback: *const fn (*T, []const u8) void,
            user_data: *T,
            timeout: u64,
        ) !*Self {
            const buf = try allocator.alloc(u8, packet_size * num_packets);
            const opt_transfer: ?*clibusb.libusb_transfer = clibusb.libusb_alloc_transfer(num_packets);

            if (opt_transfer) |transfer| {
                const self = try allocator.create(Self);
                self.* = .{
                    .allocator = allocator,
                    .transfer = transfer,
                    .callback = callback,
                    .user_data = user_data,
                    .buf = buf,
                    .active = true,
                };

                transfer.*.dev_handle = handle.raw;
                transfer.*.endpoint = endpoint;
                transfer.*.type = clibusb.LIBUSB_TRANSFER_TYPE_ISOCHRONOUS;
                transfer.*.buffer = buf.ptr;
                transfer.*.length = std.math.cast(c_int, buf.len) orelse @panic("Length too large");
                transfer.*.num_iso_packets = std.math.cast(c_int, num_packets) orelse @panic("Number of packets too large");
                transfer.*.callback = callbackRawIso;
                transfer.*.user_data = @ptrCast(self);
                transfer.*.timeout = std.math.cast(c_uint, timeout) orelse @panic("Timeout too large");

                clibusb.libusb_set_iso_packet_lengths(transfer, packet_size);

                return self;
            } else {
                return error.OutOfMemory;
            }
        }

        export fn callbackRawIso(transfer: [*c]clibusb.libusb_transfer) void {
            const self: *Self = @alignCast(@ptrCast(transfer.*.user_data.?));
            self.active = false;
            if (transfer.*.status != clibusb.LIBUSB_TRANSFER_COMPLETED) {
                return;
            }
            const num_iso_packets: usize = @intCast(transfer.*.num_iso_packets);
            var isoPackets = PacketDescriptors.init(transfer, transfer.*.iso_packet_desc()[0..num_iso_packets]);
            while (isoPackets.next()) |pack| {
                if (!pack.isCompleted()) {
                    std.log.info("Isochronous transfer failed, status: {}", .{pack.status()});
                    continue;
                }
                self.callback(self.user_data, pack.buffer());
            }
            self.submit() catch |e| std.log.err("Failed to resubmit isochronous transfer: {}", .{e});
        }

        pub fn fillInterrupt(
            allocator: *Allocator,
            handle: *Device.Handle,
            endpoint: u8,
            buffer_size: usize,
            callback: fn (*Self) void,
            user_data: T,
            timeout: u64,
        ) (Allocator.err.Error || err.Error)!*Self {
            const buf = try allocator.alloc(u8, buffer_size);

            const opt_transfer: ?*clibusb.libusb_transfer = clibusb.libusb_alloc_transfer(0);

            if (opt_transfer) |transfer| {
                transfer.*.dev_handle = handle.handle;
                transfer.*.endpoint = endpoint;
                transfer.*.type = clibusb.LIBUSB_TRANSFER_TYPE_INTERRUPT;
                transfer.*.timeout = std.math.cast(c_uint, timeout) orelse @panic("Timeout too large");
                transfer.*.buffer = buf.ptr;
                transfer.*.length = std.math.cast(c_int, buf.len) orelse @panic("Length too large");
                transfer.*.callback = callbackRaw;

                const self = try allocator.create(Self);
                self.* = .{
                    .allocator = allocator,
                    .transfer = transfer,
                    .user_data = user_data,
                    .buf = buf,
                    .callback = callback,
                    .active = true,
                };

                return self;
            } else {
                return error.OutOfMemory;
            }
        }

        export fn callbackRaw(transfer: [*c]clibusb.libusb_transfer) void {
            const self: *Self = @alignCast(@ptrCast(transfer.*.user_data.?));
            self.callback(self.user_data, self.buffer());
        }
    };
}

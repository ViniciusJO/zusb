pub const ConfigDescriptor = @import("src/config_descriptor.zig");
pub const Constants = @import("src/constants.zig");
pub const Context = @import("src/context.zig");
pub const Device = @import("src/device.zig");
pub const EndpointDescriptor = @import("src/endpoint_descriptor.zig");
pub const Fields = @import("src/fields.zig");
pub const InterfaceDescriptor = @import("src/interface_descriptor.zig");
pub const Transfer = @import("src/transfer.zig").Transfer;
pub const PacketDescriptor = @import("src/packet_descriptor.zig");
const ErrorMod = @import("src/error.zig");

pub const Error = ErrorMod.Error;
pub const failable = ErrorMod.failable;
pub const errorFromLibusb = ErrorMod.errorFromLibusb;

comptime {
    @import("std").testing.refAllDecls(@This());
}

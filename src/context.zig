const clibusb = @import("libusb");
const DeviceHandle = @import("device_handle.zig");
const DeviceList = @import("device_list.zig");
const fromLibusb = @import("constructor.zig").fromLibusb;

const err = @import("error.zig");

const Self = @This();

raw: *clibusb.libusb_context,

pub fn init() err.Error!Self {
    var ctx: ?*clibusb.libusb_context = null;
    try err.failable(clibusb.libusb_init(&ctx));

    return Self{ .raw = ctx.? };
}

pub fn deinit(self: Self) void {
    _ = clibusb.libusb_exit(self.raw);
}

pub fn devices(self: *Self) err.Error!DeviceList {
    return DeviceList.init(self);
}

pub fn handleEvents(self: Self) err.Error!void {
    try err.failable(clibusb.libusb_handle_events_completed(self.raw, null));
}

pub fn openDeviceWithFd(self: *Self, fd: isize) err.Error!DeviceHandle {
    var device_handle: *clibusb.libusb_device_handle = undefined;
    try err.failable(clibusb.libusb_wrap_sys_device(self.raw, fd, &device_handle));
    return fromLibusb(DeviceHandle, .{ self, device_handle });
}

pub fn openDeviceWithVidPid(
    self: *Self,
    vendor_id: u16,
    product_id: u16,
) err.Error!?DeviceHandle {
    if (clibusb.libusb_open_device_with_vid_pid(self.raw, vendor_id, product_id)) |handle| {
        return fromLibusb(DeviceHandle, .{ self, handle });
    } else {
        return null;
    }
}

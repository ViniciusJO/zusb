const clibusb = @import("libusb");
const err = @import("error.zig");

pub fn disableDeviceDiscovery() err.Error!void {
    try err.failable(clibusb.libusb_set_option(null, clibusb.LIBUSB_OPTION_NO_DEVICE_DISCOVERY));
}

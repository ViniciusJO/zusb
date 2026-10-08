const std = @import("std");
const zusb = @import("zusb");

// fn main() {
//     let version = rusb::version();
//
//     println!(
//         "libusb v{}.{}.{}.{}{}",
//         version.major(),
//         version.minor(),
//         version.micro(),
//         version.nano(),
//         version.rc().unwrap_or("")
//     );
//
//     let mut context = match rusb::Context::new() {
//         Ok(c) => c,
//         Err(e) => panic!("libusb::Context::new(): {}", e),
//     };
//
//     context.set_log_level(rusb::LogLevel::Debug);
//     context.set_log_level(rusb::LogLevel::Info);
//     context.set_log_level(rusb::LogLevel::Warning);
//     context.set_log_level(rusb::LogLevel::Error);
//     context.set_log_level(rusb::LogLevel::None);
//
//     println!("has capability? {}", rusb::has_capability());
//     println!("has hotplug? {}", rusb::has_hotplug());
//     println!("has HID access? {}", rusb::has_hid_access());
//     println!(
//         "supports detach kernel driver? {}",
//         rusb::supports_detach_kernel_driver()
//     )
// }

pub fn main() !void {


    var ctx = try zusb.Context.init();

    const devices = try zusb.DeviceList.init(&ctx);
    defer devices.deinit();

    var devices_list = devices.devices();
    while(devices_list.next()) |device| {
        const device_descriptor = try device.deviceDescriptor();
        std.log.info("Bus {} Device {} ID {}:{} Port {}", .{
            device.busNumber(),
            device.address(),
            device_descriptor.vendorId(),
            device_descriptor.productId(),
            device.portNumber(),
        });

    }
}

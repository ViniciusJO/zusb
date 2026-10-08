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
    defer ctx.deinit();

    const devices = try zusb.Device.List.init(&ctx);
    defer devices.deinit();

    var devices_list = devices.devices();
    while(devices_list.next()) |device| {
        defer device.deinit();

        const device_descriptor = try device.deviceDescriptor();
        std.log.info("Bus {} Device {} ID {}:{} Port {}", .{
            device.busNumber(),
            device.address(),
            device_descriptor.vendorId(),
            device_descriptor.productId(),
            device.portNumber(),
        });

        const config = try device.configDescriptor(0);
        defer config.deinit();

        var interfaces = config.interfaces();
        while (interfaces.next()) |interface| {
            var alt_settings = interface.descriptors();
            while (alt_settings.next()) |alt| {
                if (alt.descriptor.bNumEndpoints == 0) continue;

                var endpoints = alt.endpointDescriptors();
                while (endpoints.next()) |endpoint| {
                    std.log.info("\tinterface {d} alt {d}: endpoint 0x{x:0>2} {t} {t}", .{
                        interface.number(),
                        alt.descriptor.bAlternateSetting,
                        endpoint.address(),
                        endpoint.direction(),
                        endpoint.transferType(),
                    });
                }
            }
        }
        std.debug.print("\n", .{});

    }
}

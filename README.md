# zusb

Fork of [zusb](https://github.com/Sirius902/zusb.git) providing zig bindings for [libusb-1.0](https://libusb.info), ported from the Rust library [rusb](https://github.com/a1ien/rusb).

It gives Zig programs direct access to USB devices from user space: enumerate the bus, read descriptors, open devices, claim interfaces and run control, bulk and isochronous transfers, without writing a kernel driver.

For a detailed walkthrough of the USB protocol and how each part of it maps to this API, read **[USB.md](USB.md)**.

## Contents

- [Requirements](##requirements)
- [Installation](##installation)
- [Quick start](##quick-start)
- [Usage guide](##usage-guide)
- [Examples](##examples)
- [Tests](##tests)
- [Project layout](##project-layout)
- [API overview](##api-overview)
- [Known limitations](##known-limitations)
- [License](##license)

## Requirements

| Dependency | Version | Notes |
|---|---|---|
| Zig | 0.16.0 | |
| libusb | 1.0.22 or newer | Development headers are needed: zusb translates `libusb-1.0/libusb.h` at build time |

Installing libusb with headers:

```sh
# Arch Linux
sudo pacman -S libusb
# Debian / Ubuntu
sudo apt install libusb-1.0-0-dev
# Fedora
sudo dnf install libusb1-devel
# macOS (Homebrew)
brew install libusb
```

Check that the headers and library can be found:

```sh
pkg-config --modversion libusb-1.0
```

## Installation

### As a package dependency

Add zusb to your `build.zig.zon`, from git:

```sh
zig fetch --save git+https://github.com/ViniciusJO/zusb
```

Or from a local checkout:

```zig
// build.zig.zon
.dependencies = .{
    .zusb = .{ .path = "../zusb" },
},
```

Then import the module in your `build.zig`. libusb linking is configured by zusb's own build script and propagates to your executable:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zusb_dep = b.dependency("zusb", .{
        .target = target,
        .optimize = optimize,
    });
    const zusb_mod = zusb_dep.module("zusb");

    const exe = b.addExecutable(.{
        .name = "my_usb_tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zusb", .module = zusb_mod },
            },
        }),
    });
    b.installArtifact(exe);
}
```

Optional: to call libusb functions zusb does not wrap yet, import the very same translated libusb module zusb uses, so the C types are compatible:

```zig
const libusb_mod = zusb_mod.import_table.get("libusb").?;
exe.root_module.addImport("libusb", libusb_mod);
```

### Building this repository

```sh
zig build           # builds the original list example (example/main.zig)
zig build run       # runs it
zig build clean     # removes zig-out and .zig-cache
```

## Quick start

List every connected device:

```zig
const std = @import("std");
const zusb = @import("zusb");

pub fn main() !void {
    var ctx = try zusb.Context.init();
    defer ctx.deinit();

    const device_list = try ctx.devices();
    defer device_list.deinit();

    var devices = device_list.devices();
    while (devices.next()) |device| {
        defer device.deinit(); // each Device holds a reference

        const descriptor = try device.deviceDescriptor();
        std.debug.print("Bus {d:0>3} Device {d:0>3}: ID {x:0>4}:{x:0>4}\n", .{
            device.busNumber(),
            device.address(),
            descriptor.vendorId(),
            descriptor.productId(),
        });
    }
}
```

```
Bus 003 Device 004: ID 2b7e:c668
Bus 003 Device 003: ID 2df0:0007
Bus 001 Device 001: ID 1d6b:0002
```

## Usage guide

### Lifetimes at a glance

```
Context ──┬── Device.List ── Device (own reference, deinit it)
          │                   ├── Device.Descriptor (plain value)
          │                   ├── ConfigDescriptor (libusb memory, deinit it)
          │                   └── open() ── Device.Handle (deinit it)
          └── openDeviceWithVidPid() ──────── Device.Handle
                                                ├── claimInterface / release
                                                ├── writeControl / readBulk / writeBulk
                                                └── Transfer(T) (deinit it)
```

Release in reverse order of creation: transfers, handles, devices, configuration descriptors, device lists, and the context last.

### Reading descriptors

Descriptors are available without opening the device:

```zig
const config = try device.configDescriptor(0);
defer config.deinit();

var interfaces = config.interfaces();
while (interfaces.next()) |interface| {
    var alt_settings = interface.descriptors();
    while (alt_settings.next()) |alt| {
        if (alt.descriptor.bNumEndpoints == 0) continue;

        var endpoints = alt.endpointDescriptors();
        while (endpoints.next()) |endpoint| {
            std.debug.print("interface {d} alt {d}: endpoint 0x{x:0>2} {t} {t}\n", .{
                interface.number(),
                alt.descriptor.bAlternateSetting,
                endpoint.address(),
                endpoint.direction(),
                endpoint.transferType(),
            });
        }
    }
}
```

### Opening a device

```zig
// By vendor and product id: null when absent or not accessible.
var handle = (try ctx.openDeviceWithVidPid(0x2df0, 0x0007)) orelse
    return error.Device.NotFound;
defer handle.deinit();

// Or from a Device found while iterating.
var other = try device.open(); // error.Access without permission
defer other.deinit();
```

On Linux you need write access to `/dev/bus/usb/BBB/DDD`; see [USB.md, Permissions on Linux](USB.md#13-permissions-on-linux) for a udev rule.

### Claiming an interface

```zig
try handle.claimInterface(0);          // detaches a bound kernel driver
try handle.setInterfaceAltSetting(0, 0);
try handle.releaseInterface(0);        // deinit also releases leftovers
```

Claiming detaches the kernel driver, which takes the device (or that function of it) away from the system. To get the driver back on release:

```zig
try handle.claimAutoDeatachableInterface(0);
```

### Control transfers

```zig
// bmRequestType 0x40 = host-to-device | vendor | device
const sent = try handle.writeControl(0x40, 0x01, 0x0000, 0x0000, &.{ 0xab, 0xcd }, 1000);
```

### Bulk transfers

```zig
try handle.claimInterface(0);

_ = try handle.writeBulk(0x01, "hello", 1000); // OUT endpoint: bit 7 clear

var buffer: [512]u8 = undefined;
const read = handle.readBulk(0x81, &buffer, 1000) catch |e| switch (e) {
    error.Timeout => 0,
    else => return e,
};
std.debug.print("{x}\n", .{buffer[0..read]});
```

Endpoint direction is validated: `readBulk` on an OUT endpoint or `writeBulk` on an IN endpoint returns `error.InvalidParam` without touching the device.

### Isochronous streaming

```zig
const Counter = struct {
    bytes: usize = 0,

    fn onPacket(self: *@This(), data: []const u8) void {
        self.bytes += data.len;
    }
};

try handle.claimInterface(1);
try handle.setInterfaceAltSetting(1, 1);

var counter: Counter = .{};
const transfer = try zusb.Transfer(Counter).fillIsochronous(
    allocator, &handle, 0x81, 192, 8, Counter.onPacket, &counter, 1000,
);
defer transfer.deinit();

try transfer.submit();               // resubmits itself after each completion
for (0..1000) |_| try ctx.handleEvents();

transfer.cancel() catch {};
while (transfer.isActive()) try ctx.handleEvents();
```

### Error handling

All fallible calls return `zusb.Error` (plus `error.Overflow` for size and timeout casts on handle I/O):

```zig
var handle = device.open() catch |e| switch (e) {
    error.Access => {
        std.log.err("no permission, add a udev rule", .{});
        return e;
    },
    error.NoDevice => return, // unplugged meanwhile
    else => return e,
};
```

The full mapping from libusb codes is documented in [USB.md, Errors](USB.md#12-errors-and-what-they-mean-on-the-wire).

## Examples

The [`example/`](example/) folder is a standalone Zig package that depends on this repository through a path dependency, so the root build stays untouched.

```sh
cd example
zig build                     # build every example into zig-out/bin
zig build -l                  # list the run steps
zig build run-all             # run the examples that need no arguments
zig build <name> -- <args>    # run one example
```

| Example | Arguments | Shows |
|---|---|---|
| `list_devices` | | Basic enumeration ([main.zig](example/main.zig)) |
| `descriptor_tree` | | Device, configuration, interface, alt setting and endpoint tree |
| `find_devices` | `[--vid hex] [--pid hex] [--class n]` | Filtering with `Device.Descriptor` |
| `hid_descriptors` | | Class specific descriptors through `Constants.dt_hid` |
| `open_device` | `[vid:pid]` | `Device.open`, `openDeviceWithVidPid`, `Device.Handle.device` |
| `open_fd` | `<bus> <address>` | Wrapping an existing usbfs file descriptor (Linux) |
| `claim_interface` | `<vid:pid> <iface> [alt]` | Claim, alternate setting, release, driver re-attach |
| `control_transfer` | `<vid:pid> <bmRequestType> <bRequest> <wValue> <wIndex> [hex] [timeout]` | `writeControl` |
| `bulk_transfer` | `<vid:pid> <iface> [--out ep hex] [--in ep [len]]` | `writeBulk`, `readBulk` |
| `isochronous_transfer` | `<vid:pid> <iface> <alt> <ep> [size] [packets] [seconds]` | `Transfer`, `handleEvents`, `cancel` |
| `error_handling` | | Error mapping and real error paths |

Examples that claim interfaces detach kernel drivers while they run. Prefer devices without a bound driver; check with `ls -l /sys/bus/usb/devices/*:*/driver`.

## Tests

The [`test/`](test/) folder is another standalone package with one test binary per module (`Transfer(T)` exports C symbols, so separate binaries avoid duplicates).

```sh
cd test
zig build test --summary all  # every test file
zig build test-transfer       # a single file: test-<module>
```

- Descriptor, error, packet and transfer logic is tested with synthetic libusb structures and needs no hardware.
- Tests touching real devices only read descriptors or open handles, and skip themselves when no device is available.
- Intrusive tests (claiming, alternate settings, bulk reads) are opt-in and never claim an interface that has a kernel driver bound:

```sh
# vvvv:pppp:interface[:bulk_in_endpoint]
ZUSB_TEST_DEVICE=2df0:0007:0:0x82 zig build test --summary all
```

## Project layout

```
.
├── zusb.zig                  module root, re-exports everything below
├── src/
│   ├── context.zig           Context: session, enumeration, opening, events
│   ├── device_list.zig       Device.List and its iterator
│   ├── device.zig            Device: location, descriptors, open
│   ├── device_descriptor.zig Device.Descriptor accessors
│   ├── config_descriptor.zig ConfigDescriptor and interface iterator
│   ├── interface_descriptor.zig  interfaces, alt settings, endpoint iterator
│   ├── endpoint_descriptor.zig   EndpointDescriptor accessors
│   ├── device_handle.zig     Device.Handle: claiming and synchronous I/O
│   ├── transfer.zig          Transfer(T): asynchronous transfers (WIP)
│   ├── packet_descriptor.zig isochronous packet iterator
│   ├── error.zig             Error set and libusb code mapping
│   ├── fields.zig            Direction and TransferType enums
│   ├── constants.zig         descriptor constants
│   ├── options.zig           global libusb options (not re-exported)
│   └── constructor.zig       internal constructors
├── example/                  examples package (build.zig, *.zig)
├── test/                     test package (build.zig, *_test.zig)
├── USB.md                    USB protocol guide mapped to this API
└── build.zig                 library module + original example
```

## API overview

| Type | Main functions |
|---|---|
| `Context` | `init`, `deinit`, `devices`, `openDeviceWithVidPid`, `openDeviceWithFd`, `handleEvents` |
| `Device` | `deinit`, `deviceDescriptor`, `configDescriptor`, `busNumber`, `portNumber`, `address`, `open` |
| `Device.List` | `init`, `deinit`, `devices` → `Iterator.next` |
| `Device.Descriptor` | `classCode`, `subClassCode`, `vendorId`, `productId`, raw `descriptor` |
| `Device.Handle` | `deinit`, `device`, `claimInterface`, `releaseInterface`, `setInterfaceAltSetting`, `writeControl`, `readBulk`, `writeBulk` |
| `ConfigDescriptor` | `interfaces` → `Interfaces.next`, `deinit`, raw `descriptor` |
| `InterfaceDescriptor` | `number`, `descriptors` → alt settings, `endpointDescriptors` |
| `EndpointDescriptor` | `address`, `number`, `direction`, `transferType`, `interval` |
| `Transfer(T)` | `fillIsochronous`, `submit`, `cancel`, `isActive`, `buffer`, `deinit` |
| `PacketDescriptor` | `PacketDescriptors.next`, `buffer`, `isCompleted`, `status` |
| `Error` | `Error`, `errorFromLibusb`, `failable` |
| `Fields` | `Direction`, `TransferType` |
| `Constants` | `dt_hid` |

USB.md has the [detailed reference map](USB.md#14-api-reference-map) with links to each function.

## Known limitations

zusb is a work in progress. The main gaps:

- No IN control transfers, interrupt transfers, string descriptors, hotplug or device reset wrappers yet: use libusb directly via the raw pointers.
- `Context.openDeviceWithFd` and `Transfer.fillInterrupt` do not compile in their current form.
- `InterfaceDescriptor.endpointDescriptors` panics on alternate settings with no endpoints: check `bNumEndpoints` first.
- `EndpointDescriptor.number` is wrong for endpoints 8 to 15.

The complete list, with workarounds, is in [USB.md, Current limitations](USB.md#15-current-limitations).

## License

Copyright © 2015 David Cuddeback

Distributed under the [MIT License](LICENSE).

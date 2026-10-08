# USB from the ground up, with zusb

This document explains how USB works, from bus topology down to packets, and
shows at each step which part of **zusb** gives you access to it. It is meant
both as a protocol primer and as a guided reference for the library API.

> Scope: USB 2.0 concepts, which every USB 3.x device still exposes through
> the same descriptor and transfer model. SuperSpeed specific details are
> mentioned where they change what you see from software.

## Contents

1. [The big picture](#1-the-big-picture)
2. [Bus topology: buses, hubs, ports and addresses](#2-bus-topology-buses-hubs-ports-and-addresses)
3. [Speeds, frames and bandwidth](#3-speeds-frames-and-bandwidth)
4. [Enumeration: how a device comes alive](#4-enumeration-how-a-device-comes-alive)
5. [Descriptors](#5-descriptors)
6. [Endpoints](#6-endpoints)
7. [Packets, transactions and transfers](#7-packets-transactions-and-transfers)
8. [The four transfer types](#8-the-four-transfer-types)
9. [Interfaces, alternate settings and kernel drivers](#9-interfaces-alternate-settings-and-kernel-drivers)
10. [Device classes](#10-device-classes)
11. [The libusb model behind zusb](#11-the-libusb-model-behind-zusb)
12. [Errors and what they mean on the wire](#12-errors-and-what-they-mean-on-the-wire)
13. [Permissions on Linux](#13-permissions-on-linux)
14. [API reference map](#14-api-reference-map)
15. [Current limitations](#15-current-limitations)

---

## 1. The big picture

USB is a **host-centric**, **polled** bus:

- There is exactly one **host** per bus (your computer's host controller).
  Devices never talk unless the host asks them to. Even "interrupt" data is
  collected by the host polling the device on a schedule.
- A **device** exposes a set of **endpoints**: numbered, unidirectional data
  sinks or sources. All communication is a **transfer** between the host and
  one endpoint.
- The device describes itself through **descriptors**: small binary
  structures that tell the host what the device is, how it is organised and
  how to talk to it.
- A device groups its endpoints into **interfaces**. Each interface is one
  function (a keyboard, a webcam stream, a serial port) and is driven by one
  driver. Several interfaces make a **configuration**.

```
Host (your program -> zusb -> libusb -> OS -> host controller)
 │
 └── Device
      └── Configuration (one active at a time)
           ├── Interface 0
           │    └── Alternate setting 0 ── Endpoint 0x81 (IN, interrupt)
           └── Interface 1
                ├── Alternate setting 0 ── (no endpoints, zero bandwidth)
                └── Alternate setting 1 ── Endpoint 0x82 (IN, isochronous)

Endpoint 0 (control) always exists and belongs to the device as a whole.
```

In zusb that hierarchy maps one to one onto types. Everything that belongs to
a single device is namespaced under `Device`: `Device.List`,
`Device.Descriptor` and `Device.Handle`.

| USB concept | zusb type | Obtained from |
|---|---|---|
| Library session | [`Context`](src/context.zig) | `Context.init()` |
| List of attached devices | [`Device.List`](src/device_list.zig) | `ctx.devices()` |
| Device (not opened) | [`Device`](src/device.zig) | `device_list.devices().next()` (a `Device.List.Iterator`) |
| Device descriptor | [`Device.Descriptor`](src/device_descriptor.zig) | `device.deviceDescriptor()` |
| Configuration descriptor | [`ConfigDescriptor`](src/config_descriptor.zig) | `device.configDescriptor(i)` |
| Interface | [`InterfaceDescriptor`](src/interface_descriptor.zig) (the file struct) | `config.interfaces().next()` |
| Alternate setting | `InterfaceDescriptor.InterfaceDescriptor` | `interface.descriptors().next()` |
| Endpoint descriptor | [`EndpointDescriptor`](src/endpoint_descriptor.zig) | `alt.endpointDescriptors().next()` |
| Open device, I/O | [`Device.Handle`](src/device_handle.zig) | `device.open()` / `ctx.openDeviceWithVidPid()` |
| Asynchronous transfer | [`zusb.Transfer(T)`](src/transfer.zig) | `zusb.Transfer(T).fillIsochronous(...)` |

---

## 2. Bus topology: buses, hubs, ports and addresses

Every host controller drives one **bus**. Each bus starts at a **root hub**,
which is built into the controller. Devices hang from hub **ports**, and hubs
can be chained, forming a tree:

```
Bus 3
└── Root hub (address 1)            port 0 (root hubs have no parent port)
     ├── port 4: Card reader        (address 2)
     ├── port 5: Fingerprint reader (address 3)
     ├── port 6: Webcam             (address 4)
     └── port 10: Bluetooth         (address 5)
```

Rules of the tree:

- Up to **127 devices per bus**. Address 0 is reserved for a device that has
  just been reset and is still being enumerated.
- At most **7 tiers** (root hub + 5 external hubs + device).
- Addresses are assigned dynamically by the host at enumeration. Unplugging
  and replugging usually gives the device a new address, so **never use the
  address as a persistent identifier**. The (bus, port path) pair is stable
  across replugs on the same physical socket; the (vendor id, product id,
  serial number) triple identifies the device itself.

On a USB 3 controller, every physical socket appears **twice**: once on a USB
2 bus and once on a SuperSpeed bus (this is why you typically see paired root
hubs `1d6b:0002` and `1d6b:0003`).

### In zusb

```zig
var devices = device_list.devices();
while (devices.next()) |device| {
    defer device.deinit();
    std.debug.print("bus {d} address {d} port {d}\n", .{
        device.busNumber(),  // which host controller
        device.address(),    // 1..127, assigned at enumeration
        device.portNumber(), // port on the parent hub, 0 for root hubs
    });
}
```

See [`example/main.zig`](example/main.zig) and
[`example/find_devices.zig`](example/find_devices.zig).

---

## 3. Speeds, frames and bandwidth

| Name | Signalling rate | USB version | Time base |
|---|---|---|---|
| Low Speed | 1.5 Mbit/s | 1.0 | 1 ms frame |
| Full Speed | 12 Mbit/s | 1.1 | 1 ms frame |
| High Speed | 480 Mbit/s | 2.0 | 125 µs microframe (8 per frame) |
| SuperSpeed | 5 Gbit/s | 3.0 / 3.2 Gen 1 | 125 µs bus interval |
| SuperSpeed+ | 10 / 20 Gbit/s | 3.1 / 3.2 Gen 2, Gen 2x2 | 125 µs bus interval |

The host divides time into **frames** (Full Speed) or **microframes** (High
Speed and above), announced by a Start-of-Frame (SOF) packet. Within each
(micro)frame the host controller schedules work in this priority order:

1. **Isochronous** and **interrupt** transfers get reserved, guaranteed time
   (up to 90% of a Full Speed frame, 80% of a High Speed microframe).
2. **Control** transfers get a guaranteed slice of what remains.
3. **Bulk** transfers use whatever is left.

This is why the transfer type of an endpoint is a statement about **timing
guarantees**, not just about data size. Section 8 goes through each one.

The `bcdUSB` field of the device descriptor tells which specification the
device claims to follow (e.g. `0x0200` = USB 2.0, `0x0310` = USB 3.1). It is
not the speed the device is actually running at.

---

## 4. Enumeration: how a device comes alive

When a device is plugged in, the host walks it through a fixed sequence
before any application can use it:

1. **Attach detected**: the hub notices a voltage change on the data lines
   and reports it to the host. The pull-up resistor position tells Low vs
   Full Speed; High Speed is negotiated during reset ("chirp").
2. **Reset**: the host resets the port. The device now answers on
   **address 0**, endpoint 0.
3. **First descriptor read**: `GET_DESCRIPTOR(Device)` for the first 8 bytes,
   just to learn `bMaxPacketSize0` (the packet size of endpoint 0).
4. **Set address**: `SET_ADDRESS(n)`. From now on the device answers on
   address `n` only.
5. **Full device descriptor** (18 bytes), then each **configuration
   descriptor** (first 9 bytes to learn `wTotalLength`, then the full block
   with all interfaces and endpoints), then **string descriptors**.
6. **Set configuration**: `SET_CONFIGURATION(bConfigurationValue)`. The
   device's endpoints become active. Configuration value 0 means
   "unconfigured".
7. **Driver binding**: the OS matches the device and interface descriptors
   (vendor/product ids, class codes) against its drivers and binds one per
   interface.

By the time zusb sees a device, steps 1-7 are done: the OS has already cached
the descriptors. `device.deviceDescriptor()` and `device.configDescriptor()`
are therefore served from that cache and **do not require opening the
device** or any special permission.

---

## 5. Descriptors

Every descriptor starts with the same two bytes:

| Offset | Field | Meaning |
|---|---|---|
| 0 | `bLength` | Size of this descriptor in bytes |
| 1 | `bDescriptorType` | What kind of descriptor follows |

That uniform header lets the host walk a byte stream of unknown descriptors,
skipping the ones it does not understand: read `bLength`, jump ahead.

### Descriptor types

| Type | Value | Notes |
|---|---|---|
| Device | `0x01` | One per device |
| Configuration | `0x02` | Header of the configuration block |
| String | `0x03` | UTF-16LE text, index 0 holds the language id list |
| Interface | `0x04` | One per alternate setting |
| Endpoint | `0x05` | One per endpoint in an alternate setting |
| Interface Association (IAD) | `0x0b` | Groups interfaces of one function (webcams, audio) |
| BOS | `0x0f` | Binary Object Store, device capabilities (USB 2.1+) |
| Device Capability | `0x10` | Inside the BOS |
| **HID** | `0x21` | Class specific, follows a HID interface: [`Constants.dt_hid`](src/constants.zig) |
| HID Report | `0x22` | Fetched separately with GET_DESCRIPTOR |
| Hub | `0x29` | USB 2 hub class descriptor |
| SuperSpeed Endpoint Companion | `0x30` | Follows each endpoint on SuperSpeed devices |

### 5.1 Device descriptor (18 bytes)

| Field | Size | Meaning | zusb accessor |
|---|---|---|---|
| `bcdUSB` | 2 | Spec version, BCD (`0x0200` = 2.00) | `descriptor.descriptor.bcdUSB` |
| `bDeviceClass` | 1 | Class code, `0x00` = "defined per interface" | `classCode()` |
| `bDeviceSubClass` | 1 | Subclass code | `subClassCode()` |
| `bDeviceProtocol` | 1 | Protocol code | `descriptor.descriptor.bDeviceProtocol` |
| `bMaxPacketSize0` | 1 | Max packet size of endpoint 0 (8, 16, 32, 64; 9 means 2⁹ = 512 on SuperSpeed) | `descriptor.descriptor.bMaxPacketSize0` |
| `idVendor` | 2 | Vendor id, assigned by USB-IF | `vendorId()` |
| `idProduct` | 2 | Product id, assigned by the vendor | `productId()` |
| `bcdDevice` | 2 | Device release number | `descriptor.descriptor.bcdDevice` |
| `iManufacturer` | 1 | String index of the manufacturer, 0 = none | `descriptor.descriptor.iManufacturer` |
| `iProduct` | 1 | String index of the product name | `descriptor.descriptor.iProduct` |
| `iSerialNumber` | 1 | String index of the serial number | `descriptor.descriptor.iSerialNumber` |
| `bNumConfigurations` | 1 | Number of configurations | `descriptor.descriptor.bNumConfigurations` |

[`Device.Descriptor`](src/device_descriptor.zig) wraps the raw libusb struct in
its public `descriptor` field, so every field is reachable even where there is
no dedicated accessor:

```zig
const descriptor = try device.deviceDescriptor();
std.debug.print("{x:0>4}:{x:0>4} class 0x{x:0>2}, {d} configuration(s)\n", .{
    descriptor.vendorId(),
    descriptor.productId(),
    descriptor.classCode(),
    descriptor.descriptor.bNumConfigurations,
});
```

### 5.2 Configuration descriptor (9 bytes + everything below it)

A configuration is a complete operating mode of the device: which interfaces
exist and how much power it draws. Most devices have exactly one.

| Field | Meaning |
|---|---|
| `wTotalLength` | Bytes of the whole block: config + all interfaces + endpoints + class descriptors |
| `bNumInterfaces` | Number of interfaces (not counting alternate settings) |
| `bConfigurationValue` | Value passed to `SET_CONFIGURATION` |
| `iConfiguration` | String index |
| `bmAttributes` | Bit 6 self-powered, bit 5 remote wakeup (bit 7 must be 1) |
| `MaxPower` | Max bus current, in **2 mA** units (USB 2) or **8 mA** units (SuperSpeed) |

The host fetches the whole `wTotalLength` block at once; libusb parses it into
a tree, and [`ConfigDescriptor`](src/config_descriptor.zig) gives you that
tree. It owns memory allocated by libusb, so **always `deinit` it**:

```zig
const config = try device.configDescriptor(0); // index, not bConfigurationValue
defer config.deinit();

std.debug.print("{d} interface(s), {d} mA\n", .{
    config.descriptor.bNumInterfaces,
    @as(u32, config.descriptor.MaxPower) * 2,
});
```

> `configDescriptor` takes an **index** (`0 .. bNumConfigurations - 1`), not
> the `bConfigurationValue`. An out of range index returns `error.NotFound`.

### 5.3 Interface descriptor (9 bytes, one per alternate setting)

| Field | Meaning |
|---|---|
| `bInterfaceNumber` | Interface number, shared by all its alternate settings |
| `bAlternateSetting` | Which alternate setting this descriptor describes |
| `bNumEndpoints` | Endpoints in this alternate setting, **excluding** endpoint 0 |
| `bInterfaceClass` / `bInterfaceSubClass` / `bInterfaceProtocol` | What the interface does (section 10) |
| `iInterface` | String index |

After the interface descriptor, the configuration block contains any
**class specific descriptors** (for example the HID descriptor, `0x21`), then
the endpoint descriptors. libusb keeps the unrecognised class specific bytes
in the `extra` / `extra_length` fields of the interface descriptor.

In zusb an interface is an iterator over its alternate settings:

```zig
var interfaces = config.interfaces();
while (interfaces.next()) |interface| {
    std.debug.print("interface {d}\n", .{interface.number()});

    var alt_settings = interface.descriptors();
    while (alt_settings.next()) |alt| {
        const raw = alt.descriptor.*;
        std.debug.print("  alt {d}: class 0x{x:0>2}, {d} endpoint(s)\n", .{
            raw.bAlternateSetting,
            raw.bInterfaceClass,
            raw.bNumEndpoints,
        });
    }
}
```

Walking `extra` to find a class specific descriptor, here the HID one:

```zig
const raw = alt.descriptor.*;
if (raw.extra != null and raw.extra_length > 0) {
    const extra = raw.extra[0..@intCast(raw.extra_length)];
    var offset: usize = 0;
    while (offset + 2 <= extra.len) {
        const length = extra[offset];
        if (length < 2 or offset + length > extra.len) break;
        if (extra[offset + 1] == zusb.Constants.dt_hid) {
            // HID descriptor: bcdHID at [2..4], bCountryCode [4],
            // bNumDescriptors [5], report descriptor length at [7..9].
        }
        offset += length;
    }
}
```

Full version: [`example/hid_descriptors.zig`](example/hid_descriptors.zig).

### 5.4 Endpoint descriptor (7 bytes)

| Field | Meaning | zusb accessor |
|---|---|---|
| `bEndpointAddress` | Bit 7 direction, bits 3..0 number | `address()`, `direction()`, `number()` |
| `bmAttributes` | Bits 1..0 transfer type, 3..2 sync type, 5..4 usage type | `transferType()` |
| `wMaxPacketSize` | Bits 10..0 packet size, bits 12..11 extra transactions per microframe (High Speed) | `descriptor.*.wMaxPacketSize` |
| `bInterval` | Polling interval, see section 8 | `interval()` |

Endpoints are detailed in the next section.

### 5.5 String descriptors

Strings (manufacturer, product, serial, interface names) are stored separately
and referenced by index. They are UTF-16LE encoded; index 0 returns the list
of supported LANGIDs (`0x0409` = English, United States). zusb does not wrap
string descriptors yet; see section 15 for how to call libusb directly.

### Dumping the whole tree

[`example/descriptor_tree.zig`](example/descriptor_tree.zig) walks device,
configurations, interfaces, alternate settings and endpoints, much like a
compact `lsusb -v`:

```
Bus 003 Device 004 Port 6: ID 2b7e:c668
  class 0xef (Miscellaneous) subclass 0x02
  bcdUSB 2.01  max packet (ep0) 64  configurations 1
  Configuration #0: value 1, 2 interface(s), max power 500mA
    Interface 0
      Alt setting 0: class 0x0e (Video) subclass 0x01 protocol 0x00, 1 endpoint(s)
        Endpoint 0x87: number 7, IN  interrupt, interval 8, max packet 16
    Interface 1
      Alt setting 0: class 0x0e (Video) subclass 0x02 protocol 0x00, 0 endpoint(s)
      Alt setting 1: class 0x0e (Video) subclass 0x02 protocol 0x00, 1 endpoint(s)
        Endpoint 0x81: number 1, IN  isochronous, interval 1, max packet 192
```

---

## 6. Endpoints

An endpoint is the unit of addressing inside a device. It is identified by
its **address byte**:

```
 bit  7   6 5 4   3 2 1 0
     dir  reserved  number
     1=IN           0..15
     0=OUT
```

- **Direction is always seen from the host.** IN = device to host (you read),
  OUT = host to device (you write).
- **IN and OUT are separate endpoints**: `0x01` (EP1 OUT) and `0x81` (EP1 IN)
  are two independent pipes that happen to share a number.
- **Endpoint 0** is the default control endpoint. It is bidirectional, always
  present, has no endpoint descriptor, and is shared by all interfaces.
- A device can have up to 15 IN plus 15 OUT endpoints besides endpoint 0.

| zusb | Returns | Example for `0x83` |
|---|---|---|
| `endpoint.address()` | Full address byte | `0x83` |
| `endpoint.direction()` | `Fields.Direction.In` / `.Out` | `.In` |
| `endpoint.number()` | Endpoint number | `3` |
| `endpoint.transferType()` | `Fields.TransferType` | from `bmAttributes` |
| `endpoint.interval()` | `bInterval` | |

When you call transfer functions, you pass the **address** (with the
direction bit), not the number: `readBulk(0x82, ...)`, `writeBulk(0x01, ...)`.
zusb checks the direction bit and returns `error.InvalidParam` on a mismatch
before anything reaches the device.

### Max packet size

`wMaxPacketSize` limits how many bytes fit in **one packet**, not in one
transfer. A transfer larger than the packet size is split into several packets
by the host controller. Typical limits:

| Type | Low Speed | Full Speed | High Speed | SuperSpeed |
|---|---|---|---|---|
| Control | 8 | 8, 16, 32, 64 | 64 | 512 |
| Bulk | n/a | 8, 16, 32, 64 | 512 | 1024 |
| Interrupt | ≤ 8 | ≤ 64 | ≤ 1024 (×3 per µframe) | ≤ 1024 (with bursts) |
| Isochronous | n/a | ≤ 1023 | ≤ 1024 (×3 per µframe) | ≤ 1024 (with bursts) |

On High Speed interrupt/isochronous endpoints, bits 12..11 of
`wMaxPacketSize` add 0, 1 or 2 extra transactions per microframe:

```zig
const raw = endpoint.descriptor.*.wMaxPacketSize;
const packet_size = raw & 0x07ff;
const per_microframe = ((raw >> 11) & 0x3) + 1;
const bytes_per_microframe = packet_size * per_microframe;
```

---

## 7. Packets, transactions and transfers

USB communication has three layers. Applications only deal with the top one,
but the lower ones explain timeouts, stalls and short reads.

### Packets

The smallest unit on the wire. Every packet starts with a **PID** (packet id):

| Kind | PIDs | Purpose |
|---|---|---|
| Token | `SETUP`, `IN`, `OUT`, `SOF` | Host announces what happens next and to which address/endpoint |
| Data | `DATA0`, `DATA1` (+ `DATA2`, `MDATA` on High Speed isochronous) | Payload, protected by a CRC16 |
| Handshake | `ACK`, `NAK`, `STALL`, `NYET` | Receiver reports the outcome |

Handshakes are where most software visible behaviour comes from:

- **ACK**: data received correctly.
- **NAK**: "not ready, try again". The host controller silently retries; to
  your program this just means the call takes longer. A device that NAKs
  forever leads to `error.Timeout`.
- **STALL**: "this request is not supported" or "endpoint halted". Surfaces as
  `error.Pipe`.
- **NYET**: High Speed flow control ("got it, but not ready for more").

### Data toggle

Consecutive data packets on an endpoint alternate between `DATA0` and `DATA1`.
If an ACK is lost and the host resends, the device sees the same toggle twice
and discards the duplicate. Selecting an alternate setting or clearing a halt
resets the toggle, which is why those operations go through the host stack
instead of being invented by the device.

### Transactions

A **transaction** is token + (data) + (handshake). For example an IN
transaction: host sends `IN`, device sends `DATA1`, host sends `ACK`.

### Transfers

A **transfer** is what your program asks for: "read up to 512 bytes from
`0x82`". The host controller splits it into transactions of at most
`wMaxPacketSize` bytes each. A transfer completes when:

- the requested length was transferred, or
- a **short packet** arrives (fewer bytes than `wMaxPacketSize`), which marks
  the end of the device's message, or
- the timeout expires, or an error/stall occurs.

A transfer whose length is an exact multiple of the packet size can be
terminated by the device with a **zero length packet** (ZLP).

This is why `readBulk` returns **the number of bytes actually read**, which
can be smaller than the buffer:

```zig
var buffer: [512]u8 = undefined;
const read = try handle.readBulk(0x82, &buffer, 1000);
const message = buffer[0..read];
```

zusb also returns the partial count when a bulk transfer times out after
moving some data, instead of discarding it.

---

## 8. The four transfer types

| | Control | Bulk | Interrupt | Isochronous |
|---|---|---|---|---|
| Direction | Bidirectional (endpoint 0) | One way | One way | One way |
| Delivery guarantee | Yes (retries) | Yes (retries) | Yes (retries) | **No** (no retries) |
| Bandwidth guarantee | Reserved slice | **None** (leftover) | Yes | Yes |
| Latency guarantee | Best effort | None | Bounded by `bInterval` | Fixed, every interval |
| Typical use | Setup, commands, status | Storage, printers, serial data | Keyboards, mice, notifications | Audio, video |
| zusb | `writeControl` | `readBulk`, `writeBulk` | (raw libusb, see 15) | `zusb.Transfer(T).fillIsochronous` |

### 8.1 Control transfers

Control transfers are used for configuration and for most class and vendor
commands. They always go through endpoint 0 and have up to three stages:

```
Setup stage   SETUP token + 8 byte setup packet          (host -> device)
Data stage    0..wLength bytes, direction per bit 7      (optional)
Status stage  zero length packet, opposite direction     (handshake of the whole request)
```

The 8 byte **setup packet**:

| Offset | Field | Meaning |
|---|---|---|
| 0 | `bmRequestType` | Direction, type and recipient (below) |
| 1 | `bRequest` | Request code |
| 2 | `wValue` | Request specific parameter |
| 4 | `wIndex` | Request specific, usually interface or endpoint number |
| 6 | `wLength` | Length of the data stage |

`bmRequestType` bit layout:

```
 bit   7       6 5         4 3 2 1 0
      dir      type        recipient
      0 = host-to-device   00 = standard   00000 = device
      1 = device-to-host   01 = class      00001 = interface
                           10 = vendor     00010 = endpoint
                                           00011 = other
```

Common values: `0x00` standard OUT to device, `0x80` standard IN from device,
`0x21` class OUT to interface (HID `SET_REPORT`), `0xa1` class IN from
interface, `0x40` vendor OUT to device, `0xc0` vendor IN from device.

Standard requests (`type = 00`):

| bRequest | Name | Direction | Purpose |
|---|---|---|---|
| `0x00` | GET_STATUS | IN | Self-powered/remote wakeup/halt status |
| `0x01` | CLEAR_FEATURE | OUT | Clear e.g. ENDPOINT_HALT |
| `0x03` | SET_FEATURE | OUT | Set e.g. DEVICE_REMOTE_WAKEUP, TEST_MODE |
| `0x05` | SET_ADDRESS | OUT | Used by the host during enumeration only |
| `0x06` | GET_DESCRIPTOR | IN | `wValue` = type << 8 \| index |
| `0x07` | SET_DESCRIPTOR | OUT | Rarely implemented |
| `0x08` | GET_CONFIGURATION | IN | Current `bConfigurationValue` |
| `0x09` | SET_CONFIGURATION | OUT | Select a configuration |
| `0x0a` | GET_INTERFACE | IN | Current alternate setting |
| `0x0b` | SET_INTERFACE | OUT | Select an alternate setting |
| `0x0c` | SYNCH_FRAME | IN | Isochronous synchronisation |

zusb currently exposes the **host-to-device** direction through
[`Device.Handle.writeControl`](src/device_handle.zig#L52):

```zig
// Vendor specific OUT request with a 2 byte data stage.
const sent = try handle.writeControl(
    0x40,      // bmRequestType: OUT | vendor | device
    0x01,      // bRequest
    0x0000,    // wValue
    0x0000,    // wIndex
    &.{ 0xab, 0xcd }, // data stage, or null for none
    1000,      // timeout in ms
);
```

`writeControl` rejects an IN `bmRequestType` with `error.InvalidParam`, a data
stage longer than 65535 bytes with `error.Overflow`, and a device that does
not support the request answers with STALL, reported as `error.Pipe`.

Do not issue `SET_CONFIGURATION` or `SET_INTERFACE` as raw control requests:
the OS must know about the change. Use `setInterfaceAltSetting` instead.

Example: [`example/control_transfer.zig`](example/control_transfer.zig).

### 8.2 Bulk transfers

Bulk is for large amounts of data where correctness matters but timing does
not: mass storage, printers, scanners, network adapters, most "custom
protocol" devices. Bulk is only available on Full Speed and faster devices.

- Error detection and retries are done by hardware: you never get corrupted
  bulk data, at worst an error or a timeout.
- No bandwidth is reserved. Bulk is fastest on an idle bus and slows down
  when isochronous or interrupt traffic is present.

```zig
try handle.claimAutoDeatachableInterface(0); // driver re-attached on release

const written = try handle.writeBulk(0x01, "ping", 1000);  // OUT endpoint
var reply: [64]u8 = undefined;
const read = try handle.readBulk(0x81, &reply, 1000);      // IN endpoint
```

Example: [`example/bulk_transfer.zig`](example/bulk_transfer.zig).

### 8.3 Interrupt transfers

Despite the name, there are no hardware interrupts: the host **polls** the
endpoint every `bInterval`. Interrupt transfers suit small, latency
sensitive data such as key presses, mouse movement or "data ready"
notifications.

`bInterval` meaning:

| Speed | Interrupt `bInterval` | Polling period |
|---|---|---|
| Low/Full | 1..255 | `bInterval` ms |
| High/Super | 1..16 | 2^(`bInterval` - 1) × 125 µs |

zusb has no working interrupt transfer API yet (`Transfer.fillInterrupt` is
work in progress), see section 15.

### 8.4 Isochronous transfers

Isochronous endpoints get a fixed slot every (micro)frame. They trade
reliability for timing: a corrupted packet is **not** retried, it is reported
as failed and the stream moves on. That is the right choice for audio and
video, where late data is as bad as lost data.

Specifics:

- An isochronous transfer is made of **packets**, one per interval, each with
  its own length and status.
- `bInterval` for isochronous endpoints is always 2^(`bInterval` - 1) frames
  (Full Speed) or microframes (High Speed).
- `bmAttributes` bits 3..2 give the **synchronisation type** (none,
  asynchronous, adaptive, synchronous) and bits 5..4 the **usage** (data,
  feedback, implicit feedback). zusb's `transferType()` reads bits 1..0 only.
- Isochronous endpoints usually live in a non-zero **alternate setting**:
  alternate setting 0 has no endpoints so that an idle device reserves no
  bandwidth (section 9).

Isochronous I/O is asynchronous in libusb. zusb provides it through
[`zusb.Transfer(T)`](src/transfer.zig), a generic type parameterised on your
callback state:

```zig
const Stats = struct {
    bytes: usize = 0,

    fn onPacket(self: *Stats, data: []const u8) void {
        self.bytes += data.len;
    }
};
const IsoTransfer = zusb.Transfer(Stats);

try handle.claimAutoDeatachableInterface(1);
try handle.setInterfaceAltSetting(1, 1); // alt setting holding the iso endpoint

var stats: Stats = .{};
const transfer = try IsoTransfer.fillIsochronous(
    allocator,
    &handle,
    0x81,  // IN endpoint
    192,   // bytes per packet (<= wMaxPacketSize)
    8,     // packets per transfer
    Stats.onPacket,
    &stats,
    1000,  // timeout in ms
);
defer transfer.deinit();

try transfer.submit();
while (keep_running) try ctx.handleEvents(); // callbacks run in here

try transfer.cancel();
while (transfer.isActive()) try ctx.handleEvents();
```

How it works:

- `fillIsochronous` allocates a buffer of `packet_size * num_packets` bytes
  and a libusb transfer with `num_packets` packet slots.
- When the transfer completes, every **completed** packet is passed to your
  callback as a slice trimmed to the bytes actually received (see
  [`PacketDescriptor`](src/packet_descriptor.zig)). Failed packets are
  skipped.
- The transfer then **resubmits itself**, keeping the stream going, until
  `cancel()` is called or a transfer fails.
- Nothing happens unless some thread calls `ctx.handleEvents()`.

Example: [`example/isochronous_transfer.zig`](example/isochronous_transfer.zig).

---

## 9. Interfaces, alternate settings and kernel drivers

### Claiming

An interface can be driven by only one owner at a time. Before doing I/O on
the endpoints of an interface, your program must **claim** it. Control
transfers on endpoint 0 do not require a claim, although class requests
addressed to an interface usually behave better with one.

[`Device.Handle.claimInterface`](src/device_handle.zig#L25) does two things:

1. If a kernel driver is bound to the interface, it **detaches** it.
2. It claims the interface and records it in `handle.interfaces`, a bit mask
   of claimed interfaces.

```zig
try handle.claimInterface(0);
defer handle.releaseInterface(0) catch {};
```

`Device.Handle.deinit` releases every interface still marked as claimed, so
an explicit release is optional.

> **Detaching a kernel driver takes the device away from the system.** A
> keyboard stops typing, a webcam disappears from video applications.
> `claimInterface` does not re-attach the driver on release. To get it back,
> claim with [`Device.Handle.claimAutoDeatachableInterface`](src/device_handle.zig#L34)
> instead. It enables libusb's auto detach mode on the handle, then claims;
> libusb re-attaches the driver when the interface is released (explicitly
> or by `handle.deinit()`):
>
> ```zig
> try handle.claimAutoDeatachableInterface(0);
> ```
>
> Auto detach is a property of the handle: once enabled, interfaces claimed
> later with plain `claimInterface` on the same handle are re-attached on
> release too. Alternatively, re-attach explicitly with
> `libusb_attach_kernel_driver` as shown in
> [`example/claim_interface.zig`](example/claim_interface.zig). Some drivers
> bind several interfaces through a single one (e.g. `uvcvideo`), and
> re-attaching one interface is not enough; `usbreset vvvv:pppp` restores
> them.

### Alternate settings

An interface can have several **alternate settings**, mutually exclusive
variants with different endpoints. Only one is active at a time, selected with
`SET_INTERFACE`. The main use is **bandwidth negotiation** for periodic
endpoints:

- Alternate setting 0: no isochronous endpoint, reserves nothing.
- Alternate settings 1..n: the same endpoint with increasing
  `wMaxPacketSize` (the webcam in section 5 goes from 192 to 5116 bytes).

The application selects the smallest setting that fits its needs. If the bus
cannot provide the bandwidth, selecting it fails.

```zig
try handle.claimInterface(1);                 // must be claimed first
try handle.setInterfaceAltSetting(1, 3);      // interface 1, alternate setting 3
defer handle.setInterfaceAltSetting(1, 0) catch {}; // release the bandwidth
```

`setInterfaceAltSetting` on an unclaimed interface, or with a setting that
does not exist, returns `error.NotFound`.

---

## 10. Device classes

Class codes tell the OS which generic driver can handle a device or an
interface without vendor specific software. `bDeviceClass = 0x00` means "look
at each interface", which is how most composite devices are described.
`0xef` / subclass `0x02` / protocol `0x01` means the device uses Interface
Association Descriptors to group interfaces.

| Code | Class | Examples | Defined at |
|---|---|---|---|
| `0x00` | Per interface | Most composite devices | Device |
| `0x01` | Audio | Headsets, sound cards | Interface |
| `0x02` | Communications (CDC) | Modems, USB serial, Ethernet | Both |
| `0x03` | HID | Keyboards, mice, game controllers | Interface |
| `0x05` | Physical | Force feedback | Interface |
| `0x06` | Image (still imaging) | Cameras over PTP | Interface |
| `0x07` | Printer | Printers | Interface |
| `0x08` | Mass Storage | Flash drives, card readers | Interface |
| `0x09` | Hub | Hubs, root hubs | Device |
| `0x0a` | CDC Data | Data half of a CDC function | Interface |
| `0x0b` | Smart Card | Card readers | Interface |
| `0x0e` | Video (UVC) | Webcams | Interface |
| `0x0f` | Personal Healthcare | Medical devices | Interface |
| `0x10` | Audio/Video | AV devices | Interface |
| `0x11` | Billboard | Alt mode information | Device |
| `0xdc` | Diagnostic | Debug devices | Both |
| `0xe0` | Wireless Controller | Bluetooth adapters | Interface |
| `0xef` | Miscellaneous | IAD based composite devices | Both |
| `0xfe` | Application Specific | DFU, IrDA, test & measurement | Interface |
| `0xff` | Vendor Specific | Anything with a custom protocol | Both |

Filtering by class with zusb:

```zig
if (descriptor.classCode() == 0x09) {
    // a hub
}
```

[`example/find_devices.zig`](example/find_devices.zig) filters by vendor,
product and class from the command line.

---

## 11. The libusb model behind zusb

zusb is a thin, idiomatic Zig layer over [libusb](https://libusb.info). The
libusb object model, and therefore zusb's, is:

### Context

A [`Context`](src/context.zig) is an independent libusb session: its own
device list, event loop and options. Programs normally use one, but several
can coexist, which is handy for libraries and tests.

```zig
var ctx = try zusb.Context.init();
defer ctx.deinit();
```

`Context.deinit` must run **after** every device, handle and transfer created
from it has been released.

### Device list and reference counting

`ctx.devices()` (or `Device.List.init(&ctx)`) takes a snapshot of the devices
attached right now. Each `Device` returned by the iterator holds **its own
reference** to the underlying libusb device, so:

- Always `defer device.deinit()` on devices you take from the iterator, or
  they are leaked.
- A `Device` remains valid after the `Device.List` is freed, which makes it
  safe to return a device from a search function.

```zig
fn findDevice(ctx: *zusb.Context, vendor_id: u16, product_id: u16) !?zusb.Device {
    const device_list = try ctx.devices();
    defer device_list.deinit();

    var devices = device_list.devices();
    while (devices.next()) |device| {
        const descriptor = device.deviceDescriptor() catch {
            device.deinit();
            continue;
        };
        if (descriptor.vendorId() == vendor_id and descriptor.productId() == product_id) {
            return device; // caller now owns this reference
        }
        device.deinit();
    }
    return null;
}
```

### Opening: Device vs Device.Handle

A `Device` can be inspected (descriptors, location) without opening it. I/O
requires a [`Device.Handle`](src/device_handle.zig), which corresponds to an
open file on the OS side and needs access permission (section 13):

| Function | Behaviour |
|---|---|
| `device.open()` | Opens a device you already found. Errors: `Access`, `NoDevice`, `NotSupported` |
| `ctx.openDeviceWithVidPid(vid, pid)` | Convenience: opens the **first** match, returns `null` if none or not accessible |
| `ctx.openDeviceWithFd(fd)` | Wraps an already opened OS file descriptor (Android, sandboxes) |

`handle.device()` goes back from a handle to its `Device` and takes a new
reference, so `deinit` it as well.

### Synchronous vs asynchronous I/O

- **Synchronous** (`writeControl`, `readBulk`, `writeBulk`): the call blocks
  until the transfer completes, fails or times out. Simple and adequate for
  request/response protocols.
- **Asynchronous** (`zusb.Transfer(T)`): you submit a transfer and continue; the
  completion callback runs later from inside `ctx.handleEvents()`. Needed for
  streaming (isochronous) and for keeping several transfers in flight.

`ctx.handleEvents()` blocks until at least one event is processed, or until
libusb's internal timeout (60 s) expires. Typical patterns are a dedicated
event thread, or a loop in the main thread while transfers are pending. From
another thread, `libusb_interrupt_event_handler(ctx.raw)` wakes it up.

### Global options

[`src/options.zig`](src/options.zig) provides `disableDeviceDiscovery()`,
which sets `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` for every context created
afterwards. Use it together with `openDeviceWithFd` on platforms where
enumeration is not allowed (Android without root). It is not re-exported from
`zusb.zig` yet.

### Reaching libusb directly

Every zusb wrapper keeps the raw libusb pointer or struct in a public field
(`ctx.raw`, `device.raw`, `handle.raw`, `descriptor.descriptor`), so anything
zusb does not wrap yet can be done with the libusb C API. In your own
`build.zig`, import the same translated module zusb uses so the types match:

```zig
const zusb_mod = zusb_dep.module("zusb");
const libusb_mod = zusb_mod.import_table.get("libusb").?;
exe.root_module.addImport("libusb", libusb_mod);
```

zusb's `build.zig` also registers a public `libusb` module
(`zusb_dep.module("libusb")`), but for now it is a separate instance from the
one zusb imports, so using it next to `zusb` fails with
`file exists in modules 'libusb' and 'libusb0'`. Prefer `import_table` until
the zusb module is built with that same `libusb_mod`.

---

## 12. Errors and what they mean on the wire

libusb returns negative status codes; zusb converts them into the
[`zusb.Error`](src/error.zig) error set via `zusb.errorFromLibusb` and
`zusb.failable`, all three re-exported at the module root:

```zig
try zusb.failable(libusb.libusb_clear_halt(handle.raw, 0x81)); // 0 = success
const e: zusb.Error = zusb.errorFromLibusb(libusb.LIBUSB_ERROR_PIPE); // error.Pipe
```

| zusb error | libusb code | Typical cause |
|---|---|---|
| `Io` | `LIBUSB_ERROR_IO` (-1) | Low level I/O failure, often a flaky cable |
| `InvalidParam` | `LIBUSB_ERROR_INVALID_PARAM` (-2) | Wrong direction for the endpoint, bad argument |
| `Access` | `LIBUSB_ERROR_ACCESS` (-3) | No permission to open the device node (section 13) |
| `NoDevice` | `LIBUSB_ERROR_NO_DEVICE` (-4) | Device unplugged |
| `NotFound` | `LIBUSB_ERROR_NOT_FOUND` (-5) | Interface not claimed, config index out of range, nothing to cancel |
| `Busy` | `LIBUSB_ERROR_BUSY` (-6) | Interface claimed by another program or driver |
| `Timeout` | `LIBUSB_ERROR_TIMEOUT` (-7) | Device kept NAKing until the timeout |
| `Overflow` | `LIBUSB_ERROR_OVERFLOW` (-8) | Device sent more data than the buffer holds (babble); also a zusb size/timeout cast overflow |
| `Pipe` | `LIBUSB_ERROR_PIPE` (-9) | Endpoint **STALL**: request unsupported or endpoint halted |
| `Interrupted` | `LIBUSB_ERROR_INTERRUPTED` (-10) | System call interrupted |
| `OutOfMemory` | `LIBUSB_ERROR_NO_MEM` (-11) | Allocation failure |
| `NotSupported` | `LIBUSB_ERROR_NOT_SUPPORTED` (-12) | Operation unavailable on this platform/driver |
| `Other` | `LIBUSB_ERROR_OTHER` (-99) and unknown codes | Anything else |
| `BadDescriptor` | none | Reserved, not produced yet |

Handling errors idiomatically:

```zig
const read = handle.readBulk(0x81, &buffer, 500) catch |e| switch (e) {
    error.Timeout => 0,                 // nothing to read right now
    error.Pipe => return error.Stalled, // device rejected the request
    error.NoDevice => return error.Unplugged,
    else => return e,
};
```

[`example/error_handling.zig`](example/error_handling.zig) prints the full
mapping and triggers several of these errors against real devices.

---

## 13. Permissions on Linux

Device nodes live in `/dev/bus/usb/BBB/DDD` and are usually owned by root.
Reading descriptors works for everyone (they come from sysfs), but
`device.open()` fails with `error.Access` without write permission on the
node.

Grant access to a specific device with a udev rule, for example
`/etc/udev/rules.d/70-my-device.rules`:

```
SUBSYSTEM=="usb", ATTR{idVendor}=="2df0", ATTR{idProduct}=="0007", MODE="0660", TAG+="uaccess"
```

`TAG+="uaccess"` gives the logged in user access; `GROUP="plugdev"` is the
traditional alternative. Reload with:

```sh
sudo udevadm control --reload-rules && sudo udevadm trigger
```

To see which kernel driver owns each interface:

```sh
for d in /sys/bus/usb/devices/*:*; do
    echo "$d -> $(basename "$(readlink "$d/driver")" 2>/dev/null)"
done
```

---

## 14. API reference map

| Area | API | Source |
|---|---|---|
| Session | `Context.init`, `deinit` | [context.zig#L11](src/context.zig#L11) |
| Enumeration | `Context.devices`, `Device.List.init`, `deinit`, `devices`, `Device.List.Iterator.next` | [device_list.zig#L30](src/device_list.zig#L30) |
| Location | `Device.busNumber`, `portNumber`, `address` | [device.zig#L45](src/device.zig#L45) |
| Device descriptor | `Device.deviceDescriptor` → `Device.Descriptor`; `classCode`, `subClassCode`, `vendorId`, `productId` | [device_descriptor.zig](src/device_descriptor.zig) |
| Configuration | `Device.configDescriptor`, `ConfigDescriptor.interfaces` → `InterfaceIterator`, `deinit` | [config_descriptor.zig](src/config_descriptor.zig) |
| Interfaces | `InterfaceDescriptor.number`, `descriptors` → `InterfaceDescriptorsIterator`; `endpointDescriptors` | [interface_descriptor.zig](src/interface_descriptor.zig) |
| Endpoints | `direction`, `transferType`, `number`, `address`, `interval` | [endpoint_descriptor.zig](src/endpoint_descriptor.zig) |
| Enums | `Fields.Direction`, `Fields.TransferType` | [fields.zig](src/fields.zig) |
| Opening | `Device.open`, `Context.openDeviceWithVidPid`, `Context.openDeviceWithFd` | [device.zig#L57](src/device.zig#L57), [context.zig#L30](src/context.zig#L30) |
| Handle | `Device.Handle`: `deinit`, `device`, `claimInterface`, `claimAutoDeatachableInterface`, `releaseInterface`, `setInterfaceAltSetting` | [device_handle.zig#L15](src/device_handle.zig#L15) |
| Control | `writeControl` | [device_handle.zig#L52](src/device_handle.zig#L52) |
| Bulk | `readBulk`, `writeBulk` | [device_handle.zig#L95](src/device_handle.zig#L95) |
| Async | `zusb.Transfer(T).fillIsochronous`, `submit`, `cancel`, `isActive`, `buffer`, `deinit` | [transfer.zig](src/transfer.zig) |
| Iso packets | `PacketDescriptors`, `PacketDescriptor.buffer`, `isCompleted`, `status` | [packet_descriptor.zig](src/packet_descriptor.zig) |
| Events | `Context.handleEvents` | [context.zig#L26](src/context.zig#L26) |
| Errors | `zusb.Error`, `zusb.errorFromLibusb`, `zusb.failable` | [error.zig](src/error.zig) |
| Constants | `Constants.dt_hid` | [constants.zig](src/constants.zig) |
| Options | `disableDeviceDiscovery` (not re-exported) | [options.zig](src/options.zig) |

---

## 15. Current limitations

zusb is a port of [rusb](https://github.com/a1ien/rusb) and does not cover all
of it yet. Known gaps and issues, with workarounds:

| Gap / issue | Workaround |
|---|---|
| No IN control transfers (`readControl`), so no string descriptors or GET_STATUS | Call `libusb_control_transfer(handle.raw, 0x80, ...)` or `libusb_get_string_descriptor_ascii(handle.raw, index, buf, len)` directly |
| No interrupt transfers: `Transfer.fillInterrupt` does not compile | Use `libusb_interrupt_transfer(handle.raw, ...)` |
| `Context.openDeviceWithFd` does not compile (pointer type mismatch) | Call `libusb_wrap_sys_device` and build `Device.Handle{ .ctx, .raw, .interfaces = 0 }`, see [`example/open_fd.zig`](example/open_fd.zig) |
| `endpointDescriptors()` panics on alternate settings with zero endpoints (libusb stores a NULL pointer) | Check `alt.descriptor.bNumEndpoints == 0` before iterating |
| `EndpointDescriptor.number()` masks with `0x07`, wrong for endpoints 8 to 15 | Use `endpoint.address() & 0x0f` |
| `PacketDescriptor.status()` always yields `error.Other` (transfer statuses are not error codes) | Read `packet.descriptor.status` and compare with `LIBUSB_TRANSFER_*` |
| `fillIsochronous` computes `packet_size * num_packets` in `u16` | Keep the product at or below 65535 |
| `claimInterface` detaches the kernel driver and never re-attaches it | Claim with `claimAutoDeatachableInterface` |
| `zusb_dep.module("libusb")` is a different instance from zusb's own import (`file exists in modules 'libusb' and 'libusb0'`) | Use `zusb_mod.import_table.get("libusb").?` |
| The method name is spelled `claimAutoDeatachableInterface` | Use it as spelled |
| No hotplug, configuration selection, halt clearing or device reset wrappers | Use the libusb functions on `ctx.raw` / `handle.raw` |
| `options.zig` is not exported from `zusb.zig` | Import it as its own module in `build.zig` |

Each of these is exercised or documented by the test suite in [`test/`](test/).

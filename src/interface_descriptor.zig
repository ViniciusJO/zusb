const clibusb = @import("libusb");
const EndpointDescriptor = @import("endpoint_descriptor.zig");
const Interface = @import("interface_descriptor.zig");

const Self = @This();

iter: []const clibusb.libusb_interface_descriptor,

pub fn number(self: Self) u8 {
    return self.iter[0].bInterfaceNumber;
}

pub fn descriptors(self: Self) InterfaceDescriptorsIterator {
    return InterfaceDescriptorsIterator{
        .iter = self.iter,
        .i = 0,
    };
}

pub const InterfaceDescriptor = struct {
    descriptor: *const clibusb.libusb_interface_descriptor,

    pub fn endpointDescriptors(self: InterfaceDescriptor) EndpointDescriptors {
        return EndpointDescriptors{
            .iter = self.descriptor.*.endpoint[0..self.descriptor.*.bNumEndpoints],
            .i = 0,
        };
    }
};

pub const EndpointDescriptors = struct {
    iter: []const clibusb.libusb_endpoint_descriptor,
    i: usize,

    pub fn next(self: *EndpointDescriptors) ?EndpointDescriptor {
        if (self.i < self.iter.len) {
            defer self.i += 1;
            return EndpointDescriptor{ .descriptor = &self.iter[self.i] };
        } else {
            return null;
        }
    }
};

pub const InterfaceDescriptorsIterator = struct {
    iter: []const clibusb.libusb_interface_descriptor,
    i: usize,

    pub fn next(self: *InterfaceDescriptorsIterator) ?InterfaceDescriptor {
        if (self.i < self.iter.len) {
            defer self.i += 1;
            return InterfaceDescriptor{ .descriptor = &self.iter[self.i] };
        } else {
            return null;
        }
    }
};


const clibusb = @import("libusb");

const Self = @This();

descriptor: clibusb.libusb_device_descriptor,

pub fn classCode(self: Self) u8 {
    return self.descriptor.bDeviceClass;
}

pub fn subClassCode(self: Self) u8 {
    return self.descriptor.bDeviceSubClass;
}

pub fn vendorId(self: Self) u16 {
    return self.descriptor.idVendor;
}

pub fn productId(self: Self) u16 {
    return self.descriptor.idProduct;
}

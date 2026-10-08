const clibusb = @import("libusb");

pub const Error = error{
    Io,
    InvalidParam,
    Access,
    NoDevice,
    NotFound,
    Busy,
    Timeout,
    Overflow,
    Pipe,
    Interrupted,
    OutOfMemory,
    NotSupported,
    BadDescriptor,
    Other,
};

pub fn errorFromLibusb(err: c_int) Error {
    return switch (err) {
        clibusb.LIBUSB_ERROR_IO => Error.Io,
        clibusb.LIBUSB_ERROR_INVALID_PARAM => Error.InvalidParam,
        clibusb.LIBUSB_ERROR_ACCESS => Error.Access,
        clibusb.LIBUSB_ERROR_NO_DEVICE => Error.NoDevice,
        clibusb.LIBUSB_ERROR_NOT_FOUND => Error.NotFound,
        clibusb.LIBUSB_ERROR_BUSY => Error.Busy,
        clibusb.LIBUSB_ERROR_TIMEOUT => Error.Timeout,
        clibusb.LIBUSB_ERROR_OVERFLOW => Error.Overflow,
        clibusb.LIBUSB_ERROR_PIPE => Error.Pipe,
        clibusb.LIBUSB_ERROR_INTERRUPTED => Error.Interrupted,
        clibusb.LIBUSB_ERROR_NO_MEM => Error.OutOfMemory,
        clibusb.LIBUSB_ERROR_NOT_SUPPORTED => Error.NotSupported,
        clibusb.LIBUSB_ERROR_OTHER => Error.Other,
        else => Error.Other,
    };
}

pub fn failable(err: c_int) Error!void {
    if (err != 0) {
        return errorFromLibusb(err);
    }
}

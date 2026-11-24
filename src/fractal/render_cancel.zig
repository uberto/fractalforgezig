//! Cooperative cancellation for CPU export kernels.
pub const Cancel = struct {
    context: ?*anyopaque = null,
    isCancelled: *const fn (?*anyopaque) bool,

    pub fn check(control: ?Cancel) error{Cancelled}!void {
        if (control) |cancel| {
            if (cancel.isCancelled(cancel.context)) return error.Cancelled;
        }
    }
};

// Leave room for the smoothing tail after the last check in an escape loop.
pub const iteration_interval = 512;

//! Prevent completion while a stop-forwarding callback is using owned state.
const std = @import("std");
pub fn retainUnlessDone(count: *std.atomic.Value(usize)) bool {
    var value = count.load(.acquire);
    while (value != 0) {
        value = count.cmpxchgWeak(value, value + 1, .acq_rel, .acquire) orelse return true;
    }
    return false;
}

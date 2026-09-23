//! Double-start detection. A bool in safety-checked builds; zero-sized in
//! ReleaseFast/ReleaseSmall, so operation storage carries no debug state.
const std = @import("std");

pub const StartGuard = struct {
    started: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},

    pub inline fn begin(self: *StartGuard) void {
        if (std.debug.runtime_safety) {
            std.debug.assert(!self.started);
            self.started = true;
        }
    }
};

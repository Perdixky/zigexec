//! A borrowed, nullable handle. The source must outlive tokens and registrations.
const Source = @import("source.zig");
const Token = @This();
source: ?*Source = null,

pub fn stopRequested(self: Token) bool {
    return if (self.source) |source| source.requested.load(.acquire) else false;
}

pub fn stopPossible(self: Token) bool {
    return self.source != null;
}

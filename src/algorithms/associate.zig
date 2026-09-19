//! Explicitly owned association with a lazy, composable borrowed sender view.
const std = @import("std");
const ex = @import("../root.zig");

pub fn Associated(comptime S: type, comptime Token: type) type {
    const Wrapped = @TypeOf(@as(Token, undefined).wrap(@as(S, undefined)));
    const Association = @TypeOf(@as(Token, undefined).tryAssociate());
    return struct {
        wrapped: Wrapped,
        association: Association,
        const Self = @This();
        pub const Values = S.Values;
        pub const View = ex.Sender(ViewImpl);

        /// One owner per association. Ordinary copies are not ownership clones.
        pub fn deinit(self: *Self) void {
            self.association.deinit();
        }
        pub fn isEngaged(self: Self) bool {
            return self.association.isEngaged();
        }
        pub fn take(self: *Self) Self {
            return .{ .wrapped = self.wrapped, .association = self.association.take() };
        }
        /// Attempts a fresh association; a closed scope produces an empty owner.
        pub fn clone(self: *const Self) Self {
            return .{ .wrapped = self.wrapped, .association = self.association.tryAssociate() };
        }
        /// Borrow until start; start acquires a distinct operation association.
        pub fn sender(self: *Self) View {
            return ex.asSender(ViewImpl{ .owner = self, .transfer = false });
        }
        /// Borrow until start; transfer the existing association on first start.
        /// This permits previously associated work to start after scope.close().
        pub fn takeSender(self: *Self) View {
            return ex.asSender(ViewImpl{ .owner = self, .transfer = true });
        }

        const ViewImpl = struct {
            owner: *Self,
            transfer: bool,
            pub const Values = S.Values;
            pub const can_error = true; // Missing execution lifetime on raw use.
            pub const Operation = struct {
                owner: *Self,
                transfer: bool,
                receiver: ex.Receiver(S.Values),
                association: Association = .{},
                child: Wrapped.Operation = undefined,
                retirement: ex.Scope.Retirement = .{ .prepare = prepare },
                started: bool = false,
                pub fn start(self: *@This()) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    const lifetime = self.receiver.env.scope orelse {
                        self.receiver.setError(error.MissingExecutionScope);
                        return;
                    };
                    self.association = if (self.transfer) self.owner.association.take() else self.owner.association.tryAssociate();
                    if (!self.association.isEngaged()) {
                        self.receiver.setStopped();
                        return;
                    }
                    // Copy/connect before downstream callbacks can destroy owner.
                    self.child = self.owner.wrapped.connect(self.receiver);
                    lifetime.onRetired(&self.retirement);
                    self.child.start();
                }
                fn prepare(record: *ex.Scope.Retirement) ex.Scope.ReleaseAction {
                    const self: *@This() = @fieldParentPtr("retirement", record);
                    return self.association.takeReleaseAction();
                }
            };
            pub fn connect(self: @This(), receiver: ex.Receiver(S.Values)) Operation {
                return .{ .owner = self.owner, .transfer = self.transfer, .receiver = receiver };
            }
        };
    };
}

/// Acquire eagerly without allocating or starting. Deinit unused owners too.
/// Use owner.sender() or owner.takeSender() to compose the lazy work.
pub fn associate(sender: anytype, token: anytype) Associated(@TypeOf(sender), @TypeOf(token)) {
    return .{ .wrapped = token.wrap(sender), .association = token.tryAssociate() };
}

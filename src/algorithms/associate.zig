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
            pub const can_error = true; // Missing cleanup registry on raw use.
            pub fn Operation(comptime R: type) type {
                return struct {
                    owner: *Self,
                    transfer: bool,
                    receiver: ex.TypedReceiver(S.Values, R),
                    association: Association = .{},
                    child: ex.meta.OperationOf(Wrapped, ex.TypedReceiver(S.Values, R)) = undefined,
                    retirement: ex.Scope.Retirement = .{ .prepare = prepare },
                    started: bool = false,
                    pub fn cleanup(self: *@This(), continuation: anytype) void {
                        // Preserve downstream borrows while allowing repeat to
                        // reconstruct this storage, including during completion.
                        if (self.association.isEngaged()) {
                            self.receiver.getEnv().scope.?.remove(&self.retirement);
                            const action = self.association.takeReleaseAction();
                            ex.cleanupOperation(&self.child, continuation);
                            action.run(); // No operation access after continuation.
                        } else ex.cleanupOperation(&self.child, continuation);
                    }
                    pub fn start(self: *@This()) void {
                        std.debug.assert(!self.started);
                        self.started = true;
                        const lifetime = self.receiver.getEnv().scope orelse {
                            self.receiver.setError(error.MissingExecutionScope);
                            return;
                        };
                        self.association = if (self.transfer) self.owner.association.take() else self.owner.association.tryAssociate();
                        if (!self.association.isEngaged()) {
                            self.receiver.setStopped();
                            return;
                        }
                        lifetime.onRetired(&self.retirement);
                        self.child.start();
                    }
                    fn prepare(record: *ex.Scope.Retirement) ex.Scope.ReleaseAction {
                        const self: *@This() = @fieldParentPtr("retirement", record);
                        return self.association.takeReleaseAction();
                    }
                };
            }
            pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
                out.* = .{ .owner = self.owner, .transfer = self.transfer, .receiver = .init(receiver) };
                @import("../execution/protocol.zig").connectChild(&out.child, self.owner.wrapped, out.receiver);
            }
        };
    };
}

/// Acquire eagerly without allocating or starting. Deinit unused owners too.
/// Use owner.sender() or owner.takeSender() to compose the lazy work.
pub fn associate(sender: anytype, token: anytype) Associated(@TypeOf(sender), @TypeOf(token)) {
    return .{ .wrapped = token.wrap(sender), .association = token.tryAssociate() };
}

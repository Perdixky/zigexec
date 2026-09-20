//! Cleanup at an operation storage-reuse boundary. Unlike a registry, this
//! follows the statically known child graph and does no work for plain sources.
//! A cleanup hook must detach owned resources before running the continuation:
//! it may reconstruct or destroy every operation visited here.
pub fn cleanupOperation(operation: anytype, continuation: anytype) void {
    const Op = @typeInfo(@TypeOf(operation)).pointer.child;
    if (@hasDecl(Op, "cleanup")) operation.cleanup(continuation) else continuation.run();
}

/// Children are pointers in destruction order. Copy the continuation before
/// entering a child; nothing in operation storage may be read after it runs.
pub fn cleanupOperations(operations: anytype, continuation: anytype) void {
    cleanupAt(operations, 0, continuation);
}

fn cleanupAt(operations: anytype, comptime index: usize, continuation: anytype) void {
    if (index == operations.len) return continuation.run();
    const Next = struct {
        operations: @TypeOf(operations),
        continuation: @TypeOf(continuation),
        pub fn run(self: @This()) void {
            cleanupAt(self.operations, index + 1, self.continuation);
        }
    };
    cleanupOperation(operations[index], Next{ .operations = operations, .continuation = continuation });
}

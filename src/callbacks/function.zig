/// Adapt a comptime business function to a stateless callback type. Generic
/// functions retain their identity and specialize from upstream argument types.
pub fn Fn(comptime function: anytype) type {
    return struct {
        pub const __zigexec_function = function;
        pub fn callTuple(_: @This(), args: anytype) @TypeOf(@call(.auto, function, args)) {
            return @call(.auto, function, args);
        }
    };
}

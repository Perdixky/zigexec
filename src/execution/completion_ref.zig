//! Borrowed completion. Success storage belongs to an operation in the scope;
//! error and stopped carry no borrowed payload.
pub fn CompletionRef(comptime Values: type) type {
    return union(enum) { value: *const Values, err: anyerror, stopped };
}

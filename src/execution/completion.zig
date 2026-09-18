pub fn Completion(comptime Values: type) type {
    return union(enum) {
        value: Values,
        err: anyerror,
        stopped,
    };
}

/// Unknown custom senders conservatively may report errors. A custom sender may
/// declare can_error = false as a protocol contract, checked at the spawn boundary.
pub fn canError(comptime S: type) bool {
    return if (@hasDecl(S, "can_error")) S.can_error else true;
}
pub fn fallible(comptime T: type) bool {
    if (@typeInfo(T) != .error_union) return false;
    const errors = @typeInfo(@typeInfo(T).error_union.error_set).error_set.error_names;
    return if (errors) |set| set.len != 0 else true;
}

/// Scheduler protocol: schedule() returns an ordinary sender with empty Values.
pub fn schedule(scheduler: anytype) @TypeOf(scheduler.schedule()) {
    return scheduler.schedule();
}

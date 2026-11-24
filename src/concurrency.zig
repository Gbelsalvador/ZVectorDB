const std = @import("std");

/// Small non-blocking mutex for synchronous code that does not carry an Io value.
pub const Mutex = struct {
    state: u8 = 0,

    pub fn lock(self: *Mutex) void {
        while (@cmpxchgWeak(u8, &self.state, 0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        @atomicStore(u8, &self.state, 0, .release);
    }
};

/// Readers may enter together. A writer waits for all current readers and
/// prevents new ones from entering until it releases the lock.
pub const RwLock = struct {
    state: usize = 0,

    const writer_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);

    pub fn lock(self: *RwLock) void {
        while (@cmpxchgWeak(usize, &self.state, 0, writer_bit, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *RwLock) void {
        @atomicStore(usize, &self.state, 0, .release);
    }

    pub fn lockShared(self: *RwLock) void {
        while (true) {
            const state = @atomicLoad(usize, &self.state, .acquire);
            if (state & writer_bit != 0) {
                std.atomic.spinLoopHint();
                continue;
            }
            if (@cmpxchgWeak(usize, &self.state, state, state + 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        _ = @atomicRmw(usize, &self.state, .Sub, 1, .release);
    }
};

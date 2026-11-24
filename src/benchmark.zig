const std = @import("std");
const builtin = @import("builtin");
const HNSW = @import("hnsw.zig").HNSW;
const vector = @import("vector.zig");

const DIMENSION = 128;
const DATASET_SIZE = 10_000;
const QUERY_COUNT = 1_000;
const K = 10;

/// Counts allocations routed through this allocator and tracks live/peak bytes.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: u64 = 0,
    allocated_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.allocated_bytes += len;
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
    }
};

const ProcessMetrics = struct { cpu_100ns: ?u64 = null, working_set_bytes: ?usize = null };

const FileTime = extern struct { low: u32, high: u32 };
const ProcessMemoryCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessTimes(
    process: ?*anyopaque,
    creation: *FileTime,
    exit: *FileTime,
    kernel: *FileTime,
    user: *FileTime,
) callconv(.winapi) i32;
extern "psapi" fn GetProcessMemoryInfo(process: ?*anyopaque, counters: *ProcessMemoryCounters, size: u32) callconv(.winapi) i32;

fn fileTimeValue(value: FileTime) u64 {
    return (@as(u64, value.high) << 32) | value.low;
}

fn processMetrics() ProcessMetrics {
    if (comptime builtin.os.tag != .windows) return .{};
    const process = GetCurrentProcess() orelse return .{};
    var creation: FileTime = undefined;
    var exit: FileTime = undefined;
    var kernel: FileTime = undefined;
    var user: FileTime = undefined;
    var metrics = ProcessMetrics{};
    if (GetProcessTimes(process, &creation, &exit, &kernel, &user) != 0) {
        metrics.cpu_100ns = fileTimeValue(kernel) + fileTimeValue(user);
    }
    var memory: ProcessMemoryCounters = undefined;
    memory.cb = @sizeOf(ProcessMemoryCounters);
    if (GetProcessMemoryInfo(process, &memory, @sizeOf(ProcessMemoryCounters)) != 0) {
        metrics.working_set_bytes = memory.working_set_size;
    }
    return metrics;
}

fn percentile(sorted: []const u64, p: usize) u64 {
    if (sorted.len == 0) return 0;
    const index = (sorted.len * p + 99) / 100 - 1;
    return sorted[@min(index, sorted.len - 1)];
}

pub fn main(init: std.process.Init) !void {
    const base_allocator = init.gpa;
    const io = init.io;
    var random_state = std.Random.DefaultPrng.init(42);
    const random = random_state.random();

    const dataset = try base_allocator.alloc(f32, DATASET_SIZE * DIMENSION);
    defer base_allocator.free(dataset);
    for (dataset) |*value| value.* = random.float(f32) * 2.0 - 1.0;

    var hnsw = HNSW.init(base_allocator, DIMENSION, 16, 100, 100);
    defer hnsw.deinit();
    for (0..DATASET_SIZE) |id| {
        const start = id * DIMENSION;
        _ = try hnsw.insert(dataset[start .. start + DIMENSION], random);
    }

    const query = try base_allocator.alloc(f32, DIMENSION);
    defer base_allocator.free(query);
    for (query) |*value| value.* = random.float(f32) * 2.0 - 1.0;

    const latencies = try base_allocator.alloc(u64, QUERY_COUNT);
    defer base_allocator.free(latencies);
    const process_before = processMetrics();
    const run_start = std.Io.Clock.awake.now(io);

    for (latencies) |*latency| {
        var stats = vector.DistanceStats{};
        const start = std.Io.Clock.awake.now(io);
        const results = try hnsw.search(query, base_allocator, K, &stats);
        latency.* = @intCast(start.untilNow(io, .awake).nanoseconds);
        base_allocator.free(results);
    }

    const elapsed = run_start.untilNow(io, .awake).nanoseconds;
    const process_after = processMetrics();
    std.sort.pdq(u64, latencies, {}, std.sort.asc(u64));
    const elapsed_ns: u64 = @intCast(@max(1, elapsed));
    const throughput = @as(f64, @floatFromInt(QUERY_COUNT)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));

    // Count every temporary HNSW search allocation in a separate pass so the
    // tracking allocator does not distort the latency/throughput results.
    var counted = CountingAllocator{ .child = base_allocator };
    const counting_allocator = counted.allocator();
    for (0..QUERY_COUNT) |_| {
        var stats = vector.DistanceStats{};
        const results = try hnsw.search(query, counting_allocator, K, &stats);
        counting_allocator.free(results);
    }

    std.debug.print(
        \\HNSW benchmark ({d} vectors, {d} dimensions, {d} queries)
        \\  Throughput: {d:.2} queries/s
        \\  Latency mean: {d:.2} us
        \\  P50: {d:.2} us
        \\  P95: {d:.2} us
        \\  P99: {d:.2} us
        \\  CPU: {s}
        \\  RAM working set: {s}
        \\  Allocations: {d} calls, {d} bytes total, {d} bytes peak live
        \\
    , .{
        DATASET_SIZE,
        DIMENSION,
        QUERY_COUNT,
        throughput,
        @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, QUERY_COUNT) / 1_000.0,
        @as(f64, @floatFromInt(percentile(latencies, 50))) / 1_000.0,
        @as(f64, @floatFromInt(percentile(latencies, 95))) / 1_000.0,
        @as(f64, @floatFromInt(percentile(latencies, 99))) / 1_000.0,
        cpuLabel(process_before, process_after, elapsed_ns),
        memoryLabel(process_after),
        counted.allocations,
        counted.allocated_bytes,
        counted.peak_live_bytes,
    });
}

fn cpuLabel(before: ProcessMetrics, after: ProcessMetrics, wall_ns: u64) []const u8 {
    const start = before.cpu_100ns orelse return "unavailable on this platform";
    const end = after.cpu_100ns orelse return "unavailable on this platform";
    const cpu_ns = (end - start) * 100;
    const utilization = @as(f64, @floatFromInt(cpu_ns)) * 100.0 / @as(f64, @floatFromInt(wall_ns));
    return std.fmt.allocPrint(std.heap.page_allocator, "{d:.1}% process CPU", .{utilization}) catch "unavailable";
}

fn memoryLabel(metrics: ProcessMetrics) []const u8 {
    const bytes = metrics.working_set_bytes orelse return "unavailable on this platform";
    return std.fmt.allocPrint(std.heap.page_allocator, "{d:.2} MiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "unavailable";
}

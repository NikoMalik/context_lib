const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const epoll = switch (builtin.os.tag) {
    .linux => std.posix.fd_t,
    // .windows => std.iocp
    //.macos => kqueue
};

pub const EVENT = linux.epoll_event;
pub const EVENT_SIZE = 2;

pub const Nanosecond = 1;
pub const MicroSecond = 1000 * Nanosecond;
pub const Millisecond = 1000 * MicroSecond;
pub const Second = 1000 * Millisecond;
pub const Minute = 60 * Second;
pub const Hour = 60 * Second;

//pub const EPOLL = struct {
//     pub const CLOEXEC = 1 << @bitOffsetOf(O, "CLOEXEC");
//
//     pub const CTL_ADD = 1;
//     pub const CTL_DEL = 2;
//     pub const CTL_MOD = 3;
//
//     pub const IN = 0x001;
//     pub const PRI = 0x002;
//     pub const OUT = 0x004;
//     pub const RDNORM = 0x040;
//     pub const RDBAND = 0x080;
//     pub const WRNORM = if (is_mips) 0x004 else 0x100;
//     pub const WRBAND = if (is_mips) 0x100 else 0x200;
//     pub const MSG = 0x400;
//     pub const ERR = 0x008;
//     pub const HUP = 0x010;
//     pub const RDHUP = 0x2000;
//     pub const EXCLUSIVE = (@as(u32, 1) << 28);
//     pub const WAKEUP = (@as(u32, 1) << 29);
//     pub const ONESHOT = (@as(u32, 1) << 30);
//     pub const ET = (@as(u32, 1) << 31);
// };

// pub const CLOCK = clockid_t;
//
// pub const clockid_t = enum(u32) {
//     REALTIME = 0,
//     MONOTONIC = 1,
//     PROCESS_CPUTIME_ID = 2,
//     THREAD_CPUTIME_ID = 3,
//     MONOTONIC_RAW = 4,
//     REALTIME_COARSE = 5,
//     MONOTONIC_COARSE = 6,
//     BOOTTIME = 7,
//     REALTIME_ALARM = 8,
//     BOOTTIME_ALARM = 9,
//=============================================================//
//TODO: PROTECT FROM RACE DATA,ADD MUTEXES,MAKE MOR FREANDLY API
//=============================================================//
pub const Context = struct {
    // CONTEXT 0 IS MAIN
    // OTHER CONTEXTS IS CHILD
    id: usize,
    allocator: Allocator,
    epfd: posix.fd_t,
    cancelFd: posix.fd_t,
    cancelled: Atomic(bool),
    is_deinited: Atomic(bool) = Atomic(bool).init(false),
    timerfd: ?posix.fd_t,
    deadline: ?u64,
    parent: ?*Context,
    children: std.ArrayList(*Context),
    values: ?std.StringHashMap(?*anyopaque) = null,
    const Self = @This();

    pub fn init(
        allocator: Allocator,
    ) !Self {
        const epfd = try posix.epoll_create1(0);
        errdefer posix.close(epfd); // check err

        const cancel_fd = try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);

        errdefer posix.close(cancel_fd); // check err

        const timer_fd = linux.timerfd_create(linux.timerfd_clockid_t.MONOTONIC, linux.TFD{
            .NONBLOCK = true,
        });
        errdefer posix.close(timer_fd); // check err

        var event = EVENT{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = cancel_fd },
        };
        const err_ctl_1 = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, cancel_fd, &event);
        if (err_ctl_1 == -1) {
            posix.close(epfd);
            posix.close(cancel_fd);
            posix.close(timer_fd);
            std.log.err("Epoll Create Failed: {d}", .{err_ctl_1});
            return error.EPOLL_CTL_ERROR_creation;
        }

        event.data.fd = @intCast(timer_fd);
        const err_ctl_2_timer = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, @intCast(timer_fd), &event);
        if (err_ctl_2_timer == -1) {
            posix.close(epfd);
            posix.close(cancel_fd);
            posix.close(timer_fd);

            std.log.err("Epoll Create Failed Timer :{d}", .{err_ctl_2_timer});
            return error.EPOLL_CTL_ERROR_creation;
        }

        return Self{
            .id = 0,
            .allocator = allocator,
            .parent = null,
            .epfd = epfd,
            .cancelFd = cancel_fd,
            .timerfd = @intCast(timer_fd),
            .deadline = null,
            .cancelled = Atomic(bool).init(false),
            .children = std.ArrayList(*Context).init(allocator),
            .values = std.StringHashMap(?*anyopaque).init(allocator),
        };
    }

    pub fn withCancel(
        parent: *Self,
    ) !*Self {
        const allocator = parent.allocator;
        var child = try allocator.create(Self);
        child.* = try Context.init(allocator);
        child.parent = parent;
        try parent.children.append(child);
        child.id = 1 + child.id;

        return child;
    }

    pub fn deinit(
        self: *Self,
    ) void {
        if (self.is_deinited.load(.acquire)) return;
        self.is_deinited.store(true, .release);

        if (self.parent == null) { // if parent == null
            for (self.children.items) |child| { // cleanup children
                // child.values.?.deinit(self.allocator);
                if (child.values) |*values| {
                    values.deinit();
                }
                child.deinit();
                self.allocator.destroy(child);
            }
            self.children.deinit();

            if (self.values) |*vals| {
                vals.deinit();
                self.values = null;
            }
            posix.close(self.epfd);
            posix.close(self.cancelFd);
            if (self.timerfd) |fd| posix.close(fd);
            std.debug.print("succeded clean: context{d}\n", .{self.id});

            return;
        }
        // ONLY PARENT CAN CLEANUP VALUES
        // ================================//
        // if (self.values) |*vals| {
        //     vals.deinit(self.allocator);
        //     self.values = null;
        // }
        // ================================//

        posix.close(self.epfd);
        posix.close(self.cancelFd);
        if (self.timerfd) |fd| posix.close(fd);

        std.debug.print("succeded clean: context{d}\n", .{self.id});
    }
    pub fn cancel(
        self: *Self,
    ) void {
        if (!self.cancelled.swap(true, .seq_cst)) {
            const val: u64 = 1;
            _ = posix.write(self.cancelFd, std.mem.asBytes(&val)) catch {};
            // for (self.children.items) |child| {
            //     child.cancel();
            // }
        }
    }

    pub inline fn isCancelled(
        self: *Self,
    ) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn setDeadline(
        self: *Self,
        timeout_ns: u64,
    ) !void {
        if (self.timerfd == null) return error.TimerNotInitialized;
        const ts = linux.timespec{
            .sec = @intCast(timeout_ns / 1_000_000_000),
            .nsec = @intCast(timeout_ns % 1_000_000_000),
        };

        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },

            .it_value = ts,
        };

        _ = linux.timerfd_settime(self.timerfd.?, linux.TFD.TIMER{}, &spec, null);
        self.deadline = timeout_ns;
    }

    pub fn setValue(
        self: *Self,
        key: []const u8,
        value: ?*anyopaque,
    ) !void {
        if (self.values == null) {
            self.values = std.StringHashMap(?*anyopaque).init(self.allocator);
        }
        if (self.values.?.contains(key)) {
            std.debug.print("Overwriting key '{s}' in context {d}\n", .{ key, self.id });
        }
        std.debug.print("Hash table size before put: {}\n", .{self.values.?.count()});
        try self.values.?.put(key, value);
        std.debug.print("Hash table size after put: {}\n", .{self.values.?.count()});
    }
    pub fn getValue(
        self: *Self,
        key: []const u8,
    ) ?*anyopaque {
        if (self.cancelled.load(.acquire)) {
            std.log.err("Context cancelled, values destroyed\n", .{});
            return null;
        }
        var visited = std.AutoHashMap(*Context, void).init(self.allocator);
        defer visited.deinit();

        return self.getValueRecursive(key, &visited);
    }

    fn getValueRecursive(
        self: *Self,
        key: []const u8,
        visited: *std.AutoHashMap(*Context, void),
    ) ?*anyopaque {
        std.debug.print("Check Context: {d}, key: {s}\n", .{ self.id, key });
        if (visited.contains(self)) return null;
        visited.put(self, {}) catch return null;
        visited.put(self, {}) catch |err| {
            std.log.err(" visited: {}", .{err});
            return null;
        };

        if (self.values) |values| {
            if (values.get(key)) |val| {
                return val;
            }
        }

        if (self.parent) |parent| {
            return parent.getValueRecursive(key, visited);
        }

        return null;
    }
    pub fn wait(
        self: *Self,
        events: []linux.epoll_event,
    ) !usize {
        while (true) {
            const count = linux.epoll_wait(
                self.epfd,
                events.ptr,
                @intCast(events.len),
                -1,
            );
            if (count < 0) {
                switch (posix.errno(count)) {
                    .INTR => continue,
                    else => |err| return posix.unexpectedErrno(err),
                }

                return error.EpollWaitFailed;
            }
            for (events[0..count]) |*ev| {
                const fd = ev.data.fd;
                if (fd == self.cancelFd) {
                    var buf: [8]u8 = undefined;
                    _ = posix.read(self.cancelFd, &buf) catch {};

                    self.cancelled.store(true, .release);
                } else if (fd == self.timerfd) {
                    var buf: [8]u8 = undefined;
                    _ = posix.read(self.timerfd.?, &buf) catch {};

                    self.cancel();
                }
            }

            return count;
        }
    }

    fn eventLoop(
        self: *Self,
    ) !void {
        var events: [64]linux.epoll_event = undefined;

        while (!self.isCancelled()) {
            // eventLoop
            _ = try self.wait(&events);
        }
    }
};
test "context deadline with timerfd" {
    var db = std.heap.DebugAllocator(.{}){};
    defer _ = db.deinit();
    const allocator = db.allocator();
    const start = std.time.nanoTimestamp();
    //==========================================//
    var ctx = try Context.init(allocator);
    defer ctx.deinit();
    try ctx.setDeadline(100 * Millisecond);
    try ctx.eventLoop();
    //===========================================//

    const duration = @divTrunc((std.time.nanoTimestamp() - start), std.time.ns_per_ms);

    std.debug.print("make some changes\n duration: {d}\n", .{duration});
    assert(duration > 0);

    try std.testing.expect(duration >= 90);
    try std.testing.expect(ctx.isCancelled());
}

test "context cancellation" {
    var db = std.heap.DebugAllocator(.{}){};
    defer _ = db.deinit();
    const allocator = db.allocator();

    var ctx = try Context.init(allocator);
    defer ctx.deinit();
    try ctx.setDeadline(100 * Millisecond);
    try ctx.eventLoop();

    try long_running_task(&ctx);

    const thread = try std.Thread.spawn(.{}, long_running_task, .{&ctx});
    defer thread.join();

    // std.time.sleep(50 * std.time.ns_per_ms);
    // ctx.cancel();

    try std.testing.expect(ctx.isCancelled());
}

test "parent and child " {
    var db = std.heap.DebugAllocator(.{}){};
    defer _ = db.deinit();
    const allocator = db.allocator();

    // PARENT context
    var parent = try Context.init(allocator);
    defer parent.deinit();
    // try parent.eventLoop();

    // CHILD context
    var child = try Context.withCancel(&parent);
    defer child.deinit();

    try child.setDeadline(100_000_000); // 100ms

    // SET OUR VALUE
    var value = "request_id_123";

    try child.setValue("request_id", @ptrCast(&value));

    const get_value = child.getValue("request_id");
    std.debug.print("value: {s}\n", .{@as(*[]const u8, @ptrCast(@alignCast(get_value))).*});
    try child.eventLoop();

    std.time.sleep(200_000_000); // 200ms
}

test "value propagation" {
    var db = std.heap.DebugAllocator(.{}){};
    defer _ = db.deinit();
    const allocator = db.allocator();

    var parent = try Context.init(allocator);
    defer parent.deinit();

    var child = try Context.withCancel(&parent);
    defer child.deinit();

    var test_value = "parent_value";
    try parent.setValue("key", (@ptrCast(&test_value)));

    const received = child.getValue("key");

    if (received) |val_ptr| {
        const str = @as(*[]const u8, @alignCast(@ptrCast(val_ptr))).*;
        std.debug.print("value: {s}\n", .{str});
        try std.testing.expectEqualStrings(test_value, str);
    } else {
        std.debug.print("No value found\n", .{});
        try std.testing.expect(false);
    }
    return;
}
//
fn long_running_task(ctx: *Context) !void {
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        if (ctx.isCancelled()) {
            std.debug.print("Operation cancelled\n", .{});
            return;
        }
        std.time.sleep(100_000_000);
    }
}

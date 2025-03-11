const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Atomic = std.atomic.Value;

const epoll = switch (builtin.os.tag) {
    .linux => std.posix.fd_t,
    // .windows => std.iocp
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

pub const Context = struct {
    epfd: posix.fd_t,
    cancelFd: posix.fd_t,
    cancelled: Atomic(bool),
    timerfd: ?posix.fd_t,
    deadline: ?u64,

    const Self = @This();

    pub fn init() !Self {
        const epfd = try posix.epoll_create1(0);
        errdefer posix.close(epfd);

        const cancel_fd = try posix.eventfd(0, linux.EFD.NONBLOCK);

        errdefer posix.close(cancel_fd);

        const timer_fd = linux.timerfd_create(linux.timerfd_clockid_t.MONOTONIC, linux.TFD{
            .NONBLOCK = true,
        });
        errdefer posix.close(timer_fd);

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = cancel_fd },
        };
        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, cancel_fd, &event);

        event.data.fd = @intCast(timer_fd);
        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, @intCast(timer_fd), &event);

        return Self{
            .epfd = epfd,
            .cancelFd = cancel_fd,
            .timerfd = @intCast(timer_fd),
            .deadline = null,

            .cancelled = Atomic(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.epfd);
        posix.close(self.cancelFd);
        posix.close(self.timerfd.?);
    }

    pub fn cancel(self: *Self) void {
        if (!self.cancelled.swap(true, .seq_cst)) {
            const val: u64 = 1;
            _ = posix.write(self.cancelFd, std.mem.asBytes(&val)) catch {};
        }
    }

    pub inline fn isCancelled(self: *Self) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn setDeadline(self: *Self, timeout_ns: u64) !void {
        const ts = linux.timespec{
            .sec = @intCast(timeout_ns / 1_000_000_000),
            .nsec = @intCast(timeout_ns % 1_000_000_000),
        };

        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },

            .it_value = ts,
        };

        _ = linux.timerfd_settime(self.timerfd.?, linux.TFD.TIMER{}, &spec, null);
    }

    pub fn wait(self: *Self, events: []linux.epoll_event) !usize {
        const count = linux.epoll_wait(
            self.epfd,
            events.ptr,
            @intCast(events.len),
            -1,
        );

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
};
test "context deadline with timerfd" {
    var ctx = try Context.init();
    defer ctx.deinit();

    try ctx.setDeadline(100 * std.time.ns_per_ms);

    const start = std.time.nanoTimestamp();
    var events: [EVENT_SIZE]EVENT = undefined;

    _ = try ctx.wait(&events);
    std.debug.print("in\n", .{});

    const duration = @divTrunc((std.time.nanoTimestamp() - start), std.time.ns_per_ms);

    std.debug.print("make some changes\n", .{});
    try std.testing.expect(duration >= 90);
    try std.testing.expect(ctx.isCancelled());
}

test "context cancellation" {
    var ctx = try Context.init();
    defer ctx.deinit();

    try ctx.setDeadline(100 * Millisecond);
    var events: [2]linux.epoll_event = undefined;
    _ = try ctx.wait(&events);

    const thread = try std.Thread.spawn(.{}, long_running_task, .{&ctx});
    defer thread.join();

    // std.time.sleep(50 * std.time.ns_per_ms);
    ctx.cancel();

    try std.testing.expect(ctx.isCancelled());
}
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

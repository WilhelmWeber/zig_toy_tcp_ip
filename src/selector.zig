const std = @import("std");
const posix = std.posix;
const channel = @import("channel.zig");

pub const SelectTimeout = error{Timeout};

pub const Select = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    epoll_fd: posix.fd_t,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .epoll_fd = try posix.epoll_create1(0),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.epoll_fd);
        self.allocator.destroy(self);
    }

    // 監視対象チャネルを追加
    pub fn add(self: *Self, fd: posix.fd_t) !void {
        var ev = std.os.linux.epoll_event{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = fd } };
        try posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &ev);
    }

    pub fn wait(self: *Self) !posix.fd_t {
        var events: [1]std.os.linux.epoll_event = undefined;
        //TODO: エラーチェックと timeout
        const n = posix.epoll_wait(self.epoll_fd, &events, -1);
        if (n == 0) return error.Timeout;

        // epoll で通知されたことを前提に event_fd を消費
        var tmp: [8]u8 = undefined;
        _ = try posix.read(events[0].data.fd, &tmp);

        return events[0].data.fd;
    }
};

const std = @import("std");
const posix = std.posix;

pub const ChannelError = error{
    QueueFull,
    QueueEmpty,
};

/// スレッド間通信を行うためのチャネル
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        buf: []T,
        capa: usize,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        // 送信イベント通知用
        event_fd: posix.fd_t,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capa: usize) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .buf = try allocator.alloc(T, capa),
                .capa = capa,
                .event_fd = try posix.eventfd(0, 0),
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
            posix.close(self.event_fd);
            self.allocator.destroy(self);
        }

        pub fn send(self: *Self, val: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count >= self.capa) {
                return error.QueueFull;
            }

            self.buf[self.tail] = val;
            self.tail = (self.tail + 1) % self.capa;
            self.count += 1;

            // 通知
            const n: u64 = 1;
            _ = try posix.write(self.event_fd, std.mem.asBytes(&n));
        }

        pub fn recv_no_wait(self: *Self) !T {
            // チャンネルから値を取り出す
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) {
                return error.QueueEmpty;
            }
            const val = self.buf[self.head];
            self.head = (self.head + 1) % self.capa;
            self.count -= 1;

            return val;
        }

        pub fn recv(self: *Self) !T {
            var tmp: [8]u8 = undefined;
            _ = try posix.read(self.event_fd, &tmp);

            return self.recv_no_wait();
        }

        pub fn getEventFd(self: *Self) posix.fd_t {
            return self.event_fd;
        }
    };
}

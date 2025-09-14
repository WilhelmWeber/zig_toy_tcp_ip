const std = @import("std");
const ch = @import("channel.zig");
const select = @import("selector.zig");
const posix = std.posix;
const linux = std.os.linux;

const PACKET_SIZE = 2048;

pub const NetworkError = error{
    ReadError,
    WriteError,
};

pub const Packet = struct {
    buf: [PACKET_SIZE]u8,
    n: usize,
};

fn perrorZ(prefix: [:0]const u8) void {
    const msg = "hi!";
    const stderr = std.io.getStdErr().writer();
    stderr.print("{s}: {s}\n", .{ prefix, msg }) catch {};
}

fn read_worker_wrapped(n: *raw_sock) void {
    n.read_worker();
}

fn write_worker_wrapped(n: *raw_sock) void {
    n.write_worker();
}

pub const raw_sock = struct {
    const Self = @This();
    raw_sock: posix.fd_t,
    allocator: std.mem.Allocator,
    incomingQueue: *ch.Channel(Packet),
    outgoingQueue: *ch.Channel(Packet),
    // キャンセル通知用の event_fd
    cancelEvent: posix.fd_t,
    // 読み取り worker
    readWorker: std.Thread,
    // 書き込み worker
    writeWorker: std.Thread,

    pub fn new(allocator: std.mem.Allocator) !*Self {
        const ret = try allocator.create(Self);

        // raw socket IPV4
        const fd: posix.socket_t = try posix.socket(linux.AF.INET, linux.SOCK.RAW, linux.IPPROTO.TCP);

        // IP_HDRINCL を有効化する
        var one: c_int = 1;
        try posix.setsockopt(fd, linux.IPPROTO.IP, linux.IP.HDRINCL, std.mem.asBytes(&one));

        ret.* = .{
            .raw_sock = fd,
            .allocator = allocator,
            .incomingQueue = try ch.Channel(Packet).init(allocator, 10),
            .outgoingQueue = try ch.Channel(Packet).init(allocator, 10),
            .cancelEvent = try std.posix.epoll_create1(0),
            .readWorker = undefined,
            .writeWorker = undefined,
        };

        return ret;
    }

    pub fn bind(self: *Self) !void {
        const read_worker_thread = try std.Thread.spawn(.{}, read_worker_wrapped, .{self});
        const write_worker_thread = try std.Thread.spawn(.{}, write_worker_wrapped, .{self});

        self.readWorker = read_worker_thread;
        self.writeWorker = write_worker_thread;
    }

    pub fn read(self: *Self) !Packet {
        const packet = try self.incomingQueue.recv();
        return packet;
    }

    pub fn write(self: *Self, pkt: Packet) !void {
        try self.outgoingQueue.send(pkt);
    }

    pub fn delete(self: *Self) void {
        const n: u64 = 1;
        posix.close(self.raw_sock);

        // read_worker と write_worker を join する
        _ = std.posix.write(self.cancelEvent, std.mem.asBytes(&n)) catch return;
        self.readWorker.join();
        _ = std.posix.write(self.cancelEvent, std.mem.asBytes(&n)) catch return;
        self.writeWorker.join();

        posix.close(self.cancelEvent);
        self.incomingQueue.deinit();
        self.outgoingQueue.deinit();
        self.allocator.destroy(self);
    }

    fn _read(self: *Self, buf: []const u8) !usize {
        const fileno: usize = @intCast(self.raw_sock);
        const ret = std.os.linux.syscall3(std.os.linux.SYS.read, fileno, @intFromPtr(buf.ptr), buf.len);
        if (ret < 0) {
            perrorZ("read()");
            return error.ReadError;
        }
        return ret;
    }

    fn _write(self: *Self, buf: []const u8) !usize {
        const fileno: usize = @intCast(self.raw_sock);
        const ret = std.os.linux.syscall3(std.os.linux.SYS.write, fileno, @intFromPtr(buf.ptr), buf.len);
        if (ret < 0) {
            perrorZ("write");
            return error.WriteError;
        }
        return ret;
    }

    fn read_worker(self: *Self) void {
        const sel = select.Select.init(self.allocator) catch return;
        defer sel.deinit();

        // CLOCK_MONOTONIC ベースの timerfd を作る
        const tfd = posix.timerfd_create(posix.CLOCK.MONOTONIC, .{ .CLOEXEC = true }) catch return;
        defer posix.close(tfd);

        const timer_spec: linux.itimerspec = .{
            .it_interval = .{ .tv_sec = 2, .tv_nsec = 0 },
            .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
        };
        posix.timerfd_settime(tfd, .{}, &timer_spec, null) catch return;

        sel.add(self.cancelEvent) catch return;
        sel.add(tfd) catch return;

        while (true) {
            const ready = sel.wait() catch continue;

            if (ready == self.cancelEvent) {
                return;
            } else if (ready == tfd) {
                const buf: [PACKET_SIZE]u8 = undefined;
                const n = self._read(buf[0..]) catch continue;
                var packet: Packet = undefined;
                std.mem.copyForwards(u8, &packet.buf, &buf);
                packet.n = n;

                self.incomingQueue.send(packet) catch continue;
            }
        }
    }

    fn write_worker(self: *Self) void {
        const sel = select.Select.init(self.allocator) catch return;
        defer sel.deinit();

        const write_event = self.outgoingQueue.getEventFd();
        sel.add(write_event) catch return;
        sel.add(self.cancelEvent) catch return;

        while (true) {
            const ready = sel.wait() catch continue;

            if (ready == self.cancelEvent) {
                return;
            } else if (ready == write_event) {
                const packet = self.outgoingQueue.recv() catch continue;
                _ = self._write(packet.buf[0..]) catch continue;
            }
        }
    }
};

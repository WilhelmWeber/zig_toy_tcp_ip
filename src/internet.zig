const std = @import("std");
const ch = @import("channel.zig");
const select = @import("selector.zig");
const network = @import("network.zig");
const posix = std.posix;

const IP_VERSION = 4;
const IHL = 5;
const TOS = 0;
const TTL = 64;
const LENGTH = IHL * 4;
const TCP_PROTOCOL = 6;
const IP_HEADER_MIN_LEN = 20;
const QUEUE_SIZE = 10;

const InternetError = error{
    InvalidIPHeader,
};

fn read_worker_wrapped(i: *IPPacketQueue, s: *network.raw_sock) void {
    i.read_worker(s);
}

fn write_worker_wrapped(i: *IPPacketQueue, s: *network.raw_sock) void {
    i.write_worker(s);
}

pub const IpHeader = struct {
    version: u8,
    ihl: u8,
    tos: u8,
    total_length: u16,
    id: u16,
    flags: u8,
    fragment_offset: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src_ip: [4]u8,
    dst_ip: [4]u8,

    fn setCheckSum(self: @This(), pkt: []const u8) void {
        const pkt_len = pkt.len;
        var check_sum: u32 = 0;

        var i = 0;
        while (i < pkt_len) : (i += 2) {
            const added: usize = @intCast(std.mem.readInt(u16, pkt[i .. i + 2], .big));
            check_sum += added;
        }

        while (check_sum > 0xffff) {
            check_sum = (check_sum & 0xffff) + (check_sum >> 16);
        }

        const check_sum_u16: u16 = @intCast(check_sum);
        self.checksum = ~check_sum_u16;
    }

    /// ipHeader から バッファ列への変換
    /// need to delete after using
    pub fn marshal(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        const version_and_ihl: u8 = self.version << 4 | self.ihl;
        const flags_and_fragment_offset: u16 = (self.fragment_offset << 13) | (self.flags & 0x1fff);

        var buf = try allocator.alloc(u8, IP_HEADER_MIN_LEN);

        buf[0] = version_and_ihl;
        buf[1] = self.tos;
        std.mem.writeInt(u16, buf[2..4], self.total_length, .big);
        std.mem.writeInt(u16, buf[4..6], self.id, .big);
        std.mem.writeInt(u16, buf[6..8], flags_and_fragment_offset, .big);
        buf[8] = self.ttl;
        buf[9] = self.protocol;
        std.mem.writeInt(u16, buf[10..12], self.checksum, .big);
        std.mem.copyForwards(u8, buf[12..16], &self.src_ip);
        std.mem.copyForwards(u8, buf[16..20], &self.dst_ip);

        //TODO: チェックサムの計算
        self.setCheckSum(buf);
        std.mem.writeInt(u16, buf[10..12], self.checksum, .big);

        return buf;
    }

    pub fn print(self: @This()) void {
        const s =
            "version: {}\n" ++
            "ihl: {}\n" ++
            "tos: {}\n" ++
            "total length: {}\n" ++
            "id: {}\n" ++
            "flags: {}\n" ++
            "fragment offset: {}\n" ++
            "ttl: {}\n" ++
            "protocol: {}\n" ++
            "checksum: {}\n" ++
            "source_ip: {}.{}.{}.{}\n" ++
            "dest_ip: {}.{}.{}.{}\n\n";
        std.debug.print(s, .{ self.version, self.ihl, self.tos, self.total_length, self.id, self.flags, self.fragment_offset, self.ttl, self.protocol, self.checksum, self.src_ip[0], self.src_ip[1], self.src_ip[2], self.src_ip[3], self.dst_ip[0], self.dst_ip[1], self.dst_ip[2], self.dst_ip[3] });
    }
};

const ipPacket = struct {
    header: IpHeader,
    packet: network.Packet,
};

/// バイト列から IP ヘッダへ
pub fn unmarshal(pkt: []const u8) !IpHeader {
    if (pkt.len < IP_HEADER_MIN_LEN) {
        return error.InvalidIPHeader;
    }

    var header: IpHeader = .{
        .version = pkt[0] >> 4,
        .ihl = pkt[0] & 0x0f,
        .tos = pkt[1],
        .total_length = std.mem.readInt(u16, pkt[2..4], .big),
        .id = std.mem.readInt(u16, pkt[4..6], .big),
        .flags = pkt[6] >> 5,
        .fragment_offset = std.mem.readInt(u16, pkt[6..8], .big) & 0x1fff,
        .ttl = pkt[8],
        .protocol = pkt[9],
        .checksum = std.mem.readInt(u16, pkt[10..12], .big),
        .src_ip = undefined,
        .dst_ip = undefined,
    };

    std.mem.copyForwards(u8, &header.src_ip, pkt[12..16]);
    std.mem.copyForwards(u8, &header.dst_ip, pkt[16..20]);

    return header;
}

pub const IPPacketQueue = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    incomingQueue: *ch.Channel(ipPacket),
    outgoingQueue: *ch.Channel(network.Packet),
    cancelEvent: posix.fd_t,
    readWorker: std.Thread,
    writeWorker: std.Thread,

    /// コンストラクタ
    pub fn new(allocator: std.mem.Allocator) !*Self {
        const ret = try allocator.create(Self);
        ret.* = .{
            .allocator = allocator,
            .incomingQueue = try ch.Channel(ipPacket).init(allocator, QUEUE_SIZE),
            .outgoingQueue = try ch.Channel(network.Packet).init(allocator, QUEUE_SIZE),
            .cancelEvent = try posix.epoll_create1(0),
            .readWorker = undefined,
            .writeWorker = undefined,
        };

        return ret;
    }

    /// デストラクタ
    pub fn delete(self: *Self) void {
        const n: u64 = 1;
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

    /// 各キューの管理を行う
    pub fn manageQueue(self: *Self, sock: *network.raw_sock) !void {
        const read_worker_thread = try std.Thread.spawn(.{}, read_worker_wrapped, .{ self, sock });
        const write_worker_thread = try std.Thread.spawn(.{}, write_worker_wrapped, .{ self, sock });

        self.readWorker = read_worker_thread;
        self.writeWorker = write_worker_thread;
    }

    pub fn read(self: *Self) !ipPacket {
        const packet = try self.incomingQueue.recv();
        return packet;
    }

    pub fn write(self: *Self, pkt: *network.Packet) !void {
        try self.outgoingQueue.send(pkt);
    }

    // private
    fn read_worker(self: *Self, sock: *network.raw_sock) void {
        const sel = select.Select.init(self.allocator) catch return;
        defer sel.deinit();

        const default_fd = select.createDefaultFd() catch return;
        defer posix.close(default_fd);

        sel.add(self.cancelEvent) catch return;
        sel.add(default_fd) catch return;

        while (true) {
            const ready = sel.wait() catch continue;

            if (ready == self.cancelEvent) {
                return;
            } else if (ready == default_fd) {
                const pkt = sock.read() catch continue;
                const ip_header = unmarshal(pkt.buf[0..pkt.buf.len]) catch continue;

                const ip_packet: ipPacket = .{
                    .header = ip_header,
                    .packet = pkt,
                };

                self.incomingQueue.send(ip_packet) catch continue;
            }
        }
    }

    fn write_worker(self: *Self, sock: *network.raw_sock) void {
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
                sock.write(packet) catch continue;
            }
        }
    }
};

const std = @import("std");
const net = @import("network.zig");
const internet = @import("internet.zig");

pub fn main() !void {
    //const stdout = std.io.getStdOut().writer();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var network = try net.raw_sock.new(allocator);
    defer network.delete();

    try network.bind();

    var ip = try internet.IPPacketQueue.new(allocator);
    defer ip.delete();

    try ip.manageQueue(network);

    while (true) {
        const pkt = try ip.read();
        pkt.header.print();
    }
}

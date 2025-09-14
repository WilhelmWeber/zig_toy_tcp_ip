const std = @import("std");
const net = @import("network.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var network = try net.raw_sock.new(allocator);
    defer network.delete();

    try network.bind();

    while (true) {
        const pkt = try network.read();
        try stdout.print("{s}\n", .{std.fmt.fmtSliceHexLower(pkt.buf[0..pkt.buf.len])});
        try network.write(pkt);
    }
}

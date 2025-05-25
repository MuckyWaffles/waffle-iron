const std = @import("std");

pub const Buffer = struct {
    text: std.ArrayList(std.ArrayList(u8)) = undefined,
    file: std.fs.File = undefined,

    name: []u8 = undefined,

    // This function is here because I really hate typing
    // buffer.text.items.len... Does Zig have a version of
    // C's inline keyword? I should look into that
    pub fn len(self: *Buffer) usize {
        return self.text.items.len - 1;
    }

    pub fn lineLen(self: *Buffer, line: usize) usize {
        return self.text.items[line].items.len - 1;
    }

    pub fn init(allocator: anytype, fileName: []u8) !Buffer {
        var buffer = Buffer{
            .name = fileName,
        };
        buffer.text = std.ArrayList(std.ArrayList(u8)).init(allocator);
        return buffer;
    }

    pub fn readFile(self: *Buffer, allocator: anytype) !void {
        var found = true;
        std.fs.cwd().access(self.name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("File not found\n", .{});
                found = false;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return err;
            },
        };
        if (!found) {
            const file = try std.fs.cwd().createFile(self.name, .{});
            file.close();
        }
        self.file = try std.fs.cwd().openFile(self.name, .{
            .mode = .read_write,
        });

        var fileReader = std.io.bufferedReader(self.file.reader());
        var readStream = fileReader.reader();

        while (true) {
            var buff: [256]u8 = [_]u8{0x00} ** 256;
            if (try readStream.readUntilDelimiterOrEof(&buff, '\n') == null) {
                return;
            }

            const trimmed = std.mem.trim(u8, &buff, "\x00");
            var line = std.ArrayList(u8).init(allocator);
            try line.appendSlice(trimmed);
            _ = try self.text.append(line);
        }
    }

    pub fn writeToFile(self: *Buffer) !void {
        try self.file.seekTo(0);
        var fileWriter = self.file.writer();

        for (self.text.items) |line| {
            const trimmed = std.mem.trim(u8, line.items, "\x00");
            try fileWriter.writeAll(trimmed);
        }

        try self.file.setEndPos(try self.file.getPos());
    }
};

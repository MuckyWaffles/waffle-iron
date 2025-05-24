const std = @import("std");
const posix = std.posix;
const term = @import("terminal.zig");

pub fn moveCursor(writer: anytype, row: usize, col: usize) void {
    _ = writer.print("\x1B[{};{}H", .{ row + 1, col + 1 }) catch |err| {
        std.debug.print("Error moving cursor: {}", .{err});
    };
}

pub fn handleSigWinch(_: c_int) callconv(.C) void {
    terminal.size = terminal.getSize() catch return;
    //try render(stdout, terminal, buffer);
}

pub fn render(stdout: anytype, textBuffer: TextBuffer) !void {
    _ = try posix.write(terminal.tty, "\x1B[2J");
    //_ = text;
    for (textBuffer.text.items, 0..) |line, i| {
        moveCursor(stdout, i, 0);
        _ = try posix.write(terminal.tty, line.items);
    }

    moveCursor(stdout, terminal.size.height, 0);
    _ = try posix.write(terminal.tty, textBuffer.name.*);

    moveCursor(stdout, terminal.size.height, textBuffer.name.*.len + 2);

    const modeString = switch (mode) {
        .normal => "Mode: Normal",
        .insert => "Mode: Insert",
    };
    _ = try posix.write(terminal.tty, modeString);
}

var terminal: term.Terminal = undefined;

const TextBuffer = struct {
    text: std.ArrayList(std.ArrayList(u8)) = undefined,
    file: std.fs.File = undefined,

    name: *const []u8 = undefined,

    // This function is here because I really hate typing
    // buffer.text.items.len... Does Zig have a version of
    // C's inline keyword? I should look into that
    fn len(self: *TextBuffer) usize {
        return self.text.items.len;
    }
};
var buffer = TextBuffer{};

fn writeToFile() !void {
    try buffer.file.seekTo(0);
    var fileWriter = buffer.file.writer();

    for (buffer.text.items) |line| {
        const trimmed = std.mem.trim(u8, line.items, "\x00");
        try fileWriter.writeAll(trimmed);
    }

    try buffer.file.setEndPos(try buffer.file.getPos());
}

fn readFile(allocator: anytype) !void {
    var fileReader = std.io.bufferedReader(buffer.file.reader());
    var readStream = fileReader.reader();

    while (true) {
        var buff: [256]u8 = [_]u8{0x00} ** 256;
        if (try readStream.readUntilDelimiterOrEof(&buff, '\n') == null) {
            return;
        }

        const trimmed = std.mem.trim(u8, &buff, "\x00");
        var line = std.ArrayList(u8).init(allocator);
        try line.appendSlice(trimmed);
        _ = try buffer.text.append(line);
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("Waffle Iron: requires an argument\n", .{});
        return;
    }

    const fileName = try allocator.alloc(u8, args[1].len);
    defer allocator.free(fileName);
    @memcpy(fileName, args[1]);

    moveCursor(stdout, 0, 0);
    var found = true;
    std.fs.cwd().access(fileName, .{}) catch |err| switch (err) {
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
        const file = try std.fs.cwd().createFile(fileName, .{});
        file.close();
    }
    buffer.file = try std.fs.cwd().openFile(fileName, .{
        .mode = .read_write,
    });

    buffer.name = &fileName;
    buffer.text = std.ArrayList(std.ArrayList(u8)).init(allocator);

    try readFile(allocator);

    try terminal.init(stdout);

    defer terminal.deinit(stdout);
    errdefer terminal.deinit(stdout);

    // TODO: Get this working because it's kind of important

    posix.sigaction(posix.SIG.WINCH, &posix.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // Main loop
    while (!closeRequested) try mainLoop(stdout, allocator);
}

const Mode = enum {
    normal,
    insert,
};

var mode: Mode = .normal;

var cursorX: u16 = 0;
var cursorY: u16 = 0;

var closeRequested: bool = false;

fn mainLoop(stdout: anytype, allocator: anytype) !void {
    try render(stdout, buffer);
    moveCursor(stdout, cursorY, cursorX);

    // TODO: support kitty keyboard protocol, perhaps
    var input: [1]u8 = undefined;
    _ = try posix.read(terminal.tty, &input);
    if (input[0] == '\x1B') {
        // Handling escape characters
        terminal.raw.cc[@intFromEnum(posix.system.V.TIME)] = 1;
        terminal.raw.cc[@intFromEnum(posix.system.V.MIN)] = 0;
        try posix.tcsetattr(terminal.tty, .NOW, terminal.raw);

        var esc_buffer: [8]u8 = undefined;
        const esc_read = try posix.read(terminal.tty, &esc_buffer);

        terminal.raw.cc[@intFromEnum(posix.system.V.TIME)] = 0;
        terminal.raw.cc[@intFromEnum(posix.system.V.MIN)] = 1;
        try posix.tcsetattr(terminal.tty, .NOW, terminal.raw);

        if (esc_read == 0) {
            // User just pressed the escape key
            mode = .normal;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[A")) {
            if (cursorY > 0) cursorY -= 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[B")) {
            if (cursorY < buffer.len() - 1) cursorY += 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[C")) {
            if (cursorX < buffer.text.items[cursorY].items.len - 1) cursorX += 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[D")) {
            if (cursorX > 0) cursorX -= 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[3~")) {
            deleteCharacter(cursorX, cursorY);
        } else {
            //try stdout.writeAll("input: unknown escape sequence\r\n");
        }
        return;
    }

    // hjkl to navigate
    if (mode == .normal) {
        switch (input[0]) {
            'i' => {
                mode = .insert;
            },
            'j' => {
                if (cursorY < buffer.len() - 1) cursorY += 1;
            },
            'k' => {
                if (cursorY > 0) cursorY -= 1;
            },
            'h' => {
                if (cursorX > 0) cursorX -= 1;
            },
            'l' => {
                if (cursorX < buffer.text.items[cursorY].items.len - 1) cursorX += 1;
            },
            'w' => {
                try writeToFile();
            },
            'q' => {
                closeRequested = true;
            },
            'd' => {
                deleteCharacter(cursorX, cursorY);
            },
            else => {},
        }
    } else if (mode == .insert) {
        // Check for backspace
        if (input[0] == 0x7f) {
            if (cursorX > 0) {
                // Normal delete
                deleteCharacter(cursorX - 1, cursorY);
                cursorX -= 1;
            } else {
                // Deleting line if user backspaces at index 0
                const line = buffer.text.orderedRemove(cursorY);

                // Moving cursor to end of previous line
                cursorY -= 1;
                cursorX = @intCast(buffer.text.items[cursorY].items.len - 1);

                // Deleting newline at the top
                deleteCharacter(cursorX, cursorY);

                // Adding old line to the end
                try buffer.text.items[cursorY].appendSlice(line.items);
            }
            return;
        } else if (input[0] == '\n' or input[0] == '\r') {
            // Clear trailing end of old line and add newline character
            var line = std.ArrayList(u8).init(allocator);
            try line.appendSlice(buffer.text.items[cursorY].items[cursorX..]);
            buffer.text.items[cursorY].shrinkRetainingCapacity(cursorX);
            try buffer.text.insert(cursorY + 1, line);

            insertCharacter(cursorX, cursorY, '\n');

            // Move cursor to the next line
            cursorX = 0;
            cursorY += 1;
            return;
        }
        // Insert user input
        insertCharacter(cursorX, cursorY, input[0]);
        cursorX += 1;
    }
    if (input[0] == '\n' or input[0] == '\r') {
        // hello?
    } else {
        // TODO: handle control key
    }
}

// ArrayLists make these functions laughably easy...
// I WANNA WRITE CODE THIS TOTALLY SUCKS!

// Insert a single character
fn insertCharacter(x: u16, y: u16, char: u8) void {
    const line = &buffer.text.items[y];
    line.insert(x, char) catch |err| {
        std.debug.print("Error: {}", .{err});
    };
}

// Delete a single character
fn deleteCharacter(x: u16, y: u16) void {
    const line = &buffer.text.items[y];
    _ = line.orderedRemove(x);
}

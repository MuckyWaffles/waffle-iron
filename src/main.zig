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
    for (textBuffer.text, 0..) |line, i| {
        moveCursor(stdout, i, 0);
        _ = try posix.write(terminal.tty, &line);
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
    //const text: []u8 = try std.fs.cwd().readFileAlloc(allocator, fileName, 1024);
    var file = try std.fs.cwd().openFile(fileName, .{});
    var file_reader = std.io.bufferedReader(file.reader());
    var read_stream = file_reader.reader();

    //while (try read_stream.readUntilDelimiterOrEofAlloc

    buffer.name = &fileName;

    //try read_stream.readUntilDelimiter(&text, '\n');
    while (try read_stream.readUntilDelimiterOrEof(&buffer.text[buffer.lineCount], '\n')) |line| {
        // Making sure the file doesn't read too much
        if (buffer.lineCount + 1 >= buffer.text.len) {
            break;
        }

        buffer.lineCount += 1;
        _ = line;
    }

    //var file = std.fs.cwd().openFile("foo.txt", .{});
    //defer std.fs.cwd().close();
    //std.mem.copyForwards(u8, text, "hello");

    try terminal.init(stdout);

    defer terminal.deinit(stdout);

    // TODO: Get this working because it's kind of important

    std.posix.sigaction(std.posix.SIG.WINCH, &std.posix.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // Main loop
    while (!closeRequested) try mainLoop(stdout);
}

const Mode = enum {
    normal,
    insert,
};

var mode: Mode = .normal;

const TextBuffer = struct {
    text: [4][80]u8 = undefined,
    lineCount: usize = 0,
    name: *const []u8 = undefined,
};
var buffer = TextBuffer{};

var cursorX: u16 = 0;
var cursorY: u16 = 0;

var closeRequested: bool = false;

fn mainLoop(stdout: anytype) !void {
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
            if (cursorY < buffer.lineCount) cursorY += 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[C")) {
            if (cursorX < 20) cursorX += 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[D")) {
            if (cursorX > 0) cursorX -= 1;
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
                if (cursorY < buffer.lineCount) cursorY += 1;
            },
            'k' => {
                if (cursorY > 0) cursorY -= 1;
            },
            'h' => {
                if (cursorX > 0) cursorX -= 1;
            },
            'l' => {
                if (cursorX < 20) cursorX += 1;
            },
            'q' => {
                closeRequested = true;
            },
            else => {},
        }
    }
    if (input[0] == '\n' or input[0] == '\r') {
        // hello?
    } else {
        // TODO: handle control key
    }
}

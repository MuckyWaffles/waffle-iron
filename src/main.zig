const std = @import("std");
const posix = std.posix;

pub fn moveCursor(writer: anytype, row: usize, col: usize) void {
    _ = writer.print("\x1B[{};{}H", .{ row + 1, col + 1 }) catch |err| {
        std.debug.print("Error moving cursor: {}", .{err});
    };
}

const Size = struct {
    width: usize,
    height: usize,
};

const Terminal = struct {
    /// Terminal window size
    size: Size,

    /// Original cooked terminal
    original: std.posix.termios,

    /// Active uncooked terminal
    raw: std.posix.termios,

    /// I'm not sure what this is tbh
    tty: std.posix.fd_t,

    /// Create terminal
    pub fn init(self: *Terminal, stdout: anytype) !void {
        self.size = .{ .width = 0, .height = 0 };
        self.tty = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        self.original = try std.posix.tcgetattr(self.tty);
        self.raw = try self.uncook(stdout);
    }

    pub fn deinit(self: *Terminal, stdout: anytype) void {
        self.cook(stdout) catch |err| {
            std.debug.print("{}\n", .{err});
        };
        posix.close(self.tty);
    }

    // Uncooking the terminal, and storing original state
    pub fn uncook(self: *Terminal, stdout: anytype) !posix.termios {
        var raw = self.original;

        // In the words of Leon Henrik Plickat, it's better we don't
        // think about what these do, lest we lose hope in UNIX entirely...
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        // I may forget what these do, so... here you go:
        // https://zig.news/lhp/want-to-create-a-tui-application-the-basics-of-uncooked-terminal-io-17gm
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;

        try std.posix.tcsetattr(self.tty, .FLUSH, raw);

        //try stdout.writeAll("\x1B[?25l"); // Hide cursor
        try stdout.writeAll("\x1B[s"); // Save cursor position
        try stdout.writeAll("\x1B[?47h"); // Save screen.struct
        try stdout.writeAll("\x1B[?1049h"); // Enable Alternative buffer

        return raw;
    }

    pub fn cook(self: *Terminal, stdout: anytype) !void {
        try posix.tcsetattr(self.tty, .FLUSH, self.original);
        try stdout.writeAll("\x1B[?1049l"); // Disable alternative buffer.
        try stdout.writeAll("\x1B[?47l"); // Restore screen.
        try stdout.writeAll("\x1B[u"); // Restore cursor position.
    }

    pub fn getSize(self: *Terminal) !Size {
        // TODO: documentation for std.mem.zeroes claims it's "stinky"? (look into it)
        var size = std.mem.zeroes(posix.winsize);
        const err = std.os.linux.ioctl(
            self.tty,
            posix.T.IOCGWINSZ,
            @intFromPtr(&size),
        );
        if (posix.errno(err) != .SUCCESS) {
            return posix.unexpectedErrno(@enumFromInt(err));
        }
        return Size{
            .width = size.col,
            .height = size.row,
        };
    }
};

pub fn handleSigWinch(_: c_int) callconv(.C) void {
    terminal.size = terminal.getSize() catch return;
    //render() catch return;
}

pub fn render(stdout: anytype, tty: std.posix.fd_t, text: *[4][80]u8) !void {
    _ = try posix.write(tty, "\x1B[2J");
    //_ = text;
    for (text, 0..) |line, i| {
        moveCursor(stdout, i, 0);
        _ = try posix.write(tty, &line);
    }
}

var terminal: Terminal = undefined;

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
    const fileName = args[1];

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

    var lineCount: usize = 0;
    var text: [4][80]u8 = undefined;
    //try read_stream.readUntilDelimiter(&text, '\n');
    while (try read_stream.readUntilDelimiterOrEof(&text[lineCount], '\n')) |line| {
        lineCount += 1;
        if (lineCount > text.len) {
            break;
        }
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
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    // Main loop
    while (!closeRequested) try mainLoop(stdout, &text);
}

var cursorX: u16 = 0;
var cursorY: u16 = 0;

var closeRequested: bool = false;

fn mainLoop(stdout: anytype, text: *[4][80]u8) !void {
    try render(stdout, terminal.tty, text);
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
            // Put something here?
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[A")) {
            if (cursorY > 0) cursorY -= 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[B")) {
            if (cursorY < 10) cursorY += 1;
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
    switch (input[0]) {
        'j' => {
            if (cursorY < 10) cursorY += 1;
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
    if (input[0] == '\n' or input[0] == '\r') {
        // hello?
    } else {
        // TODO: handle control key
    }
}

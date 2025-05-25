const std = @import("std");
const posix = std.posix;

const Size = struct {
    width: usize,
    height: usize,
};
const stdout = std.io.getStdOut().writer();

pub const Terminal = struct {
    /// Terminal window size
    size: Size,

    /// Original cooked terminal
    original: std.posix.termios,

    /// Active uncooked terminal
    raw: std.posix.termios,

    /// I'm not sure what this is tbh
    tty: std.posix.fd_t,

    /// Create terminal
    pub fn init(self: *Terminal) !void {
        self.size = try self.getSize();
        self.tty = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        self.original = try std.posix.tcgetattr(self.tty);
        self.raw = try self.uncook();
    }

    pub fn deinit(self: *Terminal) void {
        self.cook() catch |err| {
            std.debug.print("{}\n", .{err});
        };
        posix.close(self.tty);
    }

    // Uncooking the terminal, and storing original state
    pub fn uncook(self: *Terminal) !posix.termios {
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

    pub fn cook(self: *Terminal) !void {
        try posix.tcsetattr(self.tty, .FLUSH, self.original);
        try stdout.writeAll("\x1B[?1049l"); // Disable alternative buffer.
        try stdout.writeAll("\x1B[?47l"); // Restore screen.
        try stdout.writeAll("\x1B[u"); // Restore cursor position.
    }

    pub fn getSize(self: *Terminal) !Size {
        var size = posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
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

    /// Return KeyboardEvent struct that holds a special
    /// KeyAction or a normal char
    pub fn getKeyPresses(self: *Terminal) !KeyboardEvent {
        var keys = KeyboardEvent{};

        // TODO: Support kitty keyboard protocol
        var input: [1]u8 = undefined;
        _ = try posix.read(self.tty, &input);

        if (input[0] == '\x1B') {
            // Handling escape characters
            self.raw.cc[@intFromEnum(posix.system.V.TIME)] = 1;
            self.raw.cc[@intFromEnum(posix.system.V.MIN)] = 0;
            try posix.tcsetattr(self.tty, .NOW, self.raw);

            var escBuffer: [8]u8 = undefined;
            const escRead = try posix.read(self.tty, &escBuffer);

            self.raw.cc[@intFromEnum(posix.system.V.TIME)] = 0;
            self.raw.cc[@intFromEnum(posix.system.V.MIN)] = 1;
            try posix.tcsetattr(self.tty, .NOW, self.raw);

            const char = escBuffer[0..escRead];

            if (escRead == 0) {
                keys.keyAction = .escape;
            } else if (std.mem.eql(u8, char, "[A")) {
                keys.keyAction = .arrowUp;
            } else if (std.mem.eql(u8, char, "[B")) {
                keys.keyAction = .arrowDown;
            } else if (std.mem.eql(u8, char, "[C")) {
                keys.keyAction = .arrowRight;
            } else if (std.mem.eql(u8, char, "[D")) {
                keys.keyAction = .arrowLeft;
            } else if (std.mem.eql(u8, char, "[3~")) {
                keys.keyAction = .delete;
            }
            return keys;
        }
        keys.char = input[0];
        return keys;
    }
};

/// Special key codes
pub const KeyAction = enum {
    none,
    escape,
    delete,
    arrowLeft,
    arrowRight,
    arrowUp,
    arrowDown,
};

pub const KeyboardEvent = struct {
    keyAction: KeyAction = .none,
    char: u8 = 0,
};

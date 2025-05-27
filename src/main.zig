const std = @import("std");
const posix = std.posix;
const term = @import("terminal.zig");
const buf = @import("buffer.zig");

pub fn moveCursor(writer: anytype, row: usize, col: usize) void {
    _ = writer.print("\x1B[{};{}H", .{ row + 1, col + 1 }) catch |err| {
        std.debug.print("Error moving cursor: {}", .{err});
    };
}

pub fn handleSigWinch(_: c_int) callconv(.C) void {
    terminal.size = terminal.getSize() catch return;
    //try render(stdout, terminal, buffer);
}

pub fn render(stdout: anytype, textBuffer: buf.Buffer) !void {
    _ = try posix.write(terminal.tty, "\x1B[2J");
    //_ = text;
    for (textBuffer.text.items, 0..) |line, i| {
        moveCursor(stdout, i, 0);
        _ = try posix.write(terminal.tty, line.items);
    }

    moveCursor(stdout, terminal.size.height, 0);
    _ = try posix.write(terminal.tty, textBuffer.name);

    moveCursor(stdout, terminal.size.height, textBuffer.name.len + 2);

    const modeString = switch (mode) {
        .normal => "Mode: Normal",
        .insert => "Mode: Insert",
    };
    _ = try posix.write(terminal.tty, modeString);
}

var terminal: term.Terminal = undefined;

var buffer = buf.Buffer{};

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

    // Initialize our buffer, and open given file
    buffer = try buf.Buffer.init(allocator, args[1]);
    try buffer.readFile(allocator);

    // Initialize our terminal
    try terminal.init();
    defer terminal.deinit();

    // Handle window resizing
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

var closeRequested: bool = false;

fn mainLoop(stdout: anytype, allocator: anytype) !void {
    try render(stdout, buffer);
    moveCursor(stdout, cursorY, cursorX);

    const keys = try terminal.getKeyPresses();
    switch (keys.keyAction) {
        .escape => mode = .normal,
        .arrowUp => moveCursorY(-1),
        .arrowDown => moveCursorY(1),
        .arrowLeft => cursorLeft(),
        .arrowRight => cursorRight(),
        .delete => deleteCharacter(cursorX, cursorY),
        else => {},
    }

    // hjkl to navigate
    if (mode == .normal) {
        switch (keys.char) {
            'i' => mode = .insert,
            'j' => moveCursorY(1),
            'k' => moveCursorY(-1),
            'h' => cursorLeft(),
            'l' => cursorRight(),
            's' => try buffer.writeToFile(),
            'q' => closeRequested = true,
            'd' => deleteCharacter(cursorX, cursorY),
            'o' => {
                var line = std.ArrayList(u8).init(allocator);
                try line.append('\n');
                cursorY += 1;
                cursorX = 0;
                try buffer.text.insert(cursorY, line);
                mode = .insert;
            },
            'O' => {
                var line = std.ArrayList(u8).init(allocator);
                try line.append('\n');
                try buffer.text.insert(cursorY, line);
                cursorX = 0;
                mode = .insert;
            },
            'w' => moveCursorWord(),
            else => {},
        }
    } else if (mode == .insert) {
        // Check for backspace
        if (keys.char == 0x7f) {
            if (cursorX > 0) {
                // Normal delete
                cursorX -= 1;
                deleteCharacter(cursorX, cursorY);
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
        } else if (keys.char == '\n' or keys.char == '\r') {
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
        insertCharacter(cursorX, cursorY, keys.char);
        cursorX += 1;
    }
}

var cursorX: usize = 0;
var cursorY: usize = 0;
var trueX: usize = 0;

// For these cursorUp and cursorDown functions, I repeat a very
// small amount of code, and I'm not sure if it's worth reducing...
fn moveCursorY(move: i16) void {
    cursorY = @intCast(std.math.clamp(
        @as(i16, @intCast(cursorY)) + move,
        0,
        @as(i16, @intCast(buffer.len())),
    ));

    const lineLen: usize = buffer.lineLen(cursorY);
    if (cursorX > lineLen) {
        if (lineLen > trueX) trueX = cursorX;
        cursorX = lineLen;
    }
    cursorX = std.math.clamp(trueX, 0, lineLen);
}
fn cursorLeft() void {
    if (cursorX > 0) {
        cursorX -= 1;
    } else if (cursorY > 0) {
        cursorY -= 1;
        cursorX = @intCast(buffer.lineLen(cursorY));
    }
    trueX = cursorX;
}
fn cursorRight() void {
    if (cursorX < buffer.lineLen(cursorY)) {
        cursorX += 1;
    } else if (cursorY < buffer.len()) {
        cursorY += 1;
        cursorX = 0;
    }
    trueX = cursorX;
}

// ArrayLists make these functions laughably easy...
// I WANNA WRITE CODE THIS TOTALLY SUCKS!

/// Insert a single character
fn insertCharacter(x: usize, y: usize, char: u8) void {
    const line = &buffer.text.items[y];
    line.insert(x, char) catch |err| {
        std.debug.print("Error: {}", .{err});
    };
}

/// Delete a single character
fn deleteCharacter(x: usize, y: usize) void {
    const line = &buffer.text.items[y];
    _ = line.orderedRemove(x);
}

/// Move ahead one word
fn moveCursorWord() void {
    const line = buffer.text.items[cursorY];
    if (line.items[cursorX] == '\n') {
        if (cursorY < buffer.len()) {
            cursorY += 1;
            cursorX = 0;
        }
        return;
    }
    for (cursorX + 1..line.items.len) |i| {
        if (line.items[i] != ' ' and line.items[i] != '\n') continue;
        cursorX = i;
        break;
    }
}

// Make sure the code cleans up on panic.
// Working with an uncooked terminal is really annoying...
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    terminal.deinit(); // Call your custom deinit
    std.debug.print("Panic: {s}\n", .{msg});
    std.posix.exit(1);
    _ = error_return_trace;
}

const std = @import("std");

pub const Buffer = struct {
    text: std.ArrayList(std.ArrayList(u8)) = undefined,
    file: std.fs.File = undefined,

    name: *const []u8 = undefined,

    // This function is here because I really hate typing
    // buffer.text.items.len... Does Zig have a version of
    // C's inline keyword? I should look into that
    pub fn len(self: *Buffer) usize {
        return self.text.items.len;
    }
    pub fn lineLen(self: *Buffer, line: usize) usize {
        return self.text.items[line].items.len;
    }
};

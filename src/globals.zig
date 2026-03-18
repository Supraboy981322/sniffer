const std = @import("std");
const table = @import("table.zig");

pub const Config = struct {
    dataset_file:?[]const u8 = null,
    dataset:?[]table.Filetype = null,
    files:std.ArrayList([:0]const u8),
    print_lvl:?@import("helpers.zig").Print.Valid_LVLs,
};

const std = @import("std");
const table = @import("table.zig");

pub const Config = struct {
    //dataset file path
    dataset_file:?[]const u8 = null,
    //dataset table
    dataset:?[]table.Filetype = null,
    //arraylist of files to check
    files:std.ArrayList([:0]const u8),
    //the print level (.verbose, .quiet, or .normal)
    print_lvl:?@import("helpers.zig").Print.Valid_LVLs,
    //determines if helper to make an entry is run
    mk_entry:bool = false,
};

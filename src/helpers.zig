const std = @import("std");

//create stderr and stdout interfaces with no buffer (so I don't have to call 'flush()')
const stdout = &@constCast(&std.fs.File.stdout().writer(&.{})).interface;
const stderr = &@constCast(&std.fs.File.stderr().writer(&.{})).interface;

pub fn err_out(comptime msg:[]const u8, args:anytype) void {
    stderr.print(msg, args) catch {
        @panic(msg);
    };
    std.process.exit(1);
}

pub fn parse_dataset_zon(alloc:std.mem.Allocator, file:[]const u8) ![]@import("table.zig").Filetype {
    //open the dataset file
    var dataset_file = std.fs.openFileAbsolute(file, .{
        .lock = .exclusive,
    }) catch |e| return e;
    defer dataset_file.close();

    //read the entire dataset file into memory
    var dataset_reader = &@constCast(&dataset_file.reader(&.{})).interface;
    const dataset_string_R = try dataset_reader.allocRemaining(alloc, .unlimited);
    defer alloc.free(dataset_string_R);

    //add the zig-required C sentenial
    const dataset_string:[:0]const u8 = try alloc.dupeZ(u8, dataset_string_R);
    defer alloc.free(dataset_string);
    
    //parse the dataset into zon
    return std.zon.parse.fromSlice(
        []@import("table.zig").Filetype, alloc, dataset_string, null, .{}
    );
}

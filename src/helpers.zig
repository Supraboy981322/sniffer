const std = @import("std");
const table = @import("table.zig");
const globs = @import("globals.zig");

//create stderr and stdout interfaces with no buffer (so I don't have to call 'flush()')
const stdout = &@constCast(&std.fs.File.stdout().writer(&.{})).interface;
const stderr = &@constCast(&std.fs.File.stderr().writer(&.{})).interface;

//helper to print to stderr and exit
pub fn err_out(
    comptime msg:[]const u8,
    args:anytype
) void {
    stderr.print(msg, args) catch @panic(msg);
    std.process.exit(1);
}

//helper to parse dataset zon file into table 
pub fn parse_dataset_zon(
    alloc:std.mem.Allocator,
    file:[]const u8
) ![]table.Filetype {
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
        []table.Filetype, alloc, dataset_string, null, .{}
    );
}

pub const Args = struct {
    const Valid = enum {
        dataset,
        use_default_dataset,
        invalid,
    };
    pub fn parse(
        alloc:std.mem.Allocator
    ) !globs.Config {
        //initialize a config
        var config = globs.Config {
            //holds the filenames for each file to check (set by args)
            .files = try std.ArrayList([:0]const u8).initCapacity(alloc, 0),
        };
        
        var args = std.process.args();
        _ = args.skip(); //skip the path to the binary

        var parse_remaining: bool = true;
        loop: while (args.next()) |a| {
            if (a.len < 1) continue :loop;
            //gated if statement (i call it that, not sure what i'm supposed to refer to it as) 
            if (a[0] == '-' and a.len > 1 and parse_remaining) if (a[1] == '-') {
                //if the arg is just '--', treat remaining as filenames
                if (a.len == 2) parse_remaining = false else {
                    const arg = std.meta.stringToEnum(Valid, a[2..]) orelse .invalid;
                    switch (arg) {
                        .dataset => config.dataset_file = args.next(),
                        .use_default_dataset => config.dataset = &table.the_list,
                        else => err_out("unknown arg: {s}", .{a}),
                    }
                }
            } else { //compact arg (like -dv)
                // TODO: iterate over each byte in arg
            } else {
                try stdout.print("parsing as filename\n", .{});
                try config.files.append(alloc, a);
            }
        }

        //err if both default dataset and dataset file args used
        if (config.dataset) |_| if (config.dataset_file) |_| {
            err_out(
                \\provided conflicting args:
                \\  can't use both default dataset and custom dataset
                \\
            , .{});
        };
        return config;
    }
};

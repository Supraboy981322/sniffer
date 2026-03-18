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
    const m = if (msg[msg.len-1] != '\n') msg ++ "\n" else msg;
    Print.err("ERROR: " ++ m, args) catch @panic(m);
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

    //local enum type for valid args 
    const Valid = enum {
        dataset,
        use_default_dataset,
        verbose,
        quiet,
        invalid,
    };

    //helper to parse the args
    pub fn parse(
        alloc:std.mem.Allocator
    ) !globs.Config {
        //initialize a config
        var config = globs.Config {
            //holds the filenames for each file to check (set by args)
            .files = try std.ArrayList([:0]const u8).initCapacity(alloc, 0),
            .print_lvl = .normal
        };
        
        //get the cli args
        var args = std.process.args();
        _ = args.skip(); //skip the path to the binary

        //set to 'false' if '--' passed, so all remaining args are reated as filenames 
        var parse_remaining: bool = true;
        loop: while (args.next()) |a| {
            //skip empty args
            if (a.len < 1) continue :loop;

            //gated if statement (I call it that, not sure what I'm supposed to refer to it as)
            if (a[0] == '-' and a.len > 1 and parse_remaining) if (a[1] == '-') {

                //if the arg is just '--', treat remaining args as filenames
                if (a.len == 2) parse_remaining = false else {

                    //convert the arg to an enum (so it can be switched on)
                    const arg = std.meta.stringToEnum(Valid, a[2..]) orelse .invalid;

                    //switch on arg enum
                    switch (arg) {
                        //dataset file
                        .dataset => config.dataset_file = args.next(),

                        //default dataset 
                        .use_default_dataset => config.dataset = &table.the_list,

                        .quiet, .verbose => {
                            //convert the 'Args.Valid' enum type to a 'Print.Valid_LVLs' enum
                            const lvl = std.meta.stringToEnum(Print.Valid_LVLs, @tagName(arg));

                            //attempt to set the level (err if already changed)
                            if (config.print_lvl == .normal)
                                config.print_lvl = lvl
                            else
                                conflict("print level", false);
                        },

                        //all else invalid
                        else => err_out("unknown arg: {s}", .{a}),
                    }
                }
            } else { //compact args (like '-dv')
                //I can just switch on the individual bytes here since they're just 8-bit ints
                for (a[1..]) |c| switch (c) {
                    'd' => config.dataset_file = args.next(),
                    'D' => config.dataset = &table.the_list,
                    'q', 'v' => {
                        //convert the 'Args.Valid' enum type to a 'Print.Valid_LVLs' enum
                        const lvl:Print.Valid_LVLs = if (c == 'q') .quiet else .verbose; 

                        //attempt to set the level (err if already changed)
                        if (config.print_lvl == .normal)
                            config.print_lvl = lvl
                        else
                            conflict("print level", false);
                    },
                    else => err_out("unknown arg: {c} (in: {s})", .{c, a}),
                };
            } else {
                //otherwise parse as an input filename
                Print.debug("parsing as filename\n", .{});
                try config.files.append(alloc, a);
            }
        }

        //err if both default dataset and dataset file args used
        if (config.dataset) |_| if (config.dataset_file) |_| {
            conflict("default dataset and custom dataset", true);
        };

        return config;
    }

    //local helper to print arg conflict err 
    fn conflict(what:[]const u8, comptime known_conflict: bool) void {
        //print different error format if it's a known conflict 
        if (known_conflict)
            err_out(
                \\provided conflicting args
                \\  can't use both {s}
                \\
            , .{ what })
        else
            err_out(
                \\provided conflicting args
                \\  provided a '{s}' arg, but it was already set
                \\
            , .{ what });
    }
};

//helper to print to terminal conditionally (based on the level set by args)
pub const Print = struct {
    pub const Valid_LVLs = enum {
        verbose,
        normal,
        quiet,
    };
    pub var lvl:Valid_LVLs = .normal;

    //regular stdout
    pub fn out(
        comptime msg:[]const u8, 
        args:anytype
    ) !void {
        if (lvl != .quiet)
            try stdout.print(msg, args);
    }

    //regular stderr
    pub fn err(
        comptime msg:[]const u8,
        args:anytype
    ) !void {
        if (lvl != .quiet)
            try stderr.print(msg, args);
    }

    //debug (verbose) printer (no 'try' needed, errors ignored)
    pub fn debug(
        comptime msg:[]const u8,
        args:anytype
    ) void {
        if (lvl == .verbose)
            stderr.print("DEBUG: " ++ msg ++ "\n", args) catch {};
    }
};

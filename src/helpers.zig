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
    //add a newline to end of message if missing
    const m = if (msg[msg.len-1] != '\n') msg ++ "\n" else msg;
    //print the error 
    Print.err("ERROR: " ++ m, args) catch @panic(m);
    //and exit
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
        mk_entry,
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

                        //arg to run a helper to generate a valid ZON entry for the dataset
                        .mk_entry => {
                            if (!config.mk_entry)
                                config.mk_entry = true
                            else
                                conflict("mk_entry", false);
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
                    'M' => {
                        if (!config.mk_entry)
                            config.mk_entry = true
                        else
                            conflict("mk_entry", false);
                    },
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

//helper to get a dataset entry struct
pub fn mk_dataset_entry(
    header:[]const u8,
    desc:[]const u8,
    filetype:[]const u8,
    trailer:?[]const u8,
    ext:?[]const u8,
    offset:usize,
) table.Filetype {
    return table.Filetype {
        .header = header,
        .desc = desc,
        .trailer = trailer,
        .ext = ext,
        .type = filetype,
        .offset = offset,
    };
}

//helper get a formatted dataset entry string
pub fn dataset_entry_to_fmt_str(
    alloc:std.mem.Allocator,
    entry:table.Filetype
) ![]const u8 {
    //generate the trailer string
    const trailer = if (entry.trailer) |trailer| b: {
        //init an arraylist as a dynamic buffer 
        var arr = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer _ = arr.deinit(alloc);

        //for each byte in the trailer string
        for (trailer) |b| {
            //add '\x'
            try arr.print(alloc, "\\x", .{});
            //if the byte is less than '\x0F', add a zero 
            if (b <= '\x0F')
                try arr.print(alloc, "0", .{});
            //add hex digit for byte
            try arr.print(alloc, "{X}", .{b});
        }

        //get a slice of the items
        const slice = try arr.toOwnedSlice(alloc);

        //if the slice isn't in quotes (shouldn't be, but just in-case)
        if (slice[0] != '"'){
            //make sure the owned slice is freed and break with a new slice in quotes 
            defer alloc.free(slice);
            break :b try std.fmt.allocPrint(alloc, "\"{s}\"", .{slice});
        } else {
            //otherwise just use the slice
            break :b slice;
        }
    } else b: {
        //this is a dupe of a hard-coded string so the free-ing logic is simple
        break :b try alloc.dupe(u8, "null");
    };
    defer alloc.free(trailer);

    //generate the header string
    const header = b: {
        //init an arraylist
        var arr = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer _ = arr.deinit(alloc);

        //for each byte in the header string
        for (entry.header) |b| {
            //add '\x'
            try arr.print(alloc, "\\x", .{});
            //if the byte is less than a '\x0F' byte, add a zero 
            if (b <= '\x0F')
                try arr.print(alloc, "0", .{});

            //add the hex digit for byte 
            try arr.print(alloc, "{X}", .{b});
        }

        //create an newly allocated string with the arraylist items
        const slice = try arr.toOwnedSlice(alloc);

        //make sure it's in quotes
        if (slice[0] != '"') {
            defer alloc.free(slice);
            break :b try std.fmt.allocPrint(alloc, "\"{s}\"", .{slice});
        } else  {
            break :b slice;
        }
    };
    defer alloc.free(header);

    //put the extension in quotes if present or null
    const ext = if (entry.ext) |ext|
        try std.fmt.allocPrint(alloc, "\"{s}\"", .{ext})
    else
        try std.fmt.allocPrint(alloc, "null", .{});
    defer alloc.free(ext);

    //finally, return a ZON formatted string
    return try std.fmt.allocPrint(
        alloc,
        \\.{{
        \\    .header = {s},
        \\    .desc = "{s}",
        \\    .type = "{s}",
        \\    .trailer = {s},
        \\    .ext = {s},
        \\    .offset = {d},
        \\}},
        \\
    , .{
        header,
        entry.desc,
        entry.type,
        trailer,
        ext,
        entry.offset,
    });
}

//helper to get a line from stdin with some extra logic
pub fn stdin_ln(
    stdin:*std.io.Reader,
    alloc:std.mem.Allocator,
    prompt:[]const u8,
    comptime empty_allowed:bool,
) []u8 {
    //keep trying until input is valid
    while (true) {
        //print the prompt
        stdout.print("{s}  ", .{prompt}) catch {};

        //get the raw input 
        const raw = stdin.takeDelimiter('\n') catch {
            @panic("failed to read stdin");
        } orelse {
            @panic("failed to read stdin");
        };

        //trim whitespace 
        const trimmed = std.mem.trim(u8, raw, "\r ");

        //if non-empty or allowed ot be empty, return a newly allocated string
        //  if not newly allocated, data seems to change on it's own
        //    (probably who owns the memory, or I'm just unaware of something
        //      Zig does with the data)
        if (trimmed.len > 0 or empty_allowed) return alloc.dupe(u8, trimmed) catch |e| {
            @panic(@errorName(e));
        };

        //since it hasn't returned yet, the input was invalid
        stderr.print("invalid input, cannot be empty\n", .{}) catch {};
    }
}

//helper to convert a hex string to raw bytes (parse it) with some extra logic
pub fn hex_to_bytes(
    alloc:std.mem.Allocator,
    in:[]const u8,
) ![]u8 {
    //get the number of space
    const num_spaces = std.mem.count(u8, in, " ");

    //allocate a buffer for the size of input minus spaces 
    const buf:[]u8 = try alloc.alloc(u8, in.len - num_spaces);
    defer alloc.free(buf);
    
    //remove any spaces from input
    _ = std.mem.replace(u8, in, " ", "", buf);

    //allocate another buffer for the result
    const buf2:[]u8 = try alloc.alloc(u8, buf.len);
    //it is up to the fn caller to free the slice
    return try std.fmt.hexToBytes(buf2, buf);
}

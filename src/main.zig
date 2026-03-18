const std = @import("std");
const table = @import("table.zig");
const hlp = @import("helpers.zig");
const Sniffer = @import("sniffer.zig").Sniffer;

//alias for the default dataset
const the_list = table.the_list;

//create stderr and stdout interfaces with no buffer (so I don't have to call 'flush()')
const stdout = &@constCast(&std.fs.File.stdout().writer(&.{})).interface;
const stderr = &@constCast(&std.fs.File.stderr().writer(&.{})).interface;
const print = hlp.Print;

pub fn main() !void {
    //the main allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();

    var config = try hlp.Args.parse(alloc);
    defer {
        config.files.deinit(alloc);
    }

    //set the print level
    print.lvl = if (config.print_lvl) |lvl| lvl else .normal;

    if (config.mk_entry) return mk_entry(alloc);

    
    if (config.dataset_file) |filename| {
        defer print.debug("using dataset file: {s}", .{filename});
        //get the full path to the dataset file
        print.debug("getting the full path to dataset file: {s}", .{filename});
        const path = std.fs.cwd().realpathAlloc(alloc, filename) catch |e| {
            hlp.err_out("failed to get full path to dataset file ({s}): {t}\n", .{filename, e});
            unreachable;
        };
        defer alloc.free(path);

        //parse .zon dataset file into '[]table.Filetype'
        print.debug("parsing dataset ZON into table: {s}", .{filename});
        config.dataset = hlp.parse_dataset_zon(alloc, path) catch |e| {
            // TODO: handle other errors
            switch (e) {
                else => hlp.err_out("failed to parse dataset file ({s}): {t}\n", .{filename, e}),
            }
            unreachable;
        };
    } else {
        //get the home directory
        print.debug("getting the $HOME directory", .{});
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            hlp.err_out("either unsupported (non-UNIX) system or $HOME not set\n", .{});
            unreachable;
        };
        defer alloc.free(home);
        print.debug("$HOME found: {s}", .{home});

        //construct the path to the config file 
        const path:[]const []const u8 = &[_][]const u8 { home, ".config", "sniffer.zon" };
        const dataset_path = try std.fs.path.join(alloc, path);
        defer alloc.free(dataset_path);

        //parse '.zon' dataset file into table 
        print.debug("parsing dataset ZON into table: {s}", .{dataset_path}); 
        config.dataset = hlp.parse_dataset_zon(alloc, dataset_path) catch |e| {
            // TODO: handle other errors
            switch (e) {
                else => {
                    hlp.err_out("failed to parse dataset file ({s}): {t}\n", .{dataset_path, e});
                },
            }
            unreachable;
        };
    }
    defer std.zon.parse.free(alloc, config.dataset.?);

    //create an arena allocator from the gpa so it can easily be reset
    //  after each file
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    //if the filename isn't null (meaning set by arg) 
    if (config.files.items.len > 0) loop: for (config.files.items) |name| {
        //make sure the arena resets after this loop iteration finishes
        defer _ = arena.reset(.free_all);

        //get an allocator out of it
        var allocator = arena.allocator();

        print.debug("about to do: {s}", .{name});

        //stat the file before reading it
        const stat = std.fs.cwd().statFile(name) catch |e| {
            hlp.err_out("couldn't stat file ({s}): {t}\n", .{name, e});
            unreachable;
        };

        //err if not a file
        if (stat.kind != .file) {
            hlp.err_out("{s} does not appear to be a file\n", .{name});
        }

        //attempt to open the file
        print.debug("opening file: {s}", .{name});
        var file = std.fs.cwd().openFile(name, .{
            .lock = .exclusive,
        }) catch |e| {
            hlp.err_out("couldn't open file ({s}): {t}\n", .{name, e});
            unreachable;
        };

        //a reader for the file
        var reader = &@constCast(&file.reader(&.{})).interface;

        //just read the whole thing into memory
        print.debug("reading the ENTIRE file into memory ({d} bytes)", .{stat.size});
        const input = try reader.allocRemaining(allocator, .unlimited);
        defer allocator.free(input);

        //initialize a sniffer
        //  the '.?' assumes non-null
        print.debug("initializing a sniffer", .{});
        var sniffer = Sniffer.init(input, name, config.dataset.?); 
        
        //try to find a match using everything in the dataset 
        print.debug("checking for a match", .{});
        const match = sniffer.chk_all() catch {
            try stdout.print(
                \\filename: {s}
                \\  couldn't match data
                \\
            , .{ 
                name,
            });
            continue :loop;
        };

        //print the result (multi-line string)
        try stdout.print(
            \\filename: {s}
            \\  match found.
            \\  type: {s}
            \\  file extension: {s}
            \\  description: {s}
            \\
        , .{
            name,
            match.type,
            //if no extension, print "[none]" instead of panicing
            match.ext orelse "[none]",
            match.desc,
        });
    } else print.debug("end of files to check", .{}) else {
        //no filename provided (no args), print to stderr and exit
        hlp.err_out("no filename provided\n", .{});
    }
}

// TODO: make this append it to the dataset config file (if found)
fn mk_entry(allocator:std.mem.Allocator) !void {
    try stdout.print(
        \\creating an entry... I will need:
        \\  the header ("magic" bytes at the beginning)
        \\  a brief description of the filetype
        \\  the category (type) that the filetype falls into
        \\      (eg: 'Pictures' or 'Compressed archive')
        \\  the trailer ("magic" bytes at the ending)
        \\  the file extension (if applicable)
        \\  the offset of the header
        \\
    , .{});
    
    var buffer:[1024]u8 = undefined;
    const stdin = &@constCast(&std.fs.File.stdin().reader(&buffer)).interface;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    while (true) {
        defer _ = arena.reset(.free_all);
        var ok:bool = false;
        while (!ok) {
            const ready = hlp.stdin_ln(
		stdin,
                alloc,
                "ready? (Y/n)",
                false,
            );
            defer alloc.free(ready);

            if (ready[0] == 'y') {
                ok = true;
            } else if (ready[0] == 'n') {
                return;
            } else {
                try stderr.print("invalid response, need 'y' (yes) or 'n' (no)", .{});
            }
        }

        const header = inner_loop: while (true) {
            const raw = hlp.stdin_ln(
                stdin,
                alloc,
                "header:",
                false,
            );
            defer alloc.free(raw);

            break :inner_loop hlp.hex_to_bytes(
                alloc, raw
            ) catch |e| {
                try stderr.print("\tinvalid: {s}\n", .{raw});
                try stderr.print("\t({t})\n", .{e});
                continue :inner_loop;
            };
        };
        defer alloc.free(header);

        const desc = hlp.stdin_ln(
            stdin,
            alloc,
            "description:",
            false,
        );
        defer alloc.free(desc);

        const category = hlp.stdin_ln(
            stdin,
            alloc,
            "category (type):",
            false,
        );
        defer alloc.free(category);

        const trailer = inner_loop: while (true) {
            const raw = hlp.stdin_ln(
		stdin,
                alloc,
                "trailer (empty for none):",
                true,
            );
            defer alloc.free(raw);
            if (raw.len < 1) break :inner_loop null;
            break :inner_loop hlp.hex_to_bytes(
                alloc, raw
            ) catch |e| {
                try stderr.print("\tinvalid: {s}\n", .{raw});
                try stderr.print("\t({t})\n", .{e});
                continue :inner_loop;
            };
        };
        defer if (trailer) |t| alloc.free(t);

        const ext = b: {
            const raw = hlp.stdin_ln(
		stdin,
                alloc,
                "file_extension (empty for none):",
                true,
            );
            break :b if (raw.len > 0) raw else null;
        };
        defer if (ext) |e| alloc.free(e);

        const offset:usize = inner_loop: while (true) {
            const raw = hlp.stdin_ln(
                stdin, 
                alloc,
                "offset (empty for none):",
                true,
            );
            defer alloc.free(raw);
            if (raw.len < 1) break :inner_loop 0; 
            
            break :inner_loop std.fmt.parseInt(
                usize,
                raw,
                10,
            ) catch |e| {
                try stderr.print("NaN {t}\n", .{e});
                continue :inner_loop;
            };
        };

        const entry = hlp.mk_dataset_entry(
            header,
            desc,
            category,
            trailer,
            ext,
            offset,
        );

        const fmt_entry = try hlp.dataset_entry_to_fmt_str(alloc, entry);
        defer alloc.free(fmt_entry);

        try stdout.print(
            \\result:
            \\{s}
        , .{ fmt_entry });
    }
}

const std = @import("std");
const table = @import("table.zig");
const hlp = @import("helpers.zig");
const Sniffer = @import("sniffer.zig").Sniffer;

//alias for the default dataset
const the_list = table.the_list;

//create stderr and stdout interfaces with no buffer (so I don't have to call 'flush()')
const stdout = &@constCast(&std.fs.File.stdout().writer(&.{})).interface;
const stderr = &@constCast(&std.fs.File.stderr().writer(&.{})).interface;

const Config = struct {
    dataset_file:?[]const u8 = null,
    dataset:[]table.Filetype = undefined,
    files:std.ArrayList([:0]const u8),
};

const valid_args = enum {
    dataset,
    invalid,
};

pub fn main() !void {
    //the main allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();
    
    var args = std.process.args();
    _ = args.skip(); //skip the path to the binary

    var config = Config {
        //holds the filenames for each file to check (set by args)
        .files = try std.ArrayList([:0]const u8).initCapacity(alloc, 0),
    };

    // TODO: change this to properly evaluate args
    //  (instead of just treating the last arg as the filename)
    var parse_args: bool = true;
    loop: while (args.next()) |a| {
        if (a.len < 1) continue :loop;
        //gated if statement (I call it that, not sure what I'm supposed to refer to it as) 
        if (a[0] == '-' and a.len > 1 and parse_args) if (a[1] == '-') {
            //if the arg is just '--', treat remaining as filenames
            if (a.len == 2) parse_args = false else {
                const arg = std.meta.stringToEnum(valid_args, a[2..]) orelse .invalid;
                switch (arg) {
                    .dataset => config.dataset_file = args.next(),
                    else => hlp.err_out("unknown arg: {s}", .{a}),
                }
            }
        } else { //compact arg (like -dv)
            // TODO: iterate over each byte in arg
        } else {
            try stdout.print("parsing as filename\n", .{});
            try config.files.append(alloc, a);
        }
    }
    
    var dataset_zon:[]table.Filetype = undefined;
    if (config.dataset_file) |filename| {
        const path = std.fs.cwd().realpathAlloc(alloc, filename) catch |e| {
            hlp.err_out("failed to get full path to dataset file ({s}): {t}\n", .{filename, e});
            unreachable;
        };
        dataset_zon = hlp.parse_dataset_zon(alloc, path) catch |e| {
            hlp.err_out("couldn't read dataset file ({s}): {t}\n", .{filename, e});
            unreachable;
        };
    } else {
        //get the home directory
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            hlp.err_out("either unsupported (non-UNIX) system or $HOME not set", .{});
            unreachable;
        };
        defer alloc.free(home);

        //construct the path to the config file 
        const path:[]const []const u8 = &[_][]const u8 { home, ".config", "sniffer.zon" };
        const dataset_path = try std.fs.path.join(alloc, path);
        defer alloc.free(dataset_path);

        dataset_zon = hlp.parse_dataset_zon(alloc, dataset_path) catch |e| {
            switch (e) {
                else => {
                    hlp.err_out("failed to parse dataset file ({s}): {t}\n", .{dataset_path, e});
                    unreachable;
                },
            }
        };
    }
    defer if (config.dataset_file != null)
        std.zon.parse.free(alloc, config.dataset);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    //if the filename isn't null (meaning set by arg) 
    if (config.files.items.len > 0) loop: for (config.files.items) |name| {
        defer _ = arena.reset(.free_all);
        var allocator = arena.allocator();

        //stat the file before reading it
        const stat = std.fs.cwd().statFile(name) catch |e| {
            hlp.err_out("couldn't stat file: {t}\n", .{e});
            unreachable;
        };

        //err if not a file
        if (stat.kind != .file) {
            hlp.err_out("{s} does not appear to be a file\n", .{name});
        }

        //attempt to open the file
        //   TODO: handle errors here in a 'catch' block
        var file = std.fs.cwd().openFile(name, .{
            .lock = .exclusive,
        }) catch |e| {
            hlp.err_out("couldn't open file: {t}\n", .{e});
            unreachable;
        };

        //a reader for the file
        var reader = &@constCast(&file.reader(&.{})).interface;

        //just read the whole thing into memory
        const input = try reader.allocRemaining(allocator, .unlimited);
        defer allocator.free(input);

        //initialize a sniffer
        //  the '.?' assumes non-null
        var sniffer = Sniffer.init(input, name, dataset_zon); 
        
        //try to find a match using everything in the dataset 
        const match = sniffer.chk_all() catch {
            try stdout.print(
                \\filename: {s}
                \\  couldn't match data
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
    } else {} else {
        //no filename provided (no args), print to stderr and exit
        hlp.err_out("no filename provided\n", .{});
    }
}

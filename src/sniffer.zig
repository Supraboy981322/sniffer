const std = @import("std");
const table = @import("table.zig");

//  pub const Filetype = struct {
//    header:[]const u8,
//    desc:[]const u8,
//    type:[]const u8,
//    ext:?[]const u8,
//    trailer:?[]const u8,
//    offset:usize,
//  };

pub const Sniffer = struct {

    input:[]u8,                        //the input byte string
    idx:usize = 0,                     //current index in table
    best_match:?table.Filetype = null, //the current best match (maybe null)
    file_ext:?[]const u8,              //the file extension (maybe null)
    table:[]table.Filetype,

    //so functions can reference to the struct
    const Self = @This();

    //errors that may be returned by functions in this struct
    pub const Error = error{
        NoMatch,
    };

    //initializer (creates a new sniffer instance)
    pub fn init(input:[]u8, filename:?[]const u8, dataset:?[]table.Filetype) Sniffer {
        //get the file extension (maybe null)
        const ext = if (filename) |name| b: {
            const idx = std.mem.lastIndexOf(u8, name, ".");
            break :b if (idx) |i| name[i + 1..] else null;
        } else null;

        //print it  TODO: remove this
        std.debug.print("{s}\n", .{ext orelse "[no ext found]"});

        //return a new sniffer
        return Sniffer {
            .input = input,
            .file_ext = ext,
            //use the dateset provided as a fn param,
            //  defaults to the built-in table if null
            .table = dataset orelse &table.the_list,
        };
    }

    //checks entire table for a match
    pub fn chk_all(self:*Sniffer) !table.Filetype {
        //local allocator
        var gpa = std.heap.GeneralPurposeAllocator(.{}).init; 
        var alloc = gpa.allocator();

        //anything in this defer block runs just before fn returns
        defer {
            //print what's about to return  TODO: remove this
            std.debug.print("returning: {s}\n", .{
                if (self.best_match) |best|
                    best.ext orelse "[no ext]"
                else
                    "[no best match used]"
            });
            //deinit the allocator (frees memory and such)
            _ = gpa.deinit();
        }

        //loop indefintely (not really, it returns at the end of the table) 
        while (true) {
            //attempt to get the next item in the table
            const current = self.get_next() catch |e| {
                //if there's an error (end of table) either
                //  return best match or end of table error
                return if (self.best_match) |best| best else e;
            };
            
            //if not-null (a match), first check if the file extensions match
            if (current) |cur| if (self.file_ext) |ext_R| {
                //make them both lowercase
                var ext = try std.ascii.allocLowerString(alloc, ext_R);
                var ext_match = try std.ascii.allocLowerString(alloc, ext_R);

                //make sure the allocated memory is freed
                defer for (&[_]*[]u8{
                    &ext, &ext_match
                }) |*thing| alloc.free(thing.*.*);

                //if the file-extensions match, go ahead and return it 
                if (std.mem.eql(u8, ext, ext_match)) {
                    std.debug.print("extenstion matched ({s})\n", .{ext_match});
                    return cur;
                } else {
                    //otherwise make note of it (so *something* can be returned later)
                    self.best_match = cur;
                    std.debug.print("current best match: {s}\n", .{cur.ext orelse "[no ext]"});
                }
            } else {
                //if no file extension provided, then just return the first match
                std.debug.print("best match: {s}\n", .{cur.ext orelse "[no ext]"});
                return cur;
            };
        }
    }

    //local helper to get the next item in the table
    fn get_next(self:*Sniffer) !?table.Filetype {
        //increment the index on return
        defer self.idx += 1;
        return //if at end of table, return error
            if (self.table.len <= self.idx)
                Error.NoMatch
            //otherwise, if it's a match, return the item
            else if (self.is_match(self.table[self.idx]))
                self.table[self.idx] 
            //otherwise return null
            else
                null;
    }

    //public helper to check if something is a match 
    pub fn is_match(self:*Sniffer, check:table.Filetype) bool {
        //get the end "magic" (empty string if null
        const end_bytes = if (check.trailer) |end| end else "";
        //calculate the minimum size (to fit header + trailer + offset) 
        const min_size = check.header.len + end_bytes.len + check.offset;

        //not a match if too short 
        if (self.input.len < min_size)
            return false;

        //header
        for (check.header, 0..) |b, i|
            if (self.input[check.offset+i] != b)
                return false;

        //trailer
        for (end_bytes, 0..) |b, i|
            if (self.input[self.input.len - (i + end_bytes.len)] != b)
                return false;

        //if all other conditions are fine, it's a match
        return true;
    }
};

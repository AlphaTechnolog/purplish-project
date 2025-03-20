// Run with zig run .\.scripts\fmt.zig -- .\<module-folder> from within the monorepo folder.

const std = @import("std");

const heap = std.heap;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;
const debug = std.debug;
const fs = std.fs;

const ArrayList = std.ArrayList;
const Child = process.Child;

pub fn main() !void {
    var dba = heap.DebugAllocator(.{}){};
    defer if (dba.deinit() == .leak) debug.print("memleak detected\n", .{});

    const allocator = dba.allocator();

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    const module_folder = args.next() orelse return error.NoModule;

    const folders = list: {
        var result = ArrayList([]u8).init(allocator);
        var dir = try fs.cwd().openDir(module_folder, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        // we should also format the main package files.
        try result.append(try allocator.dupe(u8, "."));

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    var opened_entry = try dir.openDir(entry.path, .{ .iterate = true });
                    defer opened_entry.close();

                    var it = opened_entry.iterate();
                    const has_gofile = has: {
                        while (try it.next()) |element| {
                            if (element.kind == .file) {
                                const dotidx = idx: {
                                    for (0.., element.name) |i, c| {
                                        if (c == '.') break :idx i;
                                    }
                                    break :idx null;
                                };

                                if (dotidx) |idx| {
                                    const ext = element.name[idx + 1 .. element.name.len];
                                    if (mem.eql(u8, ext, "go")) break :has true;
                                }

                                continue;
                            }
                        }
                        break :has false;
                    };

                    if (!has_gofile) continue;

                    try result.append(try fs.path.join(allocator, &[_][]const u8{
                        ".",
                        entry.path
                    }));
                },
                else => continue,
            }
        }

        break :list try result.toOwnedSlice();
    };

    defer {
        for (folders) |entry| allocator.free(entry);
        allocator.free(folders);
    }

    for (folders) |folder| {
        var child = Child.init(&[_][]const u8{"go", "fmt", folder}, allocator);
        child.cwd = module_folder;

        debug.print("FMT: {s} at {s}\n", .{folder, module_folder});

        try child.spawn();
        const term = try child.wait();

        if (term.Exited == 1) {
            debug.print("Failed to call 'go fmt {s}' at {s}\n", .{
                folder,
                module_folder,
            });
        }
    }
}
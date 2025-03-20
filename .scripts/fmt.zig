// Run with zig run .\.scripts\fmt.zig -- .\<module-folder> from within the monorepo folder.

const std = @import("std");

const heap = std.heap;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;
const debug = std.debug;
const fs = std.fs;
const posix = std.posix;
const io = std.io;

const ArrayList = std.ArrayList;
const Child = process.Child;

const GLOB_STAR = "*";
const VERBOSE = true;

fn deallocateStringSlice(allocator: mem.Allocator, slice: *const [][]u8) void {
    for (slice.*) |element| allocator.free(element);
    allocator.free(slice.*);
}

fn getProjectModules(allocator: mem.Allocator) ![][]u8 {
    var elements = ArrayList([]u8).init(allocator);
    var dir = try fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        var opened_subdir = try dir.openDir(entry.name, .{ .iterate = true });
        defer opened_subdir.close();

        var subdir_it = opened_subdir.iterate();
        while (try subdir_it.next()) |subentry| {
            if (mem.eql(u8, subentry.name, "go.mod")) try elements.append(try allocator.dupe(
                u8,
                entry.name,
            ));
        }
    }

    return try elements.toOwnedSlice();
}

fn fmtProject(allocator: mem.Allocator, module_folder: []const u8) !void {
    const folders = list: {
        var result = ArrayList([]u8).init(allocator);
        var dir = try fs.cwd().openDir(module_folder, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

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
                            }
                        }
                        break :has false;
                    };

                    if (!has_gofile) continue;

                    try result.append(try fs.path.join(allocator, &[_][]const u8{
                        ".",
                        entry.path,
                    }));
                },
                else => continue,
            }
        }

        break :list try result.toOwnedSlice();
    };

    defer deallocateStringSlice(allocator, &folders);

    for (folders) |folder| {
        var child = Child.init(&[_][]const u8{ "go", "fmt", folder }, allocator);
        child.cwd = module_folder;

        if (VERBOSE == true) {
            debug.print("FMT: {s} at {s}\n", .{
                folder,
                module_folder,
            });
        }

        try child.spawn();
        const term = try child.wait();

        if (term.Exited == 1 and VERBOSE == true) {
            debug.print("Failed to call 'go fmt {s}' at '{s}'\n", .{
                folder,
                module_folder,
            });
        }
    }
}

pub fn main() !void {
    var dba = heap.DebugAllocator(.{}){};
    defer if (dba.deinit() == .leak) debug.print("memleak detected\n", .{});

    const allocator = dba.allocator();

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    const argument = args.next() orelse return error.NoModule;

    if (mem.eql(u8, argument, GLOB_STAR)) {
        const modules = getProjectModules(allocator) catch |err| {
            const stderr = io.getStdErr().writer();
            stderr.print("FATAL: Unable to scan for project modules: {s}\n", .{
                @errorName(err),
            }) catch unreachable;
            posix.exit(1);
        };

        defer deallocateStringSlice(allocator, &modules);

        for (modules) |module| {
            if (VERBOSE == true) debug.print("** Entering project `{s}`\n", .{module});
            try fmtProject(allocator, module);
        }

        return;
    }

    try fmtProject(allocator, argument);
}
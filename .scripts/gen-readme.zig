// Why in zig? idk this is for fun anyways...
// run with zig run <filename>.zig -- <docdir>

const std = @import("std");

const heap = std.heap;
const process = std.process;
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const posix = std.posix;
const mem = std.mem;

const ArrayList = std.ArrayList;

const BUFFER_SIZE = 4012;

const Config = struct {
    pub const Attribute = struct {
        pub const Value = union(enum) {
            string: []u8,
            int: i64,
            float: f64,
            boolean: bool,
        };

        allocator: std.mem.Allocator,
        key: []const u8,
        value: Value,

        fn valueFromStr(allocator: std.mem.Allocator, str: []const u8) !Value {
            var lowercase_buf: [1024]u8 = undefined;
            const lowercased = std.ascii.lowerString(&lowercase_buf, str);

            if (lowercased[0] == '"' and lowercased[lowercased.len - 1] == '"') {
                return Value{ .string = try allocator.dupe(u8, str[1 .. lowercased.len - 1]) };
            }

            if (std.mem.eql(u8, lowercased, "yes") or std.mem.eql(u8, lowercased, "true") or std.mem.eql(u8, lowercased, "on")) {
                return Value{ .boolean = true };
            } else if (std.mem.eql(u8, lowercased, "no") or std.mem.eql(u8, lowercased, "false") or std.mem.eql(u8, lowercased, "off")) {
                return Value{ .boolean = false };
            }

            if (std.mem.containsAtLeast(u8, lowercased, 1, ".")) {
                return Value{ .float = try std.fmt.parseFloat(f64, lowercased) };
            } else {
                return Value{ .int = try std.fmt.parseInt(i64, lowercased, 10) };
            }
        }

        pub fn init(allocator: std.mem.Allocator, key: []const u8, value_str: []const u8) !Attribute {
            return Attribute{
                .allocator = allocator,
                .key = try allocator.dupe(u8, key),
                .value = try valueFromStr(allocator, value_str),
            };
        }

        pub inline fn debugShow(self: Attribute) void {
            std.debug.print("{s}: {s} = {s}\n", .{
                self.key,
                @tagName(self.value),

                switch (self.value) {
                    .string => |str| str,
                    .boolean => |b| if (b) "true" else "false",
                    .int => |number| formatted: {
                        var buf: [256]u8 = undefined;
                        break :formatted std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
                    },
                    .float => |number| formatted: {
                        var buf: [256]u8 = undefined;
                        break :formatted std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
                    },
                },
            });
        }

        pub fn deinit(self: *Attribute) void {
            self.allocator.free(self.key);

            switch (self.value) {
                .string => |*ptr| self.allocator.free(ptr.*),
                else => {},
            }
        }
    };

    const Section = struct {
        allocator: std.mem.Allocator,
        name: []u8,
        attributes: std.ArrayList(Attribute),

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Section {
            return Section{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch unreachable,
                .attributes = std.ArrayList(Attribute).init(allocator),
            };
        }

        pub fn get(self: Section, name: []const u8) ?Attribute {
            for (self.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.key, name)) {
                    return attr;
                }
            }

            return null;
        }

        pub const ListAttributeIterator = struct {
            attributes: []Attribute,
            name: []const u8,
            index: usize = 0,

            pub fn next(self: *ListAttributeIterator) ?Attribute {
                const index = self.index;
                for (self.attributes[index..]) |element| {
                    self.index += 1;
                    if (std.mem.eql(u8, self.name, element.key)) {
                        return element;
                    }
                }
                return null;
            }
        };

        pub fn iterate(self: Section, name: []const u8) ListAttributeIterator {
            return ListAttributeIterator{
                .attributes = self.attributes.items,
                .name = name,
            };
        }

        pub fn deinit(self: *Section) void {
            self.allocator.free(self.name);
            for (self.attributes.items) |*attr| attr.deinit();
            self.attributes.deinit();
        }
    };

    sections: std.ArrayList(Section),

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{ .sections = std.ArrayList(Section).init(allocator) };
    }

    fn isSection(input: []const u8) ?[]const u8 {
        if (input[0] == '[' and input[input.len - 1] == ']') {
            return input[1 .. input.len - 1];
        }

        return null;
    }

    pub const InputPopulateError = anyerror || error{
        InputKeyNotFound,
        InputValueNotFound,
    };

    fn populateWithInput(allocator: std.mem.Allocator, config: *Config, current_section: *Section, input: []const u8) InputPopulateError!void {
        if (std.mem.eql(u8, input, "") or input[0] == '#') {
            return;
        }

        if (isSection(input)) |section_name| {
            try config.sections.append(current_section.*);
            current_section.* = Section.init(allocator, section_name);
            return;
        }

        // var it = std.mem.tokenizeAny(u8, input, "=");

        // const key = it.next() orelse return error.InputKeyNotFound;
        // const value = it.next() orelse return error.InputValueNotFound;

        const result = value: {
            const sepindex: ?usize = idx: {
                for (0.., input) |i, c| {
                    if (c == '=') {
                        break :idx i;
                    }
                }

                break :idx null;
            };

            if (sepindex) |idx| {
                break :value .{
                    .key = input[0 .. idx],
                    .value = input[idx + 1 .. input.len],
                };
            }

            return error.InvalidKeyValuePair;
        };

        try current_section.attributes.append(try Attribute.init(
            allocator,
            result.key,
            result.value,
        ));
    }

    pub fn parseFile(allocator: std.mem.Allocator, filename: []const u8) !Config {
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        var line_buf: [1024]u8 = undefined;
        var current_section = Section.init(allocator, "root");
        var config = init(allocator);

        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            try populateWithInput(
                allocator,
                &config,
                &current_section,
                line,
            );
        }

        try config.sections.append(current_section);

        return config;
    }

    pub fn parseString(allocator: std.mem.Allocator, contents: []const u8) !Config {
        var it = std.mem.tokenizeAny(u8, contents, "\n");
        var current_section = Section.init(allocator, "root");
        var config = init(allocator);

        while (it.next()) |line| {
            try populateWithInput(
                allocator,
                &config,
                &current_section,
                line,
            );
        }

        try config.sections.append(current_section);

        return config;
    }

    pub fn get(self: Config, secname: []const u8) ?Section {
        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.name, secname)) {
                return section;
            }
        }

        return null;
    }

    pub fn deinit(self: *Config) void {
        for (self.sections.items) |*section| section.deinit();
        self.sections.deinit();
    }
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    debug.print(fmt, args);
    posix.exit(1);
}

fn genDoc(opts: *const struct {
    allocator: mem.Allocator,
    filename: []const u8,
    base: *const fs.Dir,
}) !void {
    var buf: [BUFFER_SIZE]u8 = undefined;
    const realpath = try opts.base.realpath(opts.filename, &buf);

    var config = Config.parseFile(opts.allocator, realpath) catch |err| {
        die("Unable to parse docfile '{s}': {s}\n", .{
            opts.filename,
            @errorName(err),
        });
    };

    defer config.deinit();

    var string_builder = ArrayList(u8).init(opts.allocator);
    defer string_builder.deinit();

    const writer = string_builder.writer();

    const root = config.get("root") orelse die("no config for {s}\n", .{opts.filename});
    const project_title = root.get("project") orelse die("No project name for {s}\n", .{opts.filename});
    const description = root.get("description") orelse die("No project description for {s}\n", .{opts.filename});

    debug.assert(project_title.value == .string);
    debug.assert(description.value == .string);

    try writer.print("# {s}\n\n", .{project_title.value.string});
    try writer.print("{s}\n", .{description.value.string});

    for (config.sections.items) |section| {
        if (mem.eql(u8, section.name, "root")) continue;

        const name = section.get("name") orelse die("Error for {s}: section {s} does not contain value for name\n", .{
            opts.filename,
            section.name,
        });

        debug.assert(name.value == .string);

        try writer.print("\n## {s}\n", .{name.value.string});

        if (section.get("description")) |sec_description| {
            debug.assert(sec_description.value == .string);

            try writer.print("\n{s}", .{sec_description.value.string});
        }

        var dependencies = section.iterate("dependencies");
        var cmd_sequence = section.iterate("cmd_sequence");

        if (section.get("dependencies") != null) {
            try writer.print("\n\n### Dependencies\n\n", .{});
            try writer.print("Make sure you have the next dependencies on the target system:\n", .{});
        }

        while (dependencies.next()) |dependency| {
            debug.assert(dependency.value == .string);
            try writer.print("\n- {s}", .{dependency.value.string});
        }

        const has_cmd_sequence = section.get("cmd_sequence") != null;

        if (has_cmd_sequence) {
            try writer.print("\n\n### Deploying\n\n", .{});
            try writer.print("Run the next commands on your system:\n", .{});
            try writer.print("\n```", .{});
        }

        while (cmd_sequence.next()) |cmd| {
            debug.assert(cmd.value == .string);
            try writer.print("\n{s}", .{cmd.value.string});
        }

        if (has_cmd_sequence) {
            try writer.print("\n```", .{});
        }
    }

    try writer.print("\n", .{});

    const file_contents = try string_builder.toOwnedSlice();
    defer opts.allocator.free(file_contents);

    var outfile = file: {
        const filename = root.get("outfile") orelse die("No outfile defined for {s}\n", .{opts.filename});
        debug.assert(filename.value == .string);
        break :file try fs.cwd().createFile(filename.value.string, .{
            .read = false,
            .truncate = true,
        });
    };

    defer outfile.close();

    var bw = io.bufferedWriter(outfile.writer());
    const fwriter = bw.writer();
    defer bw.flush() catch unreachable;

    try fwriter.writeAll(file_contents);
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) debug.print("memleak detected\n", .{});

    const allocator = gpa.allocator();

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    // ignore filename
    _ = args.next();

    var templates = folder: {
        const dirname = args.next() orelse return error.MissingTemplates;
        break :folder fs.cwd().openDir(dirname, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.NotDir => die("it seems to be that '{s}' is not a dir\n", .{ dirname }),
                else => return err,
            }
        };
    };

    defer templates.close();

    var walker = try templates.walk(allocator);
    defer walker.deinit();

    const stdout = io.getStdOut().writer();

    while (try walker.next()) |element| {
        try stdout.print("Generating docs for element '{s}'\n", .{element.path});
        try genDoc(&.{
            .allocator = allocator,
            .filename = element.path,
            .base = &templates,
        });
    }
}
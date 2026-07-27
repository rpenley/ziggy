const std = @import("std");
const types = @import("types.zig");

const Config = types.Config;
const max_config_bytes = types.max_config_bytes;

/// Looks for ziggy.zon in CWD, then in $HOME. Parses `.key = "value"` lines:
/// known keys update the corresponding Config field; unknown keys are stored in site_vars.
pub fn loadZonConfig(allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8, config: *Config) !void {
    const data = blk: {
        if (std.Io.Dir.cwd().readFileAlloc(io, "ziggy.zon", allocator, .limited(max_config_bytes))) |d| {
            break :blk d;
        } else |_| {}

        var home_dir = std.Io.Dir.openDirAbsolute(io, home orelse return, .{}) catch return;
        defer home_dir.close(io);
        if (home_dir.readFileAlloc(io, "ziggy.zon", allocator, .limited(max_config_bytes))) |d| {
            break :blk d;
        } else |_| {}

        return;
    };
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r,");
        if (!std.mem.startsWith(u8, trimmed, ".")) continue;

        // Match .key = "value"
        const eq = std.mem.indexOf(u8, trimmed, " = \"") orelse continue;
        const key = trimmed[1..eq];
        const value_start = eq + 4;
        const value_end = std.mem.lastIndexOf(u8, trimmed[value_start..], "\"") orelse continue;
        const value = trimmed[value_start .. value_start + value_end];

        if (std.mem.eql(u8, key, "content_dir")) config.content_dir = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "template")) config.template_dir = try std.fmt.allocPrint(allocator, "templates/{s}", .{value}) else if (std.mem.eql(u8, key, "publish_dir")) config.publish_dir = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "site_url")) config.site_url = try allocator.dupe(u8, value) else {
            try config.site_vars.put(
                try allocator.dupe(u8, key),
                try allocator.dupe(u8, value),
            );
        }
    }
}

fn nextArg(args: anytype, flag: []const u8) ?[]const u8 {
    const value = args.next() orelse {
        std.debug.print("error: {s} requires an argument\n", .{flag});
        return null;
    };
    return value;
}

/// Parses CLI args into config. Returns false if the program should exit (e.g. --help).
pub fn parseArgs(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args, config: *Config) !bool {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();
    _ = args.next(); // skip executable name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp(io);
            return false;
        } else if (std.mem.eql(u8, arg, "--content")) {
            config.content_dir = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
        } else if (std.mem.eql(u8, arg, "--template")) {
            const name = nextArg(&args, arg) orelse return false;
            config.template_dir = try std.fmt.allocPrint(allocator, "templates/{s}", .{name});
        } else if (std.mem.eql(u8, arg, "--publish")) {
            config.publish_dir = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
        } else if (std.mem.eql(u8, arg, "--site-url")) {
            config.site_url = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
        } else if (std.mem.eql(u8, arg, "--clean")) {
            config.clean = true;
        } else {
            std.debug.print("error: unknown argument '{s}'\n\n", .{arg});
            printHelp(io);
            return false;
        }
    }

    return true;
}

pub fn printHelp(io: std.Io) void {
    const help =
        \\ziggy - static site generator
        \\
        \\Usage: ziggy [options]
        \\
        \\Options:
        \\  --content <dir>    Content directory        (default: content)
        \\  --template <name>  Template name            (default: default)
        \\  --publish <dir>    Output directory         (default: publish)
        \\  --site-url <url>   Base URL for RSS feeds   (default: "")
        \\  --clean            Delete publish dir before building
        \\  -h, --help         Show this help
        \\
        \\Configuration:
        \\  ziggy.zon is loaded from the current directory first, then ~/ziggy.zon.
        \\  CLI flags override ziggy.zon settings.
        \\  Unknown keys in ziggy.zon become site-wide template variables.
        \\
        \\  Example ziggy.zon:
        \\  .{
        \\      .content_dir = "content",
        \\      .template    = "default",
        \\      .publish_dir = "publish",
        \\      .site_title  = "My Site",
        \\      .site_author = "Your Name",
        \\  }
        \\
    ;
    std.Io.File.stdout().writeStreamingAll(io, help) catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "loadZonConfig reads ziggy.zon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = std.testing.io;
    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd_len = try std.process.currentPath(io, &original_cwd_buf);
    const original_cwd = original_cwd_buf[0..original_cwd_len];

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "ziggy.zon", .{});
    try file.writeStreamingAll(io, ".{\n  .content_dir = \"my_content\",\n  .template = \"fancy\",\n}\n");
    file.close(io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_path_len];
    try std.process.setCurrentPath(io, tmp_path);
    defer std.process.setCurrentPath(io, original_cwd) catch {};

    var config = Config{
        .content_dir = "content",
        .template_dir = "templates/default",
        .publish_dir = "publish",
        .site_url = "",
        .clean = false,
        .site_vars = std.StringHashMap([]const u8).init(allocator),
    };
    try loadZonConfig(allocator, io, null, &config);

    try std.testing.expectEqualStrings("my_content", config.content_dir);
    try std.testing.expectEqualStrings("templates/fancy", config.template_dir);
    try std.testing.expectEqualStrings("publish", config.publish_dir);
}

test "loadZonConfig ignores comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = std.testing.io;
    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd_len = try std.process.currentPath(io, &original_cwd_buf);
    const original_cwd = original_cwd_buf[0..original_cwd_len];

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\.{
        \\    // This is a comment
        \\    .content_dir = "src",
        \\
        \\    // Another comment
        \\    .publish_dir = "out",
        \\}
    ;
    const file = try tmp.dir.createFile(io, "ziggy.zon", .{});
    try file.writeStreamingAll(io, content);
    file.close(io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_path_len];
    try std.process.setCurrentPath(io, tmp_path);
    defer std.process.setCurrentPath(io, original_cwd) catch {};

    var config = Config{
        .content_dir = "content",
        .template_dir = "templates/default",
        .publish_dir = "publish",
        .site_url = "",
        .clean = false,
        .site_vars = std.StringHashMap([]const u8).init(allocator),
    };
    try loadZonConfig(allocator, io, null, &config);

    try std.testing.expectEqualStrings("src", config.content_dir);
    try std.testing.expectEqualStrings("out", config.publish_dir);
    try std.testing.expectEqualStrings("templates/default", config.template_dir);
}

test "loadZonConfig template key resolves to templates/ path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = std.testing.io;
    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd_len = try std.process.currentPath(io, &original_cwd_buf);
    const original_cwd = original_cwd_buf[0..original_cwd_len];

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "ziggy.zon", .{});
    try file.writeStreamingAll(io, ".{\n    .template = \"default\",\n}\n");
    file.close(io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_path_len];
    try std.process.setCurrentPath(io, tmp_path);
    defer std.process.setCurrentPath(io, original_cwd) catch {};

    var config = Config{
        .content_dir = "content",
        .template_dir = "templates/default",
        .publish_dir = "publish",
        .site_url = "",
        .clean = false,
        .site_vars = std.StringHashMap([]const u8).init(allocator),
    };
    try loadZonConfig(allocator, io, null, &config);

    try std.testing.expectEqualStrings("templates/default", config.template_dir);
}

test "loadZonConfig site_vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = std.testing.io;
    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd_len = try std.process.currentPath(io, &original_cwd_buf);
    const original_cwd = original_cwd_buf[0..original_cwd_len];

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "ziggy.zon", .{});
    try file.writeStreamingAll(io, ".{\n  .site_title = \"My Blog\",\n  .site_author = \"Alice\",\n}\n");
    file.close(io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_path_len];
    try std.process.setCurrentPath(io, tmp_path);
    defer std.process.setCurrentPath(io, original_cwd) catch {};

    var config = Config{
        .content_dir = "content",
        .template_dir = "templates/default",
        .publish_dir = "publish",
        .site_url = "",
        .clean = false,
        .site_vars = std.StringHashMap([]const u8).init(allocator),
    };
    try loadZonConfig(allocator, io, null, &config);

    try std.testing.expectEqualStrings("My Blog", config.site_vars.get("site_title").?);
    try std.testing.expectEqualStrings("Alice", config.site_vars.get("site_author").?);
}

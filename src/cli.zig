const std = @import("std");
const types = @import("types.zig");

const Config = types.Config;
const max_config_bytes = types.max_config_bytes;

/// Looks for ziggy.zon in CWD, then in $HOME. Parses `.key = "value"` lines:
/// known keys update the corresponding Config field; unknown keys are stored in site_vars.
pub fn loadZonConfig(allocator: std.mem.Allocator, config: *Config) !void {
	const data = blk: {
		if (std.fs.cwd().readFileAlloc(allocator, "ziggy.zon", max_config_bytes)) |d| {
			break :blk d;
		} else |_| {}

		const home = std.posix.getenv("HOME") orelse return;
		var path_buf: [1024]u8 = undefined;
		const home_path = try std.fmt.bufPrint(&path_buf, "{s}/ziggy.zon", .{home});
		if (std.fs.openFileAbsolute(home_path, .{})) |file| {
			defer file.close();
			break :blk try file.readToEndAlloc(allocator, max_config_bytes);
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

		if (std.mem.eql(u8, key, "content_dir"))       config.content_dir  = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "template_dir")) config.template_dir = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "static_dir"))   config.static_dir   = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "publish_dir"))  config.publish_dir  = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "theme"))        config.theme        = try allocator.dupe(u8, value)
		else {
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
pub fn parseArgs(allocator: std.mem.Allocator, config: *Config) !bool {
	var args = try std.process.argsWithAllocator(allocator);
	defer args.deinit();
	_ = args.next(); // skip executable name

	while (args.next()) |arg| {
		if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
			printHelp();
			return false;
		} else if (std.mem.eql(u8, arg, "--content")) {
			config.content_dir  = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
		} else if (std.mem.eql(u8, arg, "--templates")) {
			config.template_dir = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
		} else if (std.mem.eql(u8, arg, "--static")) {
			config.static_dir   = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
		} else if (std.mem.eql(u8, arg, "--publish")) {
			config.publish_dir  = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
		} else if (std.mem.eql(u8, arg, "--theme")) {
			config.theme        = try allocator.dupe(u8, nextArg(&args, arg) orelse return false);
		} else if (std.mem.eql(u8, arg, "--clean")) {
			config.clean = true;
		} else {
			std.debug.print("error: unknown argument '{s}'\n\n", .{arg});
			printHelp();
			return false;
		}
	}

	return true;
}

pub fn printHelp() void {
	const help =
		\\ziggy - static site generator
		\\
		\\Usage: ziggy [options]
		\\
		\\Options:
		\\  --content <dir>    Content directory        (default: content)
		\\  --templates <dir>  Templates directory      (default: template)
		\\  --static <dir>     Static files directory   (default: static)
		\\  --publish <dir>    Output directory         (default: publish)
		\\  --theme <name>     Template theme to use    (default: default)
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
		\\      .content_dir  = "content",
		\\      .template_dir = "template",
		\\      .static_dir   = "static",
		\\      .publish_dir  = "publish",
		\\      .theme        = "default",
		\\      .site_title   = "My Site",
		\\      .site_author  = "Your Name",
		\\  }
		\\
	;
	std.fs.File.stdout().writeAll(help) catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "loadZonConfig reads ziggy.zon" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
	const original_cwd = try std.fs.cwd().realpath(".", &original_cwd_buf);

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const file = try tmp.dir.createFile("ziggy.zon", .{});
	try file.writeAll(".{\n  .content_dir = \"my_content\",\n  .theme = \"fancy\",\n}\n");
	file.close();

	var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);
	try std.posix.chdir(tmp_path);
	defer std.posix.chdir(original_cwd) catch {};

	var config = Config{
		.content_dir  = "content",
		.template_dir = "template",
		.static_dir   = "static",
		.publish_dir  = "publish",
		.theme        = "default",
		.clean        = false,
		.site_vars    = std.StringHashMap([]const u8).init(allocator),
	};
	try loadZonConfig(allocator, &config);

	try std.testing.expectEqualStrings("my_content", config.content_dir);
	try std.testing.expectEqualStrings("fancy", config.theme);
	try std.testing.expectEqualStrings("publish", config.publish_dir);
}

test "loadZonConfig site_vars" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
	const original_cwd = try std.fs.cwd().realpath(".", &original_cwd_buf);

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const file = try tmp.dir.createFile("ziggy.zon", .{});
	try file.writeAll(".{\n  .site_title = \"My Blog\",\n  .site_author = \"Alice\",\n}\n");
	file.close();

	var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);
	try std.posix.chdir(tmp_path);
	defer std.posix.chdir(original_cwd) catch {};

	var config = Config{
		.content_dir  = "content",
		.template_dir = "template",
		.static_dir   = "static",
		.publish_dir  = "publish",
		.theme        = "default",
		.clean        = false,
		.site_vars    = std.StringHashMap([]const u8).init(allocator),
	};
	try loadZonConfig(allocator, &config);

	try std.testing.expectEqualStrings("My Blog", config.site_vars.get("site_title").?);
	try std.testing.expectEqualStrings("Alice",   config.site_vars.get("site_author").?);
}

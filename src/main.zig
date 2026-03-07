const std = @import("std");
const zmd = @import("zmd");

const Config = struct {
	content_dir:  []const u8,
	template_dir: []const u8,
	static_dir:   []const u8,
	publish_dir:  []const u8,
	theme:        []const u8,
};

const default_config = Config{
	.content_dir  = "content",
	.template_dir = "template",
	.static_dir   = "static",
	.publish_dir  = "publish",
	.theme        = "default",
};

const Post = struct {
	title:       []const u8,
	date:        []const u8,
	description: []const u8,
	slug:        []const u8,
};

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	// Arena for config strings — freed at the end of main.
	var config_arena = std.heap.ArenaAllocator.init(allocator);
	defer config_arena.deinit();
	const config_allocator = config_arena.allocator();

	var config = default_config;
	try loadZonConfig(config_allocator, &config);
	if (!try parseArgs(config_allocator, &config)) return;

	var path_buf: [1024]u8 = undefined;

	try std.fs.cwd().makePath(config.publish_dir);
	const posts_pub = try std.fmt.bufPrint(&path_buf, "{s}/posts", .{config.publish_dir});
	try std.fs.cwd().makePath(posts_pub);

	// Top-level content pages.
	{
		var content_dir = try std.fs.cwd().openDir(config.content_dir, .{ .iterate = true });
		defer content_dir.close();

		var iterator = content_dir.iterate();
		while (try iterator.next()) |entry| {
			if (entry.kind != .file) continue;
			if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

			const source = try content_dir.readFileAlloc(allocator, entry.name, 1 * 1024 * 1024);
			defer allocator.free(source);

			var vars = std.StringHashMap([]const u8).init(allocator);
			defer vars.deinit();

			const stem = entry.name[0 .. entry.name.len - 3];
			const body_md = try parseFrontMatter(source, &vars);
			const body_html = try zmd.parse(allocator, body_md, .{});
			defer allocator.free(body_html);

			try vars.put("content", body_html);

			const tmpl = try loadTemplate(allocator, &config, stem);
			defer allocator.free(tmpl);
			const output = try renderMustache(allocator, tmpl, &vars);
			defer allocator.free(output);

			const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.html", .{ config.publish_dir, stem });
			const out_file = try std.fs.cwd().createFile(out_path, .{});
			defer out_file.close();
			try out_file.writeAll(output);

			std.debug.print("Generated {s}\n", .{out_path});
		}
	}

	// Posts.
	var posts = try processPosts(allocator, &config);
	defer {
		for (posts.items) |post| {
			allocator.free(post.title);
			allocator.free(post.date);
			allocator.free(post.description);
			allocator.free(post.slug);
		}
		posts.deinit(allocator);
	}

	sortPostsByDate(posts.items);
	try generateBlogIndex(allocator, &config, posts.items);

	try copyStaticFiles(allocator, &config);
}

fn processPosts(allocator: std.mem.Allocator, config: *const Config) !std.ArrayList(Post) {
	var posts: std.ArrayList(Post) = .empty;

	var path_buf: [1024]u8 = undefined;
	const posts_content = try std.fmt.bufPrint(&path_buf, "{s}/posts", .{config.content_dir});

	var posts_dir = std.fs.cwd().openDir(posts_content, .{ .iterate = true }) catch |err| {
		if (err == error.FileNotFound) return posts;
		return err;
	};
	defer posts_dir.close();

	var iterator = posts_dir.iterate();
	while (try iterator.next()) |entry| {
		if (entry.kind != .file) continue;
		if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

		const source = try posts_dir.readFileAlloc(allocator, entry.name, 1 * 1024 * 1024);
		defer allocator.free(source);

		var vars = std.StringHashMap([]const u8).init(allocator);
		defer vars.deinit();

		const body_md = try parseFrontMatter(source, &vars);
		const body_html = try zmd.parse(allocator, body_md, .{});
		defer allocator.free(body_html);

		try vars.put("content", body_html);

		const tmpl = try loadTemplate(allocator, config, "post");
		defer allocator.free(tmpl);
		const output = try renderMustache(allocator, tmpl, &vars);
		defer allocator.free(output);

		const stem = entry.name[0 .. entry.name.len - 3];
		var out_buf: [1024]u8 = undefined;
		const out_path = try std.fmt.bufPrint(&out_buf, "{s}/posts/{s}.html", .{ config.publish_dir, stem });
		const out_file = try std.fs.cwd().createFile(out_path, .{});
		defer out_file.close();
		try out_file.writeAll(output);

		std.debug.print("Generated {s}\n", .{out_path});

		try posts.append(allocator, .{
			.title       = try allocator.dupe(u8, vars.get("title") orelse ""),
			.date        = try allocator.dupe(u8, vars.get("date") orelse ""),
			.description = try allocator.dupe(u8, vars.get("description") orelse ""),
			.slug        = try allocator.dupe(u8, stem),
		});
	}

	return posts;
}

fn sortPostsByDate(posts: []Post) void {
	var i: usize = 1;
	while (i < posts.len) : (i += 1) {
		const key = posts[i];
		var j: usize = i;
		while (j > 0 and std.mem.order(u8, posts[j - 1].date, key.date) == .lt) : (j -= 1) {
			posts[j] = posts[j - 1];
		}
		posts[j] = key;
	}
}

fn generateBlogIndex(
	allocator: std.mem.Allocator,
	config: *const Config,
	posts: []const Post,
) !void {
	var content: std.ArrayList(u8) = .empty;
	defer content.deinit(allocator);

	try content.writer(allocator).writeAll("<h1>blog</h1>\n");

	if (posts.len == 0) {
		try content.writer(allocator).writeAll("<p>No posts yet.</p>\n");
	} else {
		try content.writer(allocator).writeAll("<ul class=\"post-list\">\n");
		for (posts) |post| {
			try content.writer(allocator).print(
				"  <li class=\"post-item\">\n" ++
				"    <div class=\"post-item-header\">\n" ++
				"      <a href=\"/posts/{s}.html\">{s}</a>\n" ++
				"      <span class=\"post-date\">{s}</span>\n" ++
				"    </div>\n" ++
				"    <p>{s}</p>\n" ++
				"  </li>\n",
				.{ post.slug, post.title, post.date, post.description },
			);
		}
		try content.writer(allocator).writeAll("</ul>\n");
	}

	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	try vars.put("title", "blog");
	try vars.put("description", "all posts");
	try vars.put("content", content.items);

	const tmpl = try loadTemplate(allocator, config, "blog");
	defer allocator.free(tmpl);
	const output = try renderMustache(allocator, tmpl, &vars);
	defer allocator.free(output);

	var path_buf: [1024]u8 = undefined;
	const out_path = try std.fmt.bufPrint(&path_buf, "{s}/blog.html", .{config.publish_dir});
	const out_file = try std.fs.cwd().createFile(out_path, .{});
	defer out_file.close();
	try out_file.writeAll(output);

	std.debug.print("Generated {s}\n", .{out_path});
}

fn copyStaticFiles(allocator: std.mem.Allocator, config: *const Config) !void {
	var static_dir = std.fs.cwd().openDir(config.static_dir, .{ .iterate = true }) catch |err| {
		if (err == error.FileNotFound) return;
		return err;
	};
	defer static_dir.close();

	var iterator = static_dir.iterate();
	while (try iterator.next()) |entry| {
		if (entry.kind != .file) continue;

		const data = try static_dir.readFileAlloc(allocator, entry.name, 4 * 1024 * 1024);
		defer allocator.free(data);

		var path_buf: [1024]u8 = undefined;
		const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config.publish_dir, entry.name });
		const out_file = try std.fs.cwd().createFile(out_path, .{});
		defer out_file.close();
		try out_file.writeAll(data);

		std.debug.print("Copied    {s}\n", .{out_path});
	}
}

/// Tries {template_dir}/{theme}/{stem}.mustache, then {template_dir}/{theme}/default.mustache,
/// then {template_dir}/default/default.mustache if theme is not already "default".
fn loadTemplate(allocator: std.mem.Allocator, config: *const Config, stem: []const u8) ![]const u8 {
	var path_buf: [1024]u8 = undefined;

	const specific = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.mustache", .{ config.template_dir, config.theme, stem });
	if (std.fs.cwd().readFileAlloc(allocator, specific, 1 * 1024 * 1024)) |content| {
		return content;
	} else |_| {}

	const fallback = try std.fmt.bufPrint(&path_buf, "{s}/{s}/default.mustache", .{ config.template_dir, config.theme });
	if (std.fs.cwd().readFileAlloc(allocator, fallback, 1 * 1024 * 1024)) |content| {
		return content;
	} else |_| {}

	if (!std.mem.eql(u8, config.theme, "default")) {
		const last_resort = try std.fmt.bufPrint(&path_buf, "{s}/default/default.mustache", .{config.template_dir});
		return std.fs.cwd().readFileAlloc(allocator, last_resort, 1 * 1024 * 1024);
	}

	return error.TemplateNotFound;
}

/// Looks for ziggy.zon in CWD, then in $HOME. Parses `.key = "value"` lines
/// and overwrites matching fields in config.
fn loadZonConfig(allocator: std.mem.Allocator, config: *Config) !void {
	const data = blk: {
		if (std.fs.cwd().readFileAlloc(allocator, "ziggy.zon", 64 * 1024)) |d| {
			break :blk d;
		} else |_| {}

		const home = std.posix.getenv("HOME") orelse return;
		var path_buf: [1024]u8 = undefined;
		const home_path = try std.fmt.bufPrint(&path_buf, "{s}/ziggy.zon", .{home});
		if (std.fs.cwd().readFileAlloc(allocator, home_path, 64 * 1024)) |d| {
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

		if (std.mem.eql(u8, key, "content_dir"))       config.content_dir  = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "template_dir")) config.template_dir = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "static_dir"))   config.static_dir   = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "publish_dir"))  config.publish_dir  = try allocator.dupe(u8, value)
		else if (std.mem.eql(u8, key, "theme"))        config.theme        = try allocator.dupe(u8, value);
	}
}

/// Parses CLI args into config. Returns false if the program should exit (e.g. --help).
fn parseArgs(allocator: std.mem.Allocator, config: *Config) !bool {
	var args = try std.process.argsWithAllocator(allocator);
	defer args.deinit();
	_ = args.next(); // skip executable name

	while (args.next()) |arg| {
		if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
			printHelp();
			return false;
		} else if (std.mem.eql(u8, arg, "--content")) {
			config.content_dir = try allocator.dupe(u8, args.next() orelse {
				std.debug.print("error: --content requires a directory argument\n", .{});
				return false;
			});
		} else if (std.mem.eql(u8, arg, "--templates")) {
			config.template_dir = try allocator.dupe(u8, args.next() orelse {
				std.debug.print("error: --templates requires a directory argument\n", .{});
				return false;
			});
		} else if (std.mem.eql(u8, arg, "--static")) {
			config.static_dir = try allocator.dupe(u8, args.next() orelse {
				std.debug.print("error: --static requires a directory argument\n", .{});
				return false;
			});
		} else if (std.mem.eql(u8, arg, "--publish")) {
			config.publish_dir = try allocator.dupe(u8, args.next() orelse {
				std.debug.print("error: --publish requires a directory argument\n", .{});
				return false;
			});
		} else if (std.mem.eql(u8, arg, "--theme")) {
			config.theme = try allocator.dupe(u8, args.next() orelse {
				std.debug.print("error: --theme requires a name argument\n", .{});
				return false;
			});
		} else {
			std.debug.print("error: unknown argument '{s}'\n\n", .{arg});
			printHelp();
			return false;
		}
	}

	return true;
}

fn printHelp() void {
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
		\\  -h, --help         Show this help
		\\
		\\Configuration:
		\\  ziggy.zon is loaded from the current directory first, then ~/ziggy.zon.
		\\  CLI flags override ziggy.zon settings.
		\\
		\\  Example ziggy.zon:
		\\  .{
		\\      .content_dir  = "content",
		\\      .template_dir = "template",
		\\      .static_dir   = "static",
		\\      .publish_dir  = "publish",
		\\      .theme        = "default",
		\\  }
		\\
	;
	std.debug.print("{s}", .{help});
}

/// Strips YAML front matter (between leading `---` fences) from `source`,
/// populates `vars` with the key/value pairs, and returns the markdown body.
/// All returned slices are views into `source` — no allocation.
fn parseFrontMatter(source: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
	const open = "---\n";
	if (!std.mem.startsWith(u8, source, open)) return source;

	const rest = source[open.len..];
	const close_off = std.mem.indexOf(u8, rest, "\n---\n") orelse return source;

	var lines = std.mem.splitScalar(u8, rest[0..close_off], '\n');
	while (lines.next()) |line| {
		const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
		const key   = std.mem.trim(u8, line[0..colon],     " \t");
		const value = std.mem.trim(u8, line[colon + 2 ..], " \t");
		if (key.len > 0) try vars.put(key, value);
	}

	return rest[close_off + 5 ..];
}

/// Substitutes `{{ key }}` tags in `template` with values from `vars`.
/// Unrecognised keys are replaced with an empty string.
fn renderMustache(
	allocator: std.mem.Allocator,
	template: []const u8,
	vars: *const std.StringHashMap([]const u8),
) ![]const u8 {
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(allocator);

	var pos: usize = 0;
	while (pos < template.len) {
		const open = std.mem.indexOf(u8, template[pos..], "{{") orelse {
			try out.appendSlice(allocator, template[pos..]);
			break;
		};

		try out.appendSlice(allocator, template[pos .. pos + open]);
		const tag_start = pos + open + 2;

		const close = std.mem.indexOf(u8, template[tag_start..], "}}") orelse {
			try out.appendSlice(allocator, "{{");
			try out.appendSlice(allocator, template[tag_start..]);
			break;
		};

		const key = std.mem.trim(u8, template[tag_start .. tag_start + close], " \t");
		if (vars.get(key)) |val| try out.appendSlice(allocator, val);
		pos = tag_start + close + 2;
	}

	return out.toOwnedSlice(allocator);
}

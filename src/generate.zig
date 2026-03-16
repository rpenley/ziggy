const std = @import("std");
const zmd = @import("zmd");
const types = @import("types.zig");
const parse = @import("parse.zig");
const render = @import("render.zig");

const Config = types.Config;
const ListItem = types.ListItem;
const max_content_bytes = types.max_content_bytes;
const max_static_bytes = types.max_static_bytes;

pub fn discoverContentTypes(
	allocator: std.mem.Allocator,
	config: *const Config,
) !std.ArrayList([]const u8) {
	var result: std.ArrayList([]const u8) = .empty;

	var content_dir = std.fs.cwd().openDir(config.content_dir, .{ .iterate = true }) catch |err| {
		if (err == error.FileNotFound) return result;
		return err;
	};
	defer content_dir.close();

	var iterator = content_dir.iterate();
	while (try iterator.next()) |entry| {
		if (entry.kind != .directory) continue;
		try result.append(allocator, try allocator.dupe(u8, entry.name));
	}

	return result;
}

pub fn processContentType(
	allocator: std.mem.Allocator,
	config: *const Config,
	content_type: []const u8,
) !std.ArrayList(ListItem) {
	var items: std.ArrayList(ListItem) = .empty;

	var path_buf: [1024]u8 = undefined;
	const type_content = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config.content_dir, content_type });

	var type_dir = std.fs.cwd().openDir(type_content, .{ .iterate = true }) catch |err| {
		if (err == error.FileNotFound) return items;
		return err;
	};
	defer type_dir.close();

	// Template stem: {type}-post → tries {theme}/{type}-post.mustache then {theme}/default.mustache
	var tmpl_stem_buf: [256]u8 = undefined;
	const tmpl_stem = try std.fmt.bufPrint(&tmpl_stem_buf, "{s}-post", .{content_type});

	var iterator = type_dir.iterate();
	while (try iterator.next()) |entry| {
		if (entry.kind != .file) continue;
		if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

		const source = try type_dir.readFileAlloc(allocator, entry.name, max_content_bytes);
		defer allocator.free(source);

		var vars = std.StringHashMap([]const u8).init(allocator);
		defer vars.deinit();

		var site_iter = config.site_vars.iterator();
		while (site_iter.next()) |kv| try vars.put(kv.key_ptr.*, kv.value_ptr.*);

		const body_md = try parse.parseFrontMatter(source, &vars);
		const body_html = try zmd.parse(allocator, body_md, .{});
		defer allocator.free(body_html);

		try vars.put("content", body_html);

		const tmpl = try render.loadTemplate(allocator, config, tmpl_stem);
		defer allocator.free(tmpl);

		const output = try render.renderMustache(allocator, tmpl, &vars);
		defer allocator.free(output);

		const stem = entry.name[0 .. entry.name.len - 3];
		var out_buf: [1024]u8 = undefined;
		const out_path = try std.fmt.bufPrint(&out_buf, "{s}/{s}/{s}.html", .{ config.publish_dir, content_type, stem });
		const out_file = try std.fs.cwd().createFile(out_path, .{});
		defer out_file.close();
		try out_file.writeAll(output);

		var line_buf: [1200]u8 = undefined;
		const line = try std.fmt.bufPrint(&line_buf, "Generated {s}\n", .{out_path});
		try std.fs.File.stdout().writeAll(line);

		try items.append(allocator, .{
			.title       = try allocator.dupe(u8, vars.get("title") orelse ""),
			.date        = try allocator.dupe(u8, vars.get("date") orelse ""),
			.description = try allocator.dupe(u8, vars.get("description") orelse ""),
			.slug        = try allocator.dupe(u8, stem),
		});
	}

	return items;
}

pub fn sortItemsByDate(items: []ListItem) void {
	var i: usize = 1;
	while (i < items.len) : (i += 1) {
		const key = items[i];
		var j: usize = i;
		while (j > 0 and std.mem.order(u8, items[j - 1].date, key.date) == .lt) : (j -= 1) {
			items[j] = items[j - 1];
		}
		items[j] = key;
	}
}

pub fn generateTypeIndex(
	allocator: std.mem.Allocator,
	config: *const Config,
	content_type: []const u8,
	items: []const ListItem,
) !void {
	var content: std.ArrayList(u8) = .empty;
	defer content.deinit(allocator);

	if (items.len == 0) {
		try content.appendSlice(allocator, "<p>No posts yet.</p>\n");
	} else {
		const list_item_partial = render.loadPartial(allocator, config, "list-item") catch "<li>{{ title }}</li>\n";
		defer allocator.free(list_item_partial);

		try content.appendSlice(allocator, "<ul class=\"post-list\">\n");
		for (items) |item| {
			var item_vars = std.StringHashMap([]const u8).init(allocator);
			defer item_vars.deinit();
			try item_vars.put("type",        content_type);
			try item_vars.put("slug",        item.slug);
			try item_vars.put("title",       item.title);
			try item_vars.put("date",        item.date);
			try item_vars.put("description", item.description);

			const rendered = try render.renderMustache(allocator, list_item_partial, &item_vars);
			defer allocator.free(rendered);
			try content.appendSlice(allocator, rendered);
		}
		try content.appendSlice(allocator, "</ul>\n");
	}

	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();

	var site_iter = config.site_vars.iterator();
	while (site_iter.next()) |kv| try vars.put(kv.key_ptr.*, kv.value_ptr.*);

	try vars.put("title", content_type);
	try vars.put("description", content_type);
	try vars.put("content", content.items);

	var tmpl_stem_buf: [256]u8 = undefined;
	const tmpl_stem = try std.fmt.bufPrint(&tmpl_stem_buf, "{s}-index", .{content_type});
	const tmpl = try render.loadTemplate(allocator, config, tmpl_stem);
	defer allocator.free(tmpl);

	const output = try render.renderMustache(allocator, tmpl, &vars);
	defer allocator.free(output);

	var path_buf: [1024]u8 = undefined;
	const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.html", .{ config.publish_dir, content_type });
	const out_file = try std.fs.cwd().createFile(out_path, .{});
	defer out_file.close();
	try out_file.writeAll(output);

	var line_buf: [1200]u8 = undefined;
	const line = try std.fmt.bufPrint(&line_buf, "Generated {s}\n", .{out_path});
	try std.fs.File.stdout().writeAll(line);
}

pub fn copyStaticFiles(allocator: std.mem.Allocator, config: *const Config) !void {
	var static_dir = std.fs.cwd().openDir(config.static_dir, .{ .iterate = true }) catch |err| {
		if (err == error.FileNotFound) return;
		return err;
	};
	defer static_dir.close();

	var publish_dir = try std.fs.cwd().openDir(config.publish_dir, .{});
	defer publish_dir.close();

	try copyDirRecursive(allocator, static_dir, publish_dir, config.publish_dir, "");
}

pub fn copyDirRecursive(
	allocator: std.mem.Allocator,
	source_dir: std.fs.Dir,
	dest_dir: std.fs.Dir,
	publish_base: []const u8,
	rel_prefix: []const u8,
) !void {
	var iterator = source_dir.iterate();
	while (try iterator.next()) |entry| {
		if (entry.kind == .file) {
			const data = try source_dir.readFileAlloc(allocator, entry.name, max_static_bytes);
			defer allocator.free(data);

			const out_file = try dest_dir.createFile(entry.name, .{});
			defer out_file.close();
			try out_file.writeAll(data);

			var path_buf: [1024]u8 = undefined;
			const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ publish_base, rel_prefix, entry.name });
			var line_buf: [1200]u8 = undefined;
			const line = try std.fmt.bufPrint(&line_buf, "Copied    {s}\n", .{out_path});
			try std.fs.File.stdout().writeAll(line);
		} else if (entry.kind == .directory) {
			try dest_dir.makePath(entry.name);

			var sub_source = try source_dir.openDir(entry.name, .{ .iterate = true });
			defer sub_source.close();
			var sub_dest = try dest_dir.openDir(entry.name, .{});
			defer sub_dest.close();

			var new_prefix_buf: [512]u8 = undefined;
			const new_prefix = try std.fmt.bufPrint(&new_prefix_buf, "{s}{s}/", .{ rel_prefix, entry.name });
			try copyDirRecursive(allocator, sub_source, sub_dest, publish_base, new_prefix);
		}
	}
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "sortItemsByDate ascending to descending" {
	var items = [_]ListItem{
		.{ .title = "", .date = "2024-01-01", .description = "", .slug = "" },
		.{ .title = "", .date = "2024-02-01", .description = "", .slug = "" },
		.{ .title = "", .date = "2024-03-01", .description = "", .slug = "" },
	};
	sortItemsByDate(&items);
	try std.testing.expectEqualStrings("2024-03-01", items[0].date);
	try std.testing.expectEqualStrings("2024-02-01", items[1].date);
	try std.testing.expectEqualStrings("2024-01-01", items[2].date);
}

test "sortItemsByDate already descending" {
	var items = [_]ListItem{
		.{ .title = "", .date = "2024-03-01", .description = "", .slug = "" },
		.{ .title = "", .date = "2024-01-01", .description = "", .slug = "" },
	};
	sortItemsByDate(&items);
	try std.testing.expectEqualStrings("2024-03-01", items[0].date);
	try std.testing.expectEqualStrings("2024-01-01", items[1].date);
}

test "sortItemsByDate single item" {
	var items = [_]ListItem{
		.{ .title = "", .date = "2024-01-01", .description = "", .slug = "" },
	};
	sortItemsByDate(&items);
	try std.testing.expectEqualStrings("2024-01-01", items[0].date);
}

test "sortItemsByDate empty slice" {
	var items = [_]ListItem{};
	sortItemsByDate(&items);
}

test "sortItemsByDate duplicate dates" {
	var items = [_]ListItem{
		.{ .title = "", .date = "2024-01-01", .description = "", .slug = "" },
		.{ .title = "", .date = "2024-01-01", .description = "", .slug = "" },
	};
	sortItemsByDate(&items);
	try std.testing.expectEqualStrings("2024-01-01", items[0].date);
	try std.testing.expectEqualStrings("2024-01-01", items[1].date);
}

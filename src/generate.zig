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

fn tagsToHtml(allocator: std.mem.Allocator, tags_csv: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, tags_csv, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |part| {
        const tag = std.mem.trim(u8, part, " \t\r\n");
        if (tag.len == 0) continue;
        try out.appendSlice(allocator, "<a href=\"/tag/");
        try out.appendSlice(allocator, tag);
        try out.appendSlice(allocator, ".html\" class=\"tag\">");
        try out.appendSlice(allocator, tag);
        try out.appendSlice(allocator, "</a> ");
    }

    return out.toOwnedSlice(allocator);
}

pub fn processContentType(
    allocator: std.mem.Allocator,
    config: *const Config,
    content_type: []const u8,
    tag_map: *std.StringHashMap(std.ArrayList(ListItem)),
) !std.ArrayList(ListItem) {
    var items: std.ArrayList(ListItem) = .empty;

    var path_buf: [1024]u8 = undefined;
    const type_content = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config.content_dir, content_type });

    var type_dir = std.fs.cwd().openDir(type_content, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return items;
        return err;
    };
    defer type_dir.close();

    // Template stem: {type}-post → tries {template_dir}/{type}-post.mustache then {template_dir}/default.mustache
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

        const tags_csv = vars.get("tags") orelse "";
        const tags_html = try tagsToHtml(allocator, tags_csv);
        defer allocator.free(tags_html);
        try vars.put("tags_html", tags_html);
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
            .title = try allocator.dupe(u8, vars.get("title") orelse ""),
            .date = try allocator.dupe(u8, vars.get("date") orelse ""),
            .description = try allocator.dupe(u8, vars.get("description") orelse ""),
            .slug = try allocator.dupe(u8, stem),
            .content_type = try allocator.dupe(u8, content_type),
            .tags = try allocator.dupe(u8, tags_csv),
        });

        var tag_iter = std.mem.splitScalar(u8, tags_csv, ',');
        while (tag_iter.next()) |part| {
            const tag = std.mem.trim(u8, part, " \t\r\n");
            if (tag.len == 0) continue;
            const tag_key = try allocator.dupe(u8, tag);
            const gop = try tag_map.getOrPut(tag_key);
            if (gop.found_existing) {
                allocator.free(tag_key);
            } else {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(allocator, .{
                .title = try allocator.dupe(u8, vars.get("title") orelse ""),
                .date = try allocator.dupe(u8, vars.get("date") orelse ""),
                .description = try allocator.dupe(u8, vars.get("description") orelse ""),
                .slug = try allocator.dupe(u8, stem),
                .content_type = try allocator.dupe(u8, content_type),
                .tags = try allocator.dupe(u8, tags_csv),
            });
        }
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
            try item_vars.put("type", content_type);
            try item_vars.put("slug", item.slug);
            try item_vars.put("title", item.title);
            try item_vars.put("date", item.date);
            try item_vars.put("description", item.description);
            const item_tags_html = tagsToHtml(allocator, item.tags) catch try allocator.dupe(u8, "");
            defer allocator.free(item_tags_html);
            try item_vars.put("tags_html", item_tags_html);

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

pub fn generateTagPages(
    allocator: std.mem.Allocator,
    config: *const Config,
    tag_map: *const std.StringHashMap(std.ArrayList(ListItem)),
) !void {
    var path_buf: [1024]u8 = undefined;
    const tag_dir = try std.fmt.bufPrint(&path_buf, "{s}/tag", .{config.publish_dir});
    try std.fs.cwd().makePath(tag_dir);

    const list_item_partial = render.loadPartial(allocator, config, "list-item") catch try allocator.dupe(u8, "<li>{{ title }}</li>\n");
    defer allocator.free(list_item_partial);

    var map_iter = tag_map.iterator();
    while (map_iter.next()) |entry| {
        const tag = entry.key_ptr.*;
        const tag_items = entry.value_ptr.*;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);

        if (tag_items.items.len == 0) {
            try content.appendSlice(allocator, "<p>No posts yet.</p>\n");
        } else {
            try content.appendSlice(allocator, "<ul class=\"post-list\">\n");
            for (tag_items.items) |item| {
                var item_vars = std.StringHashMap([]const u8).init(allocator);
                defer item_vars.deinit();
                try item_vars.put("type", item.content_type);
                try item_vars.put("slug", item.slug);
                try item_vars.put("title", item.title);
                try item_vars.put("date", item.date);
                try item_vars.put("description", item.description);
                const item_tags_html = try tagsToHtml(allocator, item.tags);
                defer allocator.free(item_tags_html);
                try item_vars.put("tags_html", item_tags_html);

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

        var title_buf: [256]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "tag: {s}", .{tag});
        try vars.put("title", title);
        try vars.put("description", tag);
        try vars.put("content", content.items);

        const tmpl = try render.loadTemplate(allocator, config, "tag");
        defer allocator.free(tmpl);

        const output = try render.renderMustache(allocator, tmpl, &vars);
        defer allocator.free(output);

        var out_buf: [1024]u8 = undefined;
        const out_path = try std.fmt.bufPrint(&out_buf, "{s}/tag/{s}.html", .{ config.publish_dir, tag });
        const out_file = try std.fs.cwd().createFile(out_path, .{});
        defer out_file.close();
        try out_file.writeAll(output);

        var line_buf: [1200]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "Generated {s}\n", .{out_path});
        try std.fs.File.stdout().writeAll(line);
    }
}

fn dateToRfc822(allocator: std.mem.Allocator, date: []const u8) ![]u8 {
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    // Expect "YYYY-MM-DD"
    if (date.len < 10 or date[4] != '-' or date[7] != '-') {
        return allocator.dupe(u8, date);
    }
    const year = std.fmt.parseInt(u32, date[0..4], 10) catch return allocator.dupe(u8, date);
    const month = std.fmt.parseInt(u32, date[5..7], 10) catch return allocator.dupe(u8, date);
    const day = std.fmt.parseInt(u32, date[8..10], 10) catch return allocator.dupe(u8, date);
    if (month < 1 or month > 12) return allocator.dupe(u8, date);

    // Tomohiko Sakamoto's day-of-week algorithm
    const t = [_]u32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y: u32 = if (month < 3) year - 1 else year;
    const dow: usize = @intCast((y + y / 4 - y / 100 + y / 400 + t[month - 1] + day) % 7);

    return std.fmt.allocPrint(allocator, "{s}, {d:0>2} {s} {d} 00:00:00 +0000", .{
        day_names[dow],
        day,
        month_names[month - 1],
        year,
    });
}

pub fn generateRssFeed(
    allocator: std.mem.Allocator,
    config: *const Config,
    content_type: []const u8,
    items: []const ListItem,
) !void {
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(allocator);

    const base = if (config.site_url.len > 0) config.site_url else "";

    const channel_link = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ base, content_type });
    defer allocator.free(channel_link);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try xml.appendSlice(allocator, "<rss version=\"2.0\">\n");
    try xml.appendSlice(allocator, "  <channel>\n");

    const title_line = try std.fmt.allocPrint(allocator, "    <title>{s}</title>\n", .{content_type});
    defer allocator.free(title_line);
    try xml.appendSlice(allocator, title_line);

    const link_line = try std.fmt.allocPrint(allocator, "    <link>{s}</link>\n", .{channel_link});
    defer allocator.free(link_line);
    try xml.appendSlice(allocator, link_line);

    const desc_line = try std.fmt.allocPrint(allocator, "    <description>{s}</description>\n", .{content_type});
    defer allocator.free(desc_line);
    try xml.appendSlice(allocator, desc_line);

    for (items) |item| {
        const item_link = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.html", .{ base, content_type, item.slug });
        defer allocator.free(item_link);

        const pub_date = try dateToRfc822(allocator, item.date);
        defer allocator.free(pub_date);

        try xml.appendSlice(allocator, "    <item>\n");

        const item_title = try std.fmt.allocPrint(allocator, "      <title>{s}</title>\n", .{item.title});
        defer allocator.free(item_title);
        try xml.appendSlice(allocator, item_title);

        const item_link_line = try std.fmt.allocPrint(allocator, "      <link>{s}</link>\n", .{item_link});
        defer allocator.free(item_link_line);
        try xml.appendSlice(allocator, item_link_line);

        const item_desc = try std.fmt.allocPrint(allocator, "      <description>{s}</description>\n", .{item.description});
        defer allocator.free(item_desc);
        try xml.appendSlice(allocator, item_desc);

        const item_pubdate = try std.fmt.allocPrint(allocator, "      <pubDate>{s}</pubDate>\n", .{pub_date});
        defer allocator.free(item_pubdate);
        try xml.appendSlice(allocator, item_pubdate);

        const item_guid = try std.fmt.allocPrint(allocator, "      <guid>{s}</guid>\n", .{item_link});
        defer allocator.free(item_guid);
        try xml.appendSlice(allocator, item_guid);

        try xml.appendSlice(allocator, "    </item>\n");
    }

    try xml.appendSlice(allocator, "  </channel>\n");
    try xml.appendSlice(allocator, "</rss>\n");

    var path_buf: [1024]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.xml", .{ config.publish_dir, content_type });
    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(xml.items);

    var line_buf: [1200]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "Generated {s}\n", .{out_path});
    try std.fs.File.stdout().writeAll(line);
}

pub fn copyStaticFiles(allocator: std.mem.Allocator, config: *const Config) !void {
    var source_dir = std.fs.cwd().openDir(config.template_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer source_dir.close();

    var publish_dir = try std.fs.cwd().openDir(config.publish_dir, .{});
    defer publish_dir.close();

    try copyDirRecursive(allocator, source_dir, publish_dir, config.publish_dir, "");
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
            if (std.mem.endsWith(u8, entry.name, ".mustache")) continue;

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
            if (std.mem.eql(u8, entry.name, "partials")) continue;

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

test "dateToRfc822 known date" {
    const result = try dateToRfc822(std.testing.allocator, "2026-03-07");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Sat, 07 Mar 2026 00:00:00 +0000", result);
}

test "dateToRfc822 malformed falls back to raw" {
    const result = try dateToRfc822(std.testing.allocator, "not-a-date");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("not-a-date", result);
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

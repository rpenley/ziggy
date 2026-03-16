const std = @import("std");
const zmd = @import("zmd");
const types = @import("types.zig");
const cli = @import("cli.zig");
const parse = @import("parse.zig");
const render = @import("render.zig");
const generate = @import("generate.zig");

const Config = types.Config;
const max_content_bytes = types.max_content_bytes;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple arena that we will free later
    var config_arena = std.heap.ArenaAllocator.init(allocator);
    defer config_arena.deinit();
    const config_allocator = config_arena.allocator();

    var config = Config{
        .content_dir = "content",
        .template_dir = "templates/default",
        .publish_dir = "publish",
        .site_url = "",
        .clean = false,
        .site_vars = std.StringHashMap([]const u8).init(config_allocator),
    };
    try cli.loadZonConfig(config_allocator, &config);
    if (!try cli.parseArgs(config_allocator, &config)) return;

    if (config.clean) {
        std.fs.cwd().deleteTree(config.publish_dir) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try std.fs.File.stdout().writeAll("Cleaned   publish dir\n");
    }
    try std.fs.cwd().makePath(config.publish_dir);

    // Top-level content pages (files directly in content/).
    {
        var content_dir = try std.fs.cwd().openDir(config.content_dir, .{ .iterate = true });
        defer content_dir.close();

        var path_buf: [1024]u8 = undefined;
        var line_buf: [1200]u8 = undefined;
        var iterator = content_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const source = try content_dir.readFileAlloc(allocator, entry.name, max_content_bytes);
            defer allocator.free(source);

            var vars = std.StringHashMap([]const u8).init(allocator);
            defer vars.deinit();

            // Site vars first; front matter overrides on collision.
            var site_iter = config.site_vars.iterator();
            while (site_iter.next()) |kv| try vars.put(kv.key_ptr.*, kv.value_ptr.*);

            const stem = entry.name[0 .. entry.name.len - 3];
            const body_md = try parse.parseFrontMatter(source, &vars);
            const body_html = try zmd.parse(allocator, body_md, .{});
            defer allocator.free(body_html);

            try vars.put("content", body_html);

            const tmpl = try render.loadTemplate(allocator, &config, stem);
            defer allocator.free(tmpl);

            const output = try render.renderMustache(allocator, tmpl, &vars);
            defer allocator.free(output);

            const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.html", .{ config.publish_dir, stem });
            const out_file = try std.fs.cwd().createFile(out_path, .{});
            defer out_file.close();
            try out_file.writeAll(output);

            const line = try std.fmt.bufPrint(&line_buf, "Generated {s}\n", .{out_path});
            try std.fs.File.stdout().writeAll(line);
        }
    }

    // Content type subdirectories — one per subdirectory of content/.
    var content_types = try generate.discoverContentTypes(allocator, &config);
    defer {
        for (content_types.items) |ct| allocator.free(ct);
        content_types.deinit(allocator);
    }

    var tag_map = std.StringHashMap(std.ArrayList(types.ListItem)).init(allocator);
    defer {
        var tag_iter = tag_map.iterator();
        while (tag_iter.next()) |entry| {
            for (entry.value_ptr.items) |item| {
                allocator.free(item.title);
                allocator.free(item.date);
                allocator.free(item.description);
                allocator.free(item.slug);
                allocator.free(item.content_type);
                allocator.free(item.tags);
            }
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        tag_map.deinit();
    }

    for (content_types.items) |ct| {
        var type_pub_buf: [1024]u8 = undefined;
        const type_pub = try std.fmt.bufPrint(&type_pub_buf, "{s}/{s}", .{ config.publish_dir, ct });
        try std.fs.cwd().makePath(type_pub);

        var items = try generate.processContentType(allocator, &config, ct, &tag_map);
        defer {
            for (items.items) |item| {
                allocator.free(item.title);
                allocator.free(item.date);
                allocator.free(item.description);
                allocator.free(item.slug);
                allocator.free(item.content_type);
                allocator.free(item.tags);
            }
            items.deinit(allocator);
        }

        generate.sortItemsByDate(items.items);
        try generate.generateTypeIndex(allocator, &config, ct, items.items);
        try generate.generateRssFeed(allocator, &config, ct, items.items);
    }

    try generate.generateTagPages(allocator, &config, &tag_map);
    try generate.copyStaticFiles(allocator, &config);
}

// Pull in tests from sub-modules so `zig build test` discovers them.
test {
    _ = @import("parse.zig");
    _ = @import("render.zig");
    _ = @import("generate.zig");
    _ = @import("cli.zig");
}

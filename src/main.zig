const std = @import("std");
const types = @import("types.zig");
const cli = @import("cli.zig");
const parse = @import("parse.zig");
const render = @import("render.zig");
const generate = @import("generate.zig");

const Config = types.Config;
const max_content_bytes = types.max_content_bytes;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const io = init.io;

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
    try cli.loadZonConfig(config_allocator, io, init.environ_map.get("HOME"), &config);
    if (!try cli.parseArgs(config_allocator, io, init.minimal.args, &config)) return;

    if (config.clean) {
        std.Io.Dir.cwd().deleteTree(io, config.publish_dir) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try std.Io.File.stdout().writeStreamingAll(io, "Cleaned   publish dir\n");
    }
    try std.Io.Dir.cwd().createDirPath(io, config.publish_dir);

    // Top-level content pages (files directly in content/).
    {
        var content_dir = try std.Io.Dir.cwd().openDir(io, config.content_dir, .{ .iterate = true });
        defer content_dir.close(io);

        var path_buf: [1024]u8 = undefined;
        var line_buf: [1200]u8 = undefined;
        var iterator = content_dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const source = try content_dir.readFileAlloc(io, entry.name, allocator, .limited(max_content_bytes));
            defer allocator.free(source);

            var vars = std.StringHashMap([]const u8).init(allocator);
            defer vars.deinit();

            // Site vars first; front matter overrides on collision.
            var site_iter = config.site_vars.iterator();
            while (site_iter.next()) |kv| try vars.put(kv.key_ptr.*, kv.value_ptr.*);

            const stem = entry.name[0 .. entry.name.len - 3];
            const body_md = try parse.parseFrontMatter(source, &vars);
            const body_html = try parse.renderMarkdownFragment(allocator, body_md);
            defer allocator.free(body_html);

            try vars.put("content", body_html);

            const tmpl = try render.loadTemplate(allocator, io, &config, stem);
            defer allocator.free(tmpl);

            const output = try render.renderMustache(allocator, tmpl, &vars);
            defer allocator.free(output);

            const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.html", .{ config.publish_dir, stem });
            const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer out_file.close(io);
            try out_file.writeStreamingAll(io, output);

            const line = try std.fmt.bufPrint(&line_buf, "Generated {s}\n", .{out_path});
            try std.Io.File.stdout().writeStreamingAll(io, line);
        }
    }

    // Content type subdirectories — one per subdirectory of content/.
    var content_types = try generate.discoverContentTypes(allocator, io, &config);
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
        try std.Io.Dir.cwd().createDirPath(io, type_pub);

        var items = try generate.processContentType(allocator, io, &config, ct, &tag_map);
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
        try generate.generateTypeIndex(allocator, io, &config, ct, items.items);
        try generate.generateRssFeed(allocator, io, &config, ct, items.items);
    }

    try generate.generateTagPages(allocator, io, &config, &tag_map);
    try generate.copyStaticFiles(allocator, io, &config);
}

// Pull in tests from sub-modules so `zig build test` discovers them.
test {
    _ = @import("parse.zig");
    _ = @import("render.zig");
    _ = @import("generate.zig");
    _ = @import("cli.zig");
}

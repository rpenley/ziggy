const std = @import("std");
const types = @import("types.zig");

const Config = types.Config;
const max_content_bytes = types.max_content_bytes;

/// Substitutes `{{ key }}` tags in `template` with values from `vars`.
/// Unrecognised keys are replaced with an empty string.
pub fn renderMustache(
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

/// Expands `{{> partial_name }}` tags by loading
/// `{template_dir}/partials/{name}.mustache` and inlining its content.
/// Missing partials are silently replaced with an empty string.
/// Does not recurse — partials may not themselves contain partial tags.
pub fn expandPartials(
    allocator: std.mem.Allocator,
    config: *const Config,
    template: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < template.len) {
        const open = std.mem.indexOf(u8, template[pos..], "{{") orelse {
            try out.appendSlice(allocator, template[pos..]);
            break;
        };

        const tag_start = pos + open + 2;

        // Check if this is a partial tag (next char after {{ is '>').
        if (tag_start >= template.len or template[tag_start] != '>') {
            // Not a partial — copy up to and including {{ and advance past it.
            try out.appendSlice(allocator, template[pos..tag_start]);
            pos = tag_start;
            continue;
        }

        // Copy everything before {{.
        try out.appendSlice(allocator, template[pos .. pos + open]);

        const close = std.mem.indexOf(u8, template[tag_start..], "}}") orelse {
            // Unclosed tag — copy as-is and stop.
            try out.appendSlice(allocator, template[pos + open ..]);
            break;
        };

        const name = std.mem.trim(u8, template[tag_start + 1 .. tag_start + close], " \t");

        var partial_buf: [1024]u8 = undefined;
        const partial_path = try std.fmt.bufPrint(&partial_buf, "{s}/partials/{s}.mustache", .{
            config.template_dir, name,
        });

        if (std.fs.cwd().readFileAlloc(allocator, partial_path, max_content_bytes)) |partial_content| {
            defer allocator.free(partial_content);
            try out.appendSlice(allocator, partial_content);
        } else |_| {
            // Missing partial → empty (consistent with missing-key behavior in renderMustache).
        }

        pos = tag_start + close + 2;
    }

    return out.toOwnedSlice(allocator);
}

/// Tries {template_dir}/{stem}.mustache, then {template_dir}/default.mustache.
/// Partials (`{{> name }}`) are expanded before returning.
pub fn loadTemplate(allocator: std.mem.Allocator, config: *const Config, stem: []const u8) ![]const u8 {
    var path_buf: [1024]u8 = undefined;

    const raw = blk: {
        const specific = try std.fmt.bufPrint(&path_buf, "{s}/{s}.mustache", .{ config.template_dir, stem });
        if (std.fs.cwd().readFileAlloc(allocator, specific, max_content_bytes)) |content| {
            break :blk content;
        } else |_| {}

        const fallback = try std.fmt.bufPrint(&path_buf, "{s}/default.mustache", .{config.template_dir});
        break :blk try std.fs.cwd().readFileAlloc(allocator, fallback, max_content_bytes);
    };
    defer allocator.free(raw);

    return expandPartials(allocator, config, raw);
}

/// Loads `{template_dir}/partials/{name}.mustache`.
/// Returns error.FileNotFound if it doesn't exist.
pub fn loadPartial(allocator: std.mem.Allocator, config: *const Config, name: []const u8) ![]const u8 {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/partials/{s}.mustache", .{
        config.template_dir, name,
    });
    return std.fs.cwd().readFileAlloc(allocator, path, max_content_bytes);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "renderMustache single tag" {
    const allocator = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    try vars.put("name", "World");
    const result = try renderMustache(allocator, "Hello, {{ name }}!", &vars);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "renderMustache multiple tags" {
    const allocator = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    try vars.put("title", "T");
    try vars.put("body", "B");
    const result = try renderMustache(allocator, "<t>{{ title }}</t>{{ body }}", &vars);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<t>T</t>B", result);
}

test "renderMustache missing key yields empty" {
    const allocator = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    const result = try renderMustache(allocator, "A{{ x }}B", &vars);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AB", result);
}

test "renderMustache no tags pass-through" {
    const allocator = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    const result = try renderMustache(allocator, "plain text", &vars);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "renderMustache whitespace in tag" {
    const allocator = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    try vars.put("name", "trimmed");
    const result = try renderMustache(allocator, "{{  name  }}", &vars);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("trimmed", result);
}

test "renderMustache unclosed {{ preserved" {
    const allocator = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    const result = try renderMustache(allocator, "a{{ b", &vars);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a{{ b", result);
}

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const template = try std.fs.cwd().readFileAlloc(
        allocator,
        "template/default.mustache",
        1 * 1024 * 1024,
    );
    defer allocator.free(template);

    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        "content/landing.md",
        1 * 1024 * 1024,
    );
    defer allocator.free(source);

    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();

    // Slices in vars point into `source` (no alloc), except body_html below.
    const body_md = try parseFrontMatter(source, &vars);

    const body_html = try markdownToHtml(allocator, body_md);
    defer allocator.free(body_html);

    try vars.put("content", body_html);

    const output = try renderMustache(allocator, template, &vars);
    defer allocator.free(output);

    try std.fs.cwd().makePath("publish");

    const out_file = try std.fs.cwd().createFile("publish/index.html", .{});
    defer out_file.close();
    try out_file.writeAll(output);

    std.debug.print("Generated publish/index.html\n", .{});
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
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 2 ..], " \t");
        if (key.len > 0) try vars.put(key, value);
    }

    // Skip past the closing "\n---\n" (5 bytes).
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
            // Unclosed tag — emit literally and stop.
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

/// Converts a subset of Markdown to HTML:
///   - ATX headings (`#` through `######`)
///   - `**bold**` and `*italic*` inline spans
///   - Implicit paragraphs (blank-line-delimited blocks)
fn markdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var in_paragraph = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) {
            if (in_paragraph) {
                try out.appendSlice(allocator, "</p>\n");
                in_paragraph = false;
            }
            continue;
        }

        // ATX heading: one to six `#` chars followed by a space.
        const hashes = countLeading(trimmed, '#');
        if (hashes >= 1 and hashes <= 6 and
            trimmed.len > hashes and trimmed[hashes] == ' ')
        {
            if (in_paragraph) {
                try out.appendSlice(allocator, "</p>\n");
                in_paragraph = false;
            }
            try out.writer(allocator).print("<h{d}>", .{hashes});
            try appendInline(&out, allocator, trimmed[hashes + 1 ..]);
            try out.writer(allocator).print("</h{d}>\n", .{hashes});
            continue;
        }

        // Everything else is a paragraph line.
        if (!in_paragraph) {
            try out.appendSlice(allocator, "<p>");
            in_paragraph = true;
        } else {
            try out.append(allocator, ' ');
        }
        try appendInline(&out, allocator, trimmed);
    }

    if (in_paragraph) try out.appendSlice(allocator, "</p>\n");

    return out.toOwnedSlice(allocator);
}

fn countLeading(text: []const u8, char: u8) usize {
    var n: usize = 0;
    while (n < text.len and text[n] == char) n += 1;
    return n;
}

/// Writes `text` to `out`, converting `**bold**` and `*italic*` to HTML.
fn appendInline(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Bold: **...**  (must check before single-star italic)
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const inner = i + 2;
            if (std.mem.indexOf(u8, text[inner..], "**")) |end| {
                try out.appendSlice(allocator, "<strong>");
                try out.appendSlice(allocator, text[inner .. inner + end]);
                try out.appendSlice(allocator, "</strong>");
                i = inner + end + 2;
                continue;
            }
        }
        // Italic: *...*
        if (text[i] == '*') {
            const inner = i + 1;
            if (std.mem.indexOf(u8, text[inner..], "*")) |end| {
                try out.appendSlice(allocator, "<em>");
                try out.appendSlice(allocator, text[inner .. inner + end]);
                try out.appendSlice(allocator, "</em>");
                i = inner + end + 1;
                continue;
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
}

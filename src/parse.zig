const std = @import("std");

/// Strips YAML front matter (between leading `---` fences) from `source`,
/// populates `vars` with the key/value pairs, and returns the markdown body.
/// All returned slices are views into `source` — no allocation.
pub fn parseFrontMatter(source: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
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

	return rest[close_off + "\n---\n".len ..];
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseFrontMatter basic key/value" {
	const allocator = std.testing.allocator;
	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	const body = try parseFrontMatter("---\ntitle: Hello\ndate: 2024-01-01\n---\nbody", &vars);
	try std.testing.expectEqualStrings("Hello", vars.get("title").?);
	try std.testing.expectEqualStrings("2024-01-01", vars.get("date").?);
	try std.testing.expectEqualStrings("body", body);
}

test "parseFrontMatter no front matter" {
	const allocator = std.testing.allocator;
	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	const input = "plain text";
	const body = try parseFrontMatter(input, &vars);
	try std.testing.expectEqualStrings(input, body);
	try std.testing.expectEqual(@as(usize, 0), vars.count());
}

test "parseFrontMatter empty body" {
	const allocator = std.testing.allocator;
	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	const body = try parseFrontMatter("---\ntitle: T\n---\n", &vars);
	try std.testing.expectEqualStrings("T", vars.get("title").?);
	try std.testing.expectEqualStrings("", body);
}

test "parseFrontMatter value whitespace trimmed" {
	const allocator = std.testing.allocator;
	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	_ = try parseFrontMatter("---\ntitle:   Padded  \n---\n", &vars);
	try std.testing.expectEqualStrings("Padded", vars.get("title").?);
}

test "parseFrontMatter malformed lines skipped" {
	const allocator = std.testing.allocator;
	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	_ = try parseFrontMatter("---\nbadline\ntitle: Good\n---\n", &vars);
	try std.testing.expectEqualStrings("Good", vars.get("title").?);
	try std.testing.expectEqual(@as(usize, 1), vars.count());
}

test "parseFrontMatter unclosed fence" {
	const allocator = std.testing.allocator;
	var vars = std.StringHashMap([]const u8).init(allocator);
	defer vars.deinit();
	const input = "---\ntitle: Nope\nno close";
	const body = try parseFrontMatter(input, &vars);
	try std.testing.expectEqualStrings(input, body);
	try std.testing.expectEqual(@as(usize, 0), vars.count());
}

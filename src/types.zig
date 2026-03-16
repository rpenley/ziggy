const std = @import("std");

pub const max_content_bytes: usize = 1 * 1024 * 1024;
pub const max_static_bytes:  usize = 4 * 1024 * 1024;
pub const max_config_bytes:  usize = 64 * 1024;

pub const Config = struct {
	content_dir:  []const u8,
	template_dir: []const u8,
	static_dir:   []const u8,
	publish_dir:  []const u8,
	theme:        []const u8,
	clean:        bool,
	site_vars:    std.StringHashMap([]const u8),
};

pub const ListItem = struct {
	title:       []const u8,
	date:        []const u8,
	description: []const u8,
	slug:        []const u8,
};

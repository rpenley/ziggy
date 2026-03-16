---
title: Blog Post Example
date: 2026-03-07
description: Your First Post
tags: zig, tutorial, markdown
---

# Markdown Basics

Ziggy uses the [zmd library](https://github.com/jetzig-framework/zmd) part of the wonderful [jetzig web framework](https://www.jetzig.dev/) to parse markdown for us. This allows you to write your blog posts in markdown with support for all the features you would expect such as...

## Emphasis

This is **bold text** and this is *italic text*.
You can also combine them: ***bold and italic***.

## Links

Inline links: [Zig language](https://ziglang.org)

## Lists

Unordered:

- apples
- bananas
- oranges

Ordered:

1. first
2. second
3. third

## Blockquote

> This is a blockquote. Useful for callouts or pulled quotes.

## Code

Inline `code` looks like this.

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("hello, world\n", .{});
}
```


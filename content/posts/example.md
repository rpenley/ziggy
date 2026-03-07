---
title: Example
date: 2026-03-07
description: The first post
---

# Markdown Basics

Ziggy uses the [zmd library](https://https://github.com/jetzig-framework/zmd) part of the wonderful [jetzig web framework](https://www.jetzig.dev/) to render markdown into html. It supports all the things you expect such as...

## Emphasis

This is **bold text** and this is *italic text*.
You can also combine them: ***bold and italic***.

## Links

Inline link: [Zig language](https://ziglang.org)

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

A fenced code block:

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("hello, world\n", .{});
}
```


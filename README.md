# Ziggy
Ziggy is a static site generator (SSG) written in zig using Mustache templates and Markdown to generate pure static HTML websites.

### How to Build
Building ziggy is as simple as running zig build which produces a single static binary.

Ziggy uses the [zmd library](https://https://github.com/jetzig-framework/zmd) part of the wonderful [jetzig web framework](https://www.jetzig.dev/) to parse markdown.

## How to Use
By default Ziggy will look for and generate its primary input and output folders in the same directory as it is executed unless flags are passed, use `ziggy --help` to see what flags are supported

## Structure
`./template` is where you store your mustache templates. `./template/default` will be used for pages that cannot be matched to a template
`./content` is the markdown content of your site with yaml front matter to configure page metadata
`./publish` is the default output folder where ziggy will generate your website and root index

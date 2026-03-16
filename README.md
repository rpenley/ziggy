# Ziggy
Ziggy is a static site generator (SSG) written in Zig using Mustache templates and Markdown to produce pure static HTML websites.

## Build

```sh
zig build          # compile
zig build run      # compile and run
```

Produces a single static binary at `zig-out/bin/ziggy`.

Ziggy uses the [zmd library](https://github.com/jetzig-framework/zmd) part of the [jetzig web framework](https://www.jetzig.dev/) to parse Markdown.

The default template uses icons from [Lucide](https://lucide.dev), licensed under the [ISC License](https://github.com/lucide-icons/lucide/blob/main/LICENSE).

## Directory Structure

```
content/          # Markdown source files with YAML front matter
templates/        # One subdirectory per template (e.g. templates/default)
publish/          # Generated HTML/CSS output
```

Each template folder (e.g. `templates/default`) contains:
- Mustache templates (`.mustache` files)
- `partials/` — partial templates included via `{{> name }}`
- Static assets (CSS, JS, images) — copied as-is to `publish/`

## Templates

Templates are selected by folder name under `templates/`. The `default` template is used when none is specified. To use a different template, pass `--template <name>` or set `template = "<name>"` in `ziggy.zon`.

Ziggy looks for `{stem}.mustache` matching the content file name, falling back to `default.mustache` if none is found.

## Configuration

Ziggy loads `ziggy.zon` from the current directory, then `~/ziggy.zon`. CLI flags override config file values. Unknown keys become site-wide template variables available in all mustache templates.

```zig
.{
    .content_dir = "content",
    .template    = "default",
    .publish_dir = "publish",
    .site_url    = "https://example.com",
    .site_title  = "My Site",
    .site_author = "Your Name",
}
```

Run `ziggy --help` for all available flags.

## Front Matter

Each Markdown file may include a YAML front matter block. Recognized fields:

| Field         | Format                        | Description                        |
|---------------|-------------------------------|------------------------------------|
| `title`       | string                        | Page title                         |
| `date`        | YYYY-MM-DD                    | Publication date                   |
| `description` | string                        | Short description (used in `<meta>`)|
| `tags`        | comma-separated string        | Tags (e.g. `zig, tutorial`)        |

All fields are optional. Missing fields render as empty string.

## Template Variables

Inside any `.mustache` file the following variables are available:

- All `ziggy.zon` site keys (e.g. `{{ site_title }}`, `{{ site_author }}`, `{{ site_url }}`)
- Front matter fields from the current page: `{{ title }}`, `{{ date }}`, `{{ description }}`, `{{ tags }}`
- `{{ content }}` — rendered HTML body of the Markdown file
- `{{ tags_html }}` — pre-rendered tag links (available on content-type posts only)

## Content Types

Each subdirectory of `content/` is a **content type** (e.g. `content/blog/` → type `blog`).

For each post Ziggy looks for `{type}-post.mustache` in the template dir, falling back to
`default.mustache`. For the index page it looks for `{type}-index.mustache`, falling back
to `default.mustache`.

Output paths:
- `publish/{type}.html` — index page listing all posts of that type
- `publish/{type}/{slug}.html` — individual post (slug derived from filename)

## Tags

The `tags` front matter field (comma-separated) builds tag pages. Each unique tag gets
`publish/tag/{tag}.html` listing all posts with that tag. The `{{ tags_html }}` variable
contains pre-rendered links pointing to these pages.

## RSS

Each content type gets an RSS 2.0 feed at `publish/{type}.xml`. Set `site_url` in
`ziggy.zon` so item links resolve correctly.

## Partials

Use `{{> name }}` in a template to include `{template_dir}/partials/{name}.mustache`.
Partials do not recurse — a partial cannot itself include another partial. The `partials/`
subdirectory is not copied to `publish/`.

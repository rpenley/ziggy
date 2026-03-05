# Ziggy
Ziggy is a static site generator (SSG) written in zig using mustache templates and Markdown to generate pure static HTML and CSS blogs

### How to Build
Building ziggy is as simple as running zig build which produces a single static binary

## How to Use
By default Ziggy will look for and generate its primary input and output folders in the same directory as it is executed unless flags are otherwise passed, use ziggy --help to see what flags are supported

./template # provides the mustache templates for various pages, ./template/default will be used for pages that cannot be matched to a template
./content # markdown content of your site with yaml front matter
./publish # output of ziggy generated content

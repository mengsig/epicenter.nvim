# epicenter.nvim

Your code graph, live in the editor.

epicenter.nvim puts [NavGraph](https://github.com/mengsig/NavGraph) — a fast,
dependency-free code-graph engine — behind a Neovim UI. Ask what a symbol is,
who calls it, and what breaks if you change it, and get the answer while you
type. No daemon to babysit, no index to rebuild by hand, no language servers
required for the graph itself.

epicenter.nvim ships the **search palette** (fuzzy symbol search and repo-wide
grep) and **blast radius** (a live impact panel with ripples in the code, a
hover card of callers, fan-in/fan-out badges, and diff impact against a git
ref) — all live on every keystroke, all including your unsaved edits. On top
of it come the exploration panels: callers and callees as a tree that fetches
a level at a time, the call path between two symbols, a live outline sidebar,
fan-in hot spots, unused symbols, a graph export, and the status dashboard.

```
 >  handle_request                                  ┌──────────────────────────┐
 ────────────────────────────────────────────       │ function M.handle_reques │
  󰆧 M.handle_request   app/server.lua:9   3         │   log_request(method, pa │
  󰆧 RequestHandler.handle_request  api.py:2   3     │   return config.route(me │
  󰊕 log_request        app/server.lua:5   1         │ end                      │
```

## Install

Needs Neovim 0.10+ and the `navgraph` binary (`:Epicenter install` fetches or
builds it for you). 0.11+ additionally gets an `lsp/navgraph.lua` definition,
so `vim.lsp.enable("navgraph")` works without this plugin's own start path.

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{
  "mengsig/epicenter.nvim",
  build = function()
    require("epicenter").install({ wait = true })
  end,
  opts = {},
}
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**

```lua
use({
  "mengsig/epicenter.nvim",
  run = function()
    require("epicenter").install({ wait = true })
  end,
  config = function()
    require("epicenter").setup({})
  end,
})
```

**built-in `vim.pack`** (Neovim 0.12+)

```lua
vim.pack.add({ "https://github.com/mengsig/epicenter.nvim" })
require("epicenter").setup({})
```

Then `:Epicenter install` once, and `:checkhealth epicenter` to confirm.

Calling `setup()` is optional — the defaults apply on their own. Call it to
change them.

## Keymaps

One prefix, `<leader>e` by default (`keymaps = false` installs none).

<!-- registry:keymaps -->
| Key          | Command              | Does                                       |
| ------------ | -------------------- | ------------------------------------------ |
| `<leader>es` | `:Epicenter search`  | Fuzzy symbol search across the project     |
| `<leader>eg` | `:Epicenter grep`    | Repo-wide text search, unsaved edits too   |
| `<leader>ee` | `:Epicenter blast`   | Blast radius of the symbol at the cursor   |
| `<leader>ek` | `:Epicenter hover`   | What this symbol is, and who calls it      |
| `<leader>ed` | `:Epicenter diff`    | Impact of the changes since a git ref      |
| `<leader>ec` | `:Epicenter callers` | Who calls the symbol under the cursor      |
| `<leader>eC` | `:Epicenter callees` | What the symbol under the cursor calls     |
| `<leader>ep` | `:Epicenter path`    | Call chain between two symbols             |
| `<leader>eo` | `:Epicenter outline` | Live symbol outline of the current buffer  |
| `<leader>eh` | `:Epicenter hot`     | Most depended-on symbols, ranked by fan-in |
| `<leader>ex` | `:Epicenter status`  | Dashboard: index, server, languages, log   |
<!-- /registry:keymaps -->

Inside the palette:

| Key                | Does                                          |
| ------------------ | --------------------------------------------- |
| `<CR>`             | Jump to the result (pushes the jumplist)      |
| `<C-t>`/`<C-v>`/`<C-x>` | Open in a tab / vertical split / split   |
| `<C-n>`/`<C-p>`    | Next / previous result                        |
| `<C-r>`            | Toggle reference mode (grep: regex)           |
| `<C-k>`            | Cycle the kind filter (search only)           |
| `<C-y>`            | Yank `file:line`                              |
| `?`                | Toggle the key help (normal mode)             |
| `<Esc>` / `q`      | Close                                         |

## Commands

`:Epicenter <subcommand>`, with completion.

<!-- registry:commands -->
| Subcommand | Does                                       |
| ---------- | ------------------------------------------ |
| `search`   | Fuzzy symbol search across the project     |
| `grep`     | Repo-wide text search, unsaved edits too   |
| `blast`    | Blast radius of the symbol at the cursor   |
| `hover`    | What this symbol is, and who calls it      |
| `diff`     | Impact of the changes since a git ref      |
| `callers`  | Who calls the symbol under the cursor      |
| `callees`  | What the symbol under the cursor calls     |
| `path`     | Call chain between two symbols             |
| `outline`  | Live symbol outline of the current buffer  |
| `hot`      | Most depended-on symbols, ranked by fan-in |
| `unused`   | Symbols nothing in the index reaches       |
| `graph`    | Write the call graph to a file and open it |
| `status`   | Dashboard: index, server, languages, log   |
| `install`  | Download or build the navgraph binary      |
| `restart`  | Restart the server for this project        |
| `rescan`   | Re-stat every file and rebuild the index   |
| `log`      | Open the epicenter log                     |
<!-- /registry:commands -->

Every subcommand ships today; none are pending.

### Inside the blast panel

| Key            | Does                                                     |
| -------------- | -------------------------------------------------------- |
| `<CR>`         | Jump to the symbol (panel stays open - it's a live query)|
| `<C-v>` / `<C-t>` | Open in a vertical split / a new tab                  |
| `o`            | Toggle a peek at it without leaving the panel             |
| `y`            | Yank `file:line`                                         |
| `+` / `-`      | Deeper / shallower (re-queries)                          |
| `d`            | Flip callers ↔ callees                                   |
| `t`            | Cycle the tests scope (with → without → only)            |
| `s`            | Toggle strict resolution (drops heuristic edges)         |
| `f`            | Follow the cursor                                        |
| `j`/`k`/`gg`/`G` | Move                                                   |
| `/`            | Filter by name                                            |
| `?`            | Toggle the key help                                      |
| `q` / `<Esc>`  | Close                                                    |

The hover card does not take focus; press `<leader>ek` again (or `K`) to step
into it, then `j`/`k` through the callers and `<CR>` to jump. On a buffer where
navgraph is the hover provider — which under `lsp.fallback_only` means no
other language server offers one — `K` opens the card too.

`:Epicenter diff [ref]` reuses the panel with every changed symbol as a root
(`changes vs HEAD` in the header). Your open buffers reach navgraph as
overlays, so an unsaved edit is already in the answer.

`badges` puts a definition's fan-in and fan-out at the end of its line as muted
virtual text — `"cursor"` for the definition you are inside, `"all"` for every
definition in the buffer, `false` for none.

### Inside the callers/callees tree

(and every other results panel - outline, hot, unused - which share the same
`j`/`k`/`gg`/`G`/`<CR>`/`o`/`y`/`/`/`?`/`q` keys)

| Key                     | Does                                           |
| ----------------------- | ----------------------------------------------- |
| `j` / `k` / `gg` / `G`  | Move                                           |
| `l` / `h`               | Expand (fetching that level) / collapse        |
| `<CR>`                  | Jump to the symbol                             |
| `<C-v>` / `<C-t>`       | Open in a vertical split / a new tab           |
| `o`                     | Peek at the definition without leaving the panel |
| `y`                     | Yank `file:line`                               |
| `r`                     | Toggle reference edges                         |
| `s`                     | Strict mode - drop the `?` (heuristic) edges   |
| `t`                     | Cycle the test scope: with / without / only    |
| `<C-k>`                 | Outline: cycle the kind filter                 |
| `b`                     | Hot: buffer / repo scope                       |
| `p`                     | Unused: hide the public symbols                |
| `/`                     | Filter by name                                 |
| `?`                     | Toggle the key help (normal mode)              |
| `q` / `<Esc>`           | Close                                          |

## Configuration

Defaults in full:

<!-- registry:config -->
```lua
require("epicenter").setup({
  animate = true,                           -- master switch; vim.g.epicenter_reduce_motion wins
  animation = {
    close_ms = 90,
    fps = 60,
    frame_budget_ms = 8,                    -- a frame costing more than this drops the next one
    open_ms = 120,
    stagger_ms = 8,
  },
  badges = "cursor",                        -- "cursor" | "all" | false
  blast = {
    depth = 2,                              -- rings requested
    direction = "callers",                  -- "callers" | "callees"
    follow_debounce_ms = 80,
    layout = "float",                       -- "float" | "vsplit"
    max_depth = 6,                          -- upper bound for `+` in the panel
    realtime_debounce_ms = 150,
    strict = false,                         -- drop name-resolved (heuristic) edges
    tests = "with",                         -- "with" | "without" | "only"
  },
  explore = { debounce_ms = 100 },          -- quiet time after a reindex before rows refetch
  grep = { debounce_ms = 60, limit = 200 },
  highlights = {},                          -- e.g. { EpicenterAccent = { fg = "#7aa2f7" } }
  hot = { bar_width = 12, limit = 30 },
  hover = { callers = 5, max_width = 80 },
  keymaps = { prefix = "<leader>e" },       -- or false, to install none
  log = { file = nil, level = "warn" },     -- file defaults to stdpath("state")/epicenter.log
  lsp = {
    auto_start = true,
    fallback_only = true,                   -- yield definition/references/hover to another server
    init_options = {                        -- passed verbatim as LSP initializationOptions
      debounceMs = 120,
      depth = 3,
      strict = false,
      tests = "with",                       -- "with" | "without" | "only"
      watch = true,
      watchIntervalMs = 2000,
    },
    restart = { backoff_ms = { 500, 2000, 5000 }, max = 3 },
    root_markers = { ".navgraph", ".git" }, -- checked in order at each level, walking upward
  },
  navgraph = {
    args = {},                              -- extra arguments appended to `navgraph lsp`
    install_ref = nil,                      -- git ref to build from, on the source route
    path = nil,                             -- explicit path; else $PATH, then the managed install
    repo = "mengsig/NavGraph",              -- source for :Epicenter install
  },
  outline = { debounce_ms = 80, width = 34 },
  path = { step_ms = 45 },                  -- time each rung of the path ladder takes to draw
  ripples = true,                           -- mark the impacted lines while a panel is open
  search = { debounce_ms = 40, limit = 50 },
  ui = {
    border = "rounded",
    height = 0.8,                           -- fraction of the editor when <= 1, else cells
    icons = "auto",                         -- "auto" | "nerd" | "ascii"
    max_height = 30,
    max_width = 120,
    preview = true,
    width = 0.8,                            -- fraction of the editor when <= 1, else cells
    winblend = 0,
  },
  unused = { limit = 200 },
})
```
<!-- /registry:config -->

Unknown keys and wrong types are errors at `setup()` time, naming the exact
option — a typo never silently does nothing.

### Colours

Highlight groups are derived at runtime from your colourscheme (`Normal`,
`NormalFloat`, `FloatBorder`, `Comment`, `Title`, `Function`, `Special`,
`DiagnosticInfo`) and re-derived on `ColorScheme`. One accent, monochrome text
hierarchy. Every group is overridable through `highlights`:
`EpicenterNormal`, `EpicenterBorder`, `EpicenterTitle`, `EpicenterAccent`,
`EpicenterMatch`, `EpicenterMuted`, `EpicenterCount`, `EpicenterInfo`,
`EpicenterSelection`, `EpicenterPrompt`, `EpicenterHint`, `EpicenterRange`.

The blast panel adds `EpicenterRipple1`, `EpicenterRipple2` and
`EpicenterRipple3` — the ring grades of the inline marks, derived from the
accent over the *editor* background rather than the float background.

## How it relates to NavGraph

NavGraph is the engine: a single static Zig binary that lexes and indexes a
repo, extracts definitions and their in-body references, and resolves a call
graph across files and languages. Its CLI answers the same questions from a
terminal.

epicenter.nvim runs `navgraph lsp`, which speaks LSP over stdio — the standard
subset (`definition`, `references`, `hover`, `documentSymbol`,
`workspace/symbol`) plus custom `navgraph/*` methods for the graph queries.
One server per workspace root. Your open buffers are sent as overlays, so
answers include edits you have not saved yet. Match highlight indices in
`navgraph/search` are 0-based byte offsets into the symbol's qualified name.

With `lsp.fallback_only` (the default), navgraph's standard providers are
hidden on buffers that already have a real language server, so `gd`, `gr` and
`K` never return duplicates — and still work in the many files no language
server covers.

## Why it feels instant

Every server call is asynchronous and cancellable, and each keystroke's
request is tagged: when a newer query is issued, an older answer - however
it arrives, even synchronously - is dropped rather than painted, so results
never flicker backwards to a query you have already replaced. Requests are
debounced (40ms for search) so a fast typist issues a handful of queries,
not one per character.

The one blocking read on the UI path is the preview's file slice, capped at
20,000 lines scanned and 400 lines shown - past that it says so instead of
freezing. `:checkhealth`'s binary version check blocks too (a user-invoked
report, `:wait(3000)` at worst).

Motion is cheap and interruptible: one `vim.uv` timer per animation, geometry
interpolated over 120ms, and a frame that costs more than 8ms drops the next
one instead of queueing behind it. A resize reflows in place — it never
animates. `animate = false` or `vim.g.epicenter_reduce_motion = true` turns all
of it off, and every widget lands on exactly the same final state.

## Extending

Adding a feature is one new file plus one line.

1. Write `lua/epicenter/features/<name>.lua` returning a feature spec:

   ```lua
   local M = {}
   M.name = "blast"
   M.summary = "Blast radius of the symbol under the cursor"
   M.options = { blast = { depth = 3 } }   -- merged into the config defaults
   M.commands = {
     { name = "blast", desc = "Blast radius", run = function(ctx) end },
   }
   M.keymaps = { { suffix = "b", command = "blast", desc = "Epicenter: blast" } }
   return M
   ```

2. Add one `require` line to `lua/epicenter/features/init.lua`.

A feature validates its own options with `option_rules` (`variants` for the
types a path accepts, `enums` for its values, `positive` for numbers that must
be > 0), and can watch the session with `setup = function(cfg) ... end`, which
runs at the end of `setup()` and must be idempotent.

`lua/epicenter/registry.lua` collects the specs, and `plugin/epicenter.lua`,
`:Epicenter` completion, the keymap installer, `:checkhealth` and the config
defaults all iterate it — nothing else needs editing. Two features claiming the
same subcommand or option key is a hard error, never a silent override.

Feature modules must not `require("epicenter.config")` at file scope: config
builds its defaults from the registry, so that would be a cycle. Require it
inside `run`.

The UI kit is the public contract for features:
`ui/window`, `ui/animate`, `ui/easing`, `ui/theme`, `ui/icons`, `ui/list`,
`ui/tree`, `ui/prompt`, `ui/preview`, `ui/toast`, `ui/palette`, `ui/panel`.
`ui/palette` is the prompt+list+preview widget; `ui/panel` is the float that
carries a list or a tree plus the shared jump/peek/yank keys.
Server access goes through `epicenter.client`, which already has a helper for
every `navgraph/*` method.

## Development

```sh
make test        # headless suite, against the fake server
make test-real   # the same features against a real `navgraph lsp` binary
make smoke       # drives the real palette in a real Neovim and asserts the result
make lint        # stylua --check + luacheck
make fmt         # stylua
make docs-check  # README/vimdoc still match the registry
make docs-fix    # regenerate them
```

Tests run against `tests/fake_navgraph.lua`, a fake server that speaks the same
protocol over stdio against `tests/fixtures/proj` — so the suite needs no `zig`
and no network. Its handlers are registered per area under `tests/fake/`; a new
area is one new file there.

`make test-real` runs `tests/real/` against the real binary over
`tests/fixtures/real`, a small multi-language tree. Set `NAVGRAPH_BIN` when the
`navgraph` on `$PATH` is not the one you mean to test. Both lanes enforce
`tests/contract/schema.lua`, the editor protocol as data: a request carrying a
param the contract does not name is refused, and a response missing a promised
field fails.

The keymap table, the command table and the config reference above are
**generated** from `lua/epicenter/registry.lua` — the regions between the
`<!-- registry:… -->` markers here and the `*epicenter-…-table*` tags in
`doc/epicenter.txt` are written by `make docs-fix`, and CI fails if they drift.
Edit the feature spec, not the table.

## Licence

MIT © Marcus Engsig

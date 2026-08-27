# epicenter.nvim

Your code graph, live in the editor.

epicenter.nvim puts [NavGraph](https://github.com/mengsig/NavGraph) — a fast,
dependency-free code-graph engine — behind a Neovim UI. Ask what a symbol is,
who calls it, and what breaks if you change it, and get the answer while you
type. No daemon to babysit, no index to rebuild by hand, no language servers
required for the graph itself.

This release ships the foundation and the **search palette**: fuzzy symbol
search and repo-wide grep, both live on every keystroke, both including your
unsaved edits.

```
 >  handle_request                                  ┌──────────────────────────┐
 ────────────────────────────────────────────       │ function M.handle_reques │
  󰆧 M.handle_request   app/server.lua:9   3         │   log_request(method, pa │
  󰆧 RequestHandler.handle_request  api.py:2   3     │   return config.route(me │
  󰊕 log_request        app/server.lua:5   1         │ end                      │
```

## Install

Needs Neovim 0.11+ and the `navgraph` binary (`:Epicenter install` fetches or
builds it for you).

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

| Key          | Command              | Does                                          |
| ------------ | -------------------- | --------------------------------------------- |
| `<leader>es` | `:Epicenter search`  | Fuzzy symbol search across the project        |
| `<leader>eg` | `:Epicenter grep`    | Repo-wide text search, unsaved edits included  |

Inside the palette:

| Key                | Does                                          |
| ------------------ | --------------------------------------------- |
| `<CR>`             | Jump to the result (pushes the jumplist)      |
| `<C-t>`/`<C-v>`/`<C-x>` | Open in a tab / vertical split / split   |
| `<C-n>`/`<C-p>`    | Next / previous result                        |
| `<C-r>`            | Toggle reference mode (grep: regex)           |
| `<C-k>`            | Cycle the kind filter                         |
| `<C-y>`            | Yank `file:line`                              |
| `?`                | Toggle the key help (normal mode)             |
| `<Esc>` / `q`      | Close                                         |

## Commands

`:Epicenter <subcommand>`, with completion.

| Subcommand | Does                                                     |
| ---------- | -------------------------------------------------------- |
| `search`   | Symbol search palette                                    |
| `grep`     | Text search palette                                      |
| `status`   | What the index knows about this project                  |
| `install`  | Download or build the `navgraph` binary                  |
| `restart`  | Restart the server for this project                      |
| `rescan`   | Re-stat every file and rebuild the index (`rescan full`) |
| `log`      | Open the epicenter log                                   |

`blast`, `callers`, `callees`, `outline`, `hot`, `diff` and `path` complete
today and announce themselves as coming in this release.

## Configuration

Defaults in full:

```lua
require("epicenter").setup({
  navgraph = {
    path = nil,               -- explicit binary path; otherwise $PATH, then the managed install
    args = {},                -- extra arguments appended to `navgraph lsp`
    repo = "mengsig/NavGraph", -- source for :Epicenter install
    install_ref = nil,        -- git ref to build from, when building from source
  },
  lsp = {
    auto_start = true,
    root_markers = { ".navgraph", ".git" },
    fallback_only = true,     -- hide navgraph's definition/references/hover/documentSymbol
                              -- on buffers that already have another language server
    init_options = {
      tests = "with",         -- "with" | "without" | "only"
      strict = false,
      debounceMs = 120,
      watch = true,
      watchIntervalMs = 2000,
      depth = 3,
    },
    restart = { max = 3, backoff_ms = { 500, 2000, 5000 } },
  },
  ui = {
    border = "rounded",
    width = 0.8,              -- fraction of the editor when <= 1, absolute cells when > 1
    height = 0.8,
    max_width = 120,
    max_height = 30,
    winblend = 0,
    icons = "auto",           -- "auto" | "nerd" | "ascii"
    preview = true,
  },
  animate = true,             -- vim.g.epicenter_reduce_motion = true also disables motion
  animation = {
    open_ms = 120,
    close_ms = 90,
    stagger_ms = 8,
    fps = 60,
    frame_budget_ms = 8,      -- a frame costing more than this drops the next one
  },
  highlights = {},            -- e.g. { EpicenterAccent = { fg = "#7aa2f7" } }
  keymaps = { prefix = "<leader>e" }, -- or false
  search = { debounce_ms = 40, limit = 50 },
  grep = { debounce_ms = 60, limit = 200 },
  log = { level = "warn", file = nil }, -- nil -> stdpath("state")/epicenter.log
})
```

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

## How it relates to NavGraph

NavGraph is the engine: a single static Zig binary that lexes and indexes a
repo, extracts definitions and their in-body references, and resolves a call
graph across files and languages. Its CLI answers the same questions from a
terminal.

epicenter.nvim runs `navgraph lsp`, which speaks LSP over stdio — the standard
subset (`definition`, `references`, `hover`, `documentSymbol`,
`workspace/symbol`) plus custom `navgraph/*` methods for the graph queries.
One server per workspace root. Your open buffers are sent as overlays, so
answers include edits you have not saved yet.

With `lsp.fallback_only` (the default), navgraph's standard providers are
hidden on buffers that already have a real language server, so `gd`, `gr` and
`K` never return duplicates — and still work in the many files no language
server covers.

## Why it feels instant

Nothing on the UI path blocks. Every server call is asynchronous and
cancellable, and each keystroke's request is tagged with a channel: when a
newer request goes out, the older response is dropped on arrival rather than
painted, so results never flicker backwards to a query you have already
replaced. Requests are debounced (40ms for search) so a fast typist issues a
handful of queries, not one per character.

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

`lua/epicenter/registry.lua` collects the specs, and `plugin/epicenter.lua`,
`:Epicenter` completion, the keymap installer, `:checkhealth` and the config
defaults all iterate it — nothing else needs editing. Two features claiming the
same subcommand or option key is a hard error, never a silent override.

Feature modules must not `require("epicenter.config")` at file scope: config
builds its defaults from the registry, so that would be a cycle. Require it
inside `run`.

The UI kit is the public contract for features:
`ui/window`, `ui/animate`, `ui/easing`, `ui/theme`, `ui/icons`, `ui/list`,
`ui/tree`, `ui/prompt`, `ui/preview`, `ui/toast`, `ui/palette`.
Server access goes through `epicenter.client`, which already has a helper for
every `navgraph/*` method.

## Development

```sh
make test    # headless suite
make smoke   # drives the real palette in a real Neovim and asserts the result
make lint    # stylua --check + luacheck
make fmt     # stylua
```

Tests run against `tests/fake_navgraph.lua`, a fake server that speaks the same
protocol over stdio against `tests/fixtures/` — so the suite needs no `zig` and
no network. Its handlers are registered per area under `tests/fake/`; a new
area is one new file there.

## Licence

MIT © Marcus Engsig

# Changelog

## 1.1.0 — 2026-08-28

Everything the protocol 1.1 addendum adds, and the flow around it: getting a
result set out of the editor, seeing what a change already broke, and the two
questions an agent asks about a symbol.

### Flow

- **Quickfix and location list** — `<C-q>` / `<C-l>` inside any panel or
  palette send the current rows (or the `<Tab>` multi-selection) to the
  quickfix or location list; every subcommand that produces rows also takes
  `--qf` / `--loc` directly, e.g. `:Epicenter blast --qf`.
- **Peek** (`:Epicenter peek`, `<leader>eP`, or `o` inside any panel) — the
  definition under the cursor in a float that does not take focus. `<CR>`
  goes there, `q` dismisses it, and so does moving the cursor.
- **Resizing and moving a panel** — `+`/`-`/`<`/`>`/`<C-arrow>` on every float
  panel built on the shared kit, remembered per panel type under
  `stdpath("state")` so it reopens at the size you left it, across a restart.
- **Palette upgrades** — `<C-space>` cycles the search palette through
  symbols → grep → references without losing what you typed; symbols you
  have jumped to before rank first, per project; `<C-y>` yanks `file:line`.
- **`:Epicenter tour`** — a minute with the whole plugin, a few notes each
  with the panel they are talking about open beside them. Mentioned once, on
  a first run, and never runs without asking.

### The new panels

- **Breadcrumbs and statusline** — `require("epicenter").breadcrumbs()` for
  a winbar, `require("epicenter").statusline()` for a `⌁ 12 ← · 4 →`
  fan-in/out fragment. Both read a cache and debounce one request per cursor
  line change; zero cost with the server down.
- **Call hierarchy** (`:Epicenter hierarchy`, `<leader>eH`) and **type
  hierarchy** (`:Epicenter types`, `<leader>eT`) — incoming/outgoing calls in
  one lazy tree, `d` flips direction; supertypes, subtypes, implementors and
  now **users** — who uses this type as a param, return, field, local,
  extends, implements, annotation or generic — the type panel's fourth
  group, from the custom `navgraph/types` rather than a standard LSP method.
  Both ride methods any editor gets from protocol 1.1, not just this one.
- **LLM context** (`:Epicenter context [symbol] [--budget N]`, `<leader>ey`)
  — one symbol packaged for a model: signature, doc, body, callers, callees,
  types and tests, as markdown on `+`, trimmed to a token budget by dropping
  bodies first, then tests, then types, then callees. `:Epicenter where`
  answers the reverse question — what a line (or a pasted stack-trace frame)
  is inside of.
- **Tests** (`:Epicenter tests`, `<leader>et`) — every test from which the
  symbol under the cursor is reachable, grouped by file, `dN` for how many
  calls away; `r` runs the test under the cursor through a per-language
  runner template, output in a scratch split, never blocking.
- **Impact** (always on) and **impact review** (`:Epicenter review`,
  `<leader>ea`) — the working change's blast radius, live: a calm inline
  marker on every impacted line, a statusline fragment, and a review panel
  that ticks each impacted symbol off (`a`/`A`/`u`) with approvals keyed to
  the exact code that earned them, so editing that code again clears the
  tick. `:Epicenter review export` copies a markdown checklist to `+`.
- **Telescope extension** — optional: `require("telescope").load_extension
  ("epicenter")` gets `.symbols()`, `.grep()` and `.blast()`, the same server
  calls the built-in palette and blast panel use, Telescope's own UI.
  Nothing here loads unless Telescope does the loading.

### Polish

- **Theme** — `theme.accent`: `"auto"` (the existing derivation), `"mono"`
  (one flat palette, no extra hue), or a literal `#rrggbb` / highlight group.
- **Motion under load** — a frame that blows its budget skips ahead by
  however many ticks the overrun costs, capped so the skip itself never
  drops the achievable rate below 30fps; a single fixed skip (the 1.0
  behaviour) only happened to hold that floor at the default 60fps.
- **`:Epicenter` completion** covers every new flag and subcommand argument.

### Neovim support and testing

Neovim 0.10, 0.11 and 0.12. Both lanes gained the addendum's shapes:
`tests/fake/v11.lua` speaks `navgraph/tests`, `navgraph/types`,
`navgraph/impact`, `navgraph/context`, `navgraph/where` and the standard
call-/type-hierarchy methods, contract-checked the same way the v1.0 methods
are; every v1.1 feature is gated behind `client.supports()`, so a v1.0
server is never sent a method it would answer `-32601` to — it gets a "needs
protocol 1.1" notice instead, and `make test-real` against a v1.0 server
skips those cases with that same reason rather than failing.

## 1.0.1 — 2026-08-28

Fixes `:Epicenter install` always falling back to a ~100s source build: the
release-asset glob checked `<os>` before `<arch>`, but the published assets are
named `navgraph-<arch>-<os>`, so a matching prebuilt binary never downloaded
even with `gh` authenticated. The pattern now matches the real names, a
downloaded archive is verified against the release's `SHA256SUMS` before it is
extracted, and a fallback to a source build now says why in the toast. The
README FAQ no longer describes NavGraph as a private repo — both repos are
public, and `gh` now only buys install speed, not access.

## 1.0.0 — 2026-08-28

The first release. epicenter.nvim drives [NavGraph](https://github.com/mengsig/NavGraph)
from inside Neovim: it runs `navgraph lsp` per workspace root, sends your open
buffers as overlays, and answers what a symbol is, who calls it, and what
breaks if you change it — on every keystroke, including edits you have not
saved.

### The panels

- **Search palette** (`:Epicenter search`) — fuzzy search over every definition
  in the project, with a live preview and fan-in on each row. `<C-r>` switches
  to reference mode, `<C-k>` cycles the kind filter.
- **Grep** (`:Epicenter grep`) — the same widget over raw text, repo-wide,
  optionally as a regex.
- **Blast radius** (`:Epicenter blast`) — a live impact panel that stays open
  and re-queries as you type, with the impacted lines marked in the source
  windows in three grades by ring distance, a hover card of callers, fan-in /
  fan-out badges at the end of a definition line, and `:Epicenter diff [ref]`
  for everything changed since a git ref.
- **Callers and callees** (`:Epicenter callers` / `callees`) — a tree that
  fetches one level at a time.
- **Call path** (`:Epicenter path`) — the chain between two symbols, drawn one
  rung at a time; it says so plainly when there is no path, and when a name is
  ambiguous it offers a candidate picker rather than reporting no path.
- **Outline** (`:Epicenter outline`) — a live sidebar that follows the cursor
  and re-renders on reindex. It is a real vertical split, so it takes its own
  columns rather than covering the code it navigates, and `<CR>` hands the
  cursor back to the source with the sidebar still open.
- **Hot spots**, **unused**, **graph export**, and a **status dashboard** that
  carries the index, the server, the languages and the log, with `r` rescan,
  `R` restart and `l` log.

### Neovim support

Neovim 0.10 and up. Everything that differs between 0.10 and 0.11+ goes through
one compatibility module rather than branching at the call site, because none
of it fails loudly: 0.11 made the LSP client method-call, `vim.validate` took a
flat signature, and `vim.lsp.start` gained `attach`. On 0.11+ the repo also
ships `lsp/navgraph.lua`, so `vim.lsp.enable("navgraph")` starts the same
server the plugin's own path does; that path stays the default either way.

`winborder`, `winblend`, `laststatus=3`, `splitkeep` and `nvim --clean` are all
asserted in the headless smoke: every float names its own border and blend, the
palette never paints over the global statusline, and no surface moves the
source window's view.

### Configuration and documentation

One registry in Lua is the single index of every subcommand, keymap and option.
The keymap table, the command table and the config reference in `README.md` and
`doc/epicenter.txt` are generated from it, and `make docs-check` fails when they
drift. Unknown config keys and wrong types are errors at `setup()` time, naming
the exact option.

### Behaviour under load

Every server call is asynchronous and cancellable, and an answer superseded by a
newer keystroke is dropped rather than painted. With every panel closed and
badges off, moving the cursor costs nothing: no request, no timer. With badges
on, a `CursorHold` repaints from the cached outline and sends nothing; an edit
costs at most one `navgraph/outline` request, and re-entering an already-open
buffer costs nothing further. A badge repaint starts at most one tween, none
when the badge did not change. Animation is one `vim.uv` timer per tween, and a
frame over budget drops the next one; `vim.g.epicenter_reduce_motion` or
`animate = false` turns it off with every widget landing on the same final
state.

### Getting the binary

`:Epicenter install` downloads a release through `gh` when it is authenticated
(so a private NavGraph works with no extra setup), and otherwise clones and
builds with `zig`. A session that cannot start a server says so once and points
at the command — including the likelier case of a navgraph installed before the
editor server shipped, which is refused on its own `--version` rather than
started four times. Every error names the log file, which `:Epicenter log`
opens, and `:checkhealth epicenter` reports the plugin version, the Neovim
version, the binary, its version and whether it can serve at all, the protocol
version of every running server (or why one failed to start, and where the log
is), the icon mode, the state of the keymaps, and the log path.

### Testing

Two lanes over the same feature entry points: `make test` against a fake server
speaking the same protocol (so the suite needs no `zig` and no network), and
`make test-real` against a real `navgraph lsp` over a multi-language fixture
tree. Both enforce `tests/contract/schema.lua`, the editor protocol as data
derived from NavGraph's own `docs/lsp.md`: a request carrying a parameter the
contract does not name is refused, and a response missing a promised field
fails. `make smoke` drives the real widgets in a real Neovim, and
`make screenshots` regenerates `assets/` from a real terminal.

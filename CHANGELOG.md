# Changelog

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
  and re-renders on reindex.
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

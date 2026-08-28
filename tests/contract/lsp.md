# NavGraph editor protocol — v1

`navgraph lsp` runs NavGraph as a resident editor
server: the whole code graph stays in memory, an edit re-indexes in single-digit
milliseconds, and blast-radius / search / call-graph queries answer in under a
millisecond.

It is a standard LSP server (a subset) **plus** custom `navgraph/*` methods.
Neovim's built-in client (`vim.lsp.start`) is the reference client.

```
navgraph lsp [--root <dir>] [--log <file>] [--log-level error|info|debug]
```

- **Transport** — JSON-RPC 2.0 over stdio with LSP framing
  (`Content-Length: N\r\n\r\n<json>`). A bare `\n` after the header is accepted
  too, so hand-written scripts work.
- **stdout is the protocol channel.** Nothing else is ever written there.
  Diagnostics go to stderr, or to `--log <file>` (truncated per run).
- **`--root`** pins the index root. Without it the root is the workspace sent in
  `initialize` (`rootUri`, else the first `workspaceFolders` entry, else
  `rootPath`), falling back to the current directory.

## Positions and encodings

Positions are LSP-style: 0-based `line` and `character`. The server negotiates
`positionEncoding: "utf-8"` when the client offers it in
`general.positionEncodings`, otherwise UTF-16 with correct conversion on
non-ASCII lines (an astral code point counts as a surrogate pair; a column
landing inside a multi-byte sequence snaps to that sequence's start).

Symbol `line` / `endLine` in navgraph payloads stay **1-based**, matching the
CLI's JSON. LSP `Location` / `Range` values are **0-based**, per spec. `uri`
fields are `file://` URIs; `file` fields are root-relative paths, exactly as the
CLI prints them.

## Standard LSP

| Method | Notes |
| --- | --- |
| `initialize` | Capabilities below. |
| `initialized` (notif) | Builds the index (using `.navgraph/cache` like the CLI), reports `$/progress`, and always ends with `navgraph/indexed`. |
| `shutdown` → `null`, `exit` | `exit` after `shutdown` exits 0, without it exits 1. stdin EOF exits 0. |
| `textDocument/didOpen` `didChange` `didSave` `didClose` | Overlay store; see below. |
| `textDocument/definition` → `Location[]` | The identifier at the position, resolved with the same rules as `calls`. |
| `textDocument/references` → `Location[]` | Every use site; the declaration is included when `context.includeDeclaration`. |
| `textDocument/hover` | Markdown: `kind name`, the fenced signature, `file:line-endLine`, `← N callers → M callees`, then the doc comment. |
| `textDocument/documentSymbol` → `DocumentSymbol[]` | Nested; `range` spans `line..endLine`, `selectionRange` covers the name. Reflects the overlay. |
| `workspace/symbol` → `SymbolInformation[]` | Ranked like `navgraph/search`. |
| `workspace/didChangeWatchedFiles` (notif) | Re-stats the listed files and re-indexes. |
| `$/cancelRequest`, `$/setTrace` (notif) | Accepted and ignored. |

`initialize` advertises:

```jsonc
{"capabilities": {
  "positionEncoding": "utf-8",                     // or "utf-16"
  "textDocumentSync": {"openClose": true, "change": 1, "save": {"includeText": false}},
  "definitionProvider": true, "referencesProvider": true, "hoverProvider": true,
  "documentSymbolProvider": true, "workspaceSymbolProvider": true,
  "experimental": {"navgraph": {"protocolVersion": 1, "methods": [ /* every implemented navgraph/* method */ ]}}
}, "serverInfo": {"name": "navgraph", "version": "…"}}
```

`initializationOptions` (all optional):

| Field | Default | Meaning |
| --- | --- | --- |
| `tests` | `"with"` | `with` \| `without` \| `only` — the test-code scope. |
| `strict` | `false` | Follow only high-confidence (type/self-bound) edges. |
| `debounceMs` | `120` | How long an edit waits before re-indexing. |
| `watch` | `true` | Poll file mtimes for out-of-editor changes. |
| `watchIntervalMs` | `2000` | Poll interval. |
| `depth` | `3` | Default graph depth (max 10). |

### Overlays

An open document's text overrides the disk copy everywhere the server reads
source: indexing, `navgraph/grep`, hover, and position lookups. `didChange`
(Full sync — the last content change wins) schedules a debounced re-index of
that file; `didClose` drops the overlay and the disk copy is re-read; `didSave`
re-stats the file. Every re-index ends with `navgraph/indexed`.

An overlay for a path that does not exist on disk is indexed as a new file, and
disappears again when the buffer is closed.

## Errors

| Code | When |
| --- | --- |
| `-32700` | A frame body that is not JSON, or a frame the server could not parse. The server resyncs and keeps serving. |
| `-32600` | Not a JSON-RPC request, or a request before `initialized`. |
| `-32601` | Unknown method. |
| `-32602` | Bad params: a missing/ill-typed field, an unknown `direction`, an uncompilable grep pattern, an unindexed file. |
| `-32603` | Internal failure (allocation, IO). |
| `-32001` | A `Target` that resolves to nothing — `{"message": "…: symbol not found", …}`. |
| `-32002` | The request could not be completed: a grep regex that exhausts the backtracking budget, or a `navgraph/diff`/`{ref}` target whose `git diff` failed (bad ref, no git tree, git unavailable). |

A malformed *notification* gets no reply, per JSON-RPC. Nothing a client can
send kills the server.

## Shared result shapes

```
Symbol { id:int, name:string, qualified:string, kind:string, file:string, uri:string,
         line:int, endLine:int, sig:string, doc?:string, language:string,
         callers:int, callees:int, exported:bool, test:bool }
Node   { symbol:Symbol, exact:bool, lines:int[], children:Node[], ext:string[], recursion:bool }
Edge   { from:int, to:int, exact:bool, lines:int[] }
Target = { uri:string, position:{line,character} } | { symbol:string }
Scope  = { strict?:bool, tests?:"with"|"without"|"only" }
```

- `qualified` is `Parent.name` for a nested definition, else `name` — the form
  `{ symbol: … }` accepts back.
- `kind` and `language` use the CLI's short tags (`fn`, `method`, `struct`, …;
  `zig`, `py`, `ts`, …).
- `id` is a graph index, **stable only within one index generation.** Every
  re-index renumbers; clients refresh open views on `navgraph/indexed`.

## Custom requests

### `navgraph/status` `{}`

```
{ root, protocolVersion:1, version:string, files, symbols, edges,
  languages:{<lang>:files}, overlays:int, indexedAt:string(ISO-8601),
  lastIndexMs:int, cache:bool }
```

`cache` reports whether the on-disk parse cache served the last full walk.

### `navgraph/symbolAt` `{ uri, position }`

```
{ word:string, symbol:Symbol|null, enclosing:Symbol|null, candidates:Symbol[] }
```

`candidates` lists the same-name definitions that were **not** chosen.

Resolution order — the graph's own, not a fresh guess:

1. The cursor is on a definition's own name → that definition.
2. Otherwise the enclosing body's already-resolved reference for that name on
   that line (receiver- and import-aware, exact edges preferred).
3. Otherwise a name lookup, preferring a definition in the cursor's own file.

### `navgraph/blast`

Params: `Target | { file:string } | { ref:string }`, plus
`{ depth?:int, direction?:"callers"|"callees", limit?:int (500) } & Scope`.

```
{ roots:Symbol[],
  nodes:[{ symbol:Symbol, depth:int, via:int[], exact:bool }],
  edges:Edge[],
  summary:{ symbols:int, files:int, tests:int, maxDepth:int, truncated:bool,
            byDepth:int[], byFile:[{file:string,count:int}] } }
```

- `{ file }` unions every definition in that file. `{ ref }` is every definition
  changed since that git ref (`navgraph diff`'s rule) **plus** every definition
  in a file whose unsaved buffer differs from the copy on disk.
- Breadth-first to `depth`; each symbol appears once, at its **minimum** depth.
- `via` names the depth-1 neighbours the node was reached through.
- `edges` are always written caller→callee, whichever direction the walk ran.
- `byFile` is ranked by count descending, then path.
- `truncated` is set when `limit` stopped the walk.

### `navgraph/search`

Params: `{ query:string, kinds?:string[], refs?:bool, limit?:int (50) } & Scope`.

```
{ items:[{ symbol:Symbol, score:int, matches:int[], lines?:int[] }], total:int }
```

Fuzzy subsequence match on `qualified`, ranked **exact > prefix >
word-boundary > substring > subsequence**; ties break on fan-in, then the
shorter file path, then the symbol id (so paging is stable). `matches` holds the
byte offsets in `qualified` where the query characters landed. `total` counts
every match, before `limit`.

With `refs: true` the query matches **use sites** instead: an item's `symbol` is
the *referencing* definition and `lines` lists its use-site lines. The pattern
grammar is the CLI's `search --refs` one, so `Recv.field` and `.field` pin
instance-attribute reads.

### `navgraph/grep`

Params: `{ pattern:string, regex?:bool (false), caseSensitive?:bool (false),
limit?:int (200), include?:string[] }`.

```
{ items:[{ file, uri, line:int(1-based), character:int(0-based), text:string,
           enclosing:Symbol|null }], total:int, truncated:bool }
```

Runs over the in-memory, overlay-aware sources, so it sees unsaved edits.
`include` globs match the basename when the pattern has no `/`, else the
root-relative path; `*` stays within a segment, `**` crosses separators, `?` is
one character.

`regex: true` uses a small built-in engine: literals, `.`, character classes
(`[a-z]`, `[^…]`, `\d \w \s` and their negations), groups with alternation,
greedy and lazy `* + ? {n} {n,} {n,m}`, and the `^` `$` anchors. No
backreferences, no lookaround, no captures. Backtracking is capped; a
pathological pattern returns `-32002` rather than hanging.

### `navgraph/callers` / `navgraph/calls`

Params: `Target & { depth?:int (1), refs?:bool } & Scope` → `{ root:Node }`.

Mirrors the CLI's `callers`/`calls -j` tree. `lines` on a child is every
call-site line of the edge to its parent; `ext` lists unresolved call targets;
`recursion` marks a node already on the path. Plain data reads (a module `var`,
`const` or field) are hidden unless `refs: true`, exactly as in the CLI.

### `navgraph/rescan` `{ full?:bool }` → the `navgraph/status` shape

Re-walks the tree, so files created or deleted outside the editor are picked up
(a git checkout, a formatter). `full: true` ignores the on-disk cache. Open
documents are re-applied afterwards, so unsaved edits survive a rescan.

### `navgraph/neighbors`

Params: `Target & Scope` → `{ items:[{ symbol:Symbol,
callees:[{symbol,exact,lines}], callers:[{symbol,exact,lines}] }] }`.

Callees and callers of one symbol, one level deep, in a single view — a
quicker "what's around this" than `blast`/`callers`/`calls`. One entry in
`items` per definition the `Target` resolves to — a name with several
definitions (overloads, same-named methods across files) gets an entry for
each, exactly as the CLI's `neighbors` does, not just the first. Unlike the
CLI, both sides go through the same `Scope` (`strict`/`tests`) every other
navgraph/* walk uses, for a consistent contract; and unlike `blast`/`callers`/
`calls`, plain data-read callees are always included (there is no `refs`
param here, matching the CLI's `-j` output).

### `navgraph/path`

Params: `{ from:string, to:string }` → `{ path:Symbol[] }`.

The shortest call path from `from` to `to` (BFS over resolved call/use edges),
source-first; empty when either name is unknown or no path exists. Names accept
the same `Parent.name` / `name@path` forms as every CLI name argument.

### `navgraph/outline`

Params: `{ path?:string, kinds?:string[], limit?:int (300) } & Scope` →
`{ files:[{file,lang,symbols:Symbol[]}] }`.

Every visible top-level (and nested) definition per file, in indexing order.
`path` is a substring filter over the root-relative path; `kinds` restricts to
kind tags (`fn`, `struct`, …).

### `navgraph/hot`

Params: `{ path?:string, limit?:int (25) } & Scope` →
`{ items:[{symbol,fanIn,fanInExact,fanInTest,fanOut,fanOutExact}] }`.

Functions/methods ranked by connectivity — the load-bearing symbols. `*Exact`
counts exclude heuristic (name-collision) edges; `fanInTest` is the share of
callers living in test files. `strict` drops entries whose connectivity is
entirely heuristic. Unlike the CLI, an explicit `limit` is always honored —
the CLI overloads its own default (300) as a sentinel meaning "unset", so
`navgraph hot -l 300` is indistinguishable from no flag at all; this adapter
has no such sentinel, so `{"limit":300}` returns up to 300 results.

### `navgraph/unused`

Params: `{ path?:string, noPublic?:bool, followImports?:bool, limit?:int (300)
} & Scope` → `{ items:[{symbol,testOnly}] }`.

Zero-caller function/method/type definitions — removal candidates, not broken
code. `tests`: `with` (default) lists code dead in the whole graph;
`without` also flags code used only by tests (`testOnly: true`); `only` lists
unused test helpers. `noPublic` drops exported symbols (possible public API).
`followImports` disambiguates same-name symbols by import reachability instead
of the safe family-wide name tally — finds dead code masked by a used
same-name twin, at the cost of depending on import resolution.

### `navgraph/diff`

Params: `{ ref?:string ("HEAD"), depth?:int (1), direction?:"callers"|
"callees" ("callers"), limit?:int (500) } & Scope` → `{ ref:string,
blast: <the navgraph/blast result> }`.

Definitions changed since `ref` **plus** every definition in a file whose
unsaved buffer differs from disk, wrapped as a `navgraph/blast` walk from those
roots — the blast radius of a pending change. Unlike `navgraph/blast`'s own
`{ ref }` target form, an empty change set is not a `-32001` error here:
"nothing changed" is a routine answer, not a failed lookup. A `ref` git
rejects, or a served root that is not a git tree, **is** an error —
`-32002` with git's own message — so a mistyped ref is never reported as a
clean tree; this also applies to `navgraph/blast`'s `{ ref }` form.

### `navgraph/routes`

Params: `{ filter?:string, limit?:int (300) }` →
`{ items:[{symbol,handler:Symbol|null,callers:Symbol[]}] }`.

Every HTTP route (`symbol.name` is `"METHOD /path"`, e.g. `"GET /api/orders"`),
its resolved handler definition, and the client call sites that hit it.
`filter` is a substring match over the route name.

### `navgraph/events`

Params: `{ filter?:string, limit?:int (50) }` →
`{ groups:[{key,sites:[{role:"handler"|"emitter", verb, file, uri, line, in?}]}] }`.


Message-bus handlers (`register`/`on`) linked to emitters (`send`/`emit`) by
their shared string key, key-sorted, paired keys first. `in` names the
enclosing definition when the site sits inside one. `limit` caps the number of
key groups returned.

### `navgraph/imports`

Params: `{ path?:string, limit?:int (300) }` →
`{ files:[{file,uri,imports:[{target,targetUri,binding}]}] }`.

The local modules each in-scope file imports (resolved edges only). `path` is
a substring filter over the importing file's path. `limit` caps the number of
files listed (each file's full import list still comes through).

### `navgraph/importers`

Params: `{ path:string }` → `{ files:[{file,uri,importers:[{file,uri}]}] }`.

Files that import the file(s) matching `path` — reverse dependencies. `path`
is required (a substring filter over the imported file's path).

### `navgraph/graph`

Params: `{ path?:string } & Scope` → `{ path:string }`.

Renders the same interactive HTML visualization as `navgraph graph` and writes
it to `.navgraph/graph-<hash>.html` under the served root (`<hash>` identifies
the view — the `path` filter and test scope — so re-requesting the same view
overwrites its one file rather than leaving the previous render behind).
`path` is returned root-relative; open it in a browser. `tests` selects
whether test symbols appear in the graph (`strict` has no effect here).

## Notifications (server → client)

- **`navgraph/indexed`** `{ reason:"initial"|"change"|"save"|"rescan"|"watch",
  files:int, symbols:int, edges:int, ms:int, changedFiles:string[] }` — sent
  after **every** (re)index. Clients refresh open views on it.
- **`$/progress`** for the initial index, after a
  `window/workDoneProgress/create` request, and only when the client advertised
  `window.workDoneProgress`.
- **`window/logMessage`** for diagnostics.

## Watching

With `watch: true` the server polls the mtime/size of every indexed file every
`watchIntervalMs`; a change re-indexes it and emits `navgraph/indexed` with
`reason: "watch"`. A file the editor holds open is skipped — the buffer is
authoritative while a document is open. Files *created* outside the editor are
picked up by `navgraph/rescan` or `workspace/didChangeWatchedFiles`, not by the
mtime poll (which only re-stats files it already knows). Editor notifications
remain the primary realtime path.

## Concurrency model

**There is none, by construction.** The server is single-threaded: one timed
read on stdin drives everything.

- When the read returns bytes, complete frames are extracted and dispatched one
  at a time. A request is answered before the next is read.
- When the read times out, the debounce window or the watcher interval is due,
  and the loop does that work inline. The read deadline is always the soonest of
  the two, so neither is starved by an idle client.
- Every handler that reads the graph flushes pending edits first. A request that
  arrives mid-debounce therefore sees those edits — it waits for the index
  rather than answering from a stale graph.

The index, the overlays, the reader and the writer are all owned by that one
thread. No shared mutable state, no lock, and no data race is possible.
`$/cancelRequest` is accepted and ignored because there is never a request in
flight to cancel.

This is a deliberate departure from "a watcher thread": a thread would buy
nothing here (an mtime scan of a large tree is a few milliseconds, and indexing
must serialize with queries anyway) and would cost a mutex around the graph.

### Memory ownership

The initial walk's arena owns every file's text and parse output. When a file is
re-parsed its slot takes a private arena holding the newer copy; the arena the
*live* index still points into is retired and freed only once the replacement
index is in place. So a re-index never frees memory a served response might
still reference, and steady-state memory is the initial walk plus one arena per
currently-edited file.

## Measured performance

Zig 0.16.0, `-Doptimize=ReleaseFast`, Linux x86-64. "server" is the `ms` the
server reports in `navgraph/indexed`; query figures are the best of seven round
trips over the pipe. Ranges span two independent runs — cold-cache indexing in
particular varies with page-cache warmth.

| Measurement | This repo (30 files, ~23k lines) | 59k-line tree (250 files) | 118k-line tree (500 files) |
| --- | --- | --- | --- |
| Initial index, cold cache | **36–46 ms** | 67–107 ms | 96–129 ms |
| Initial index, warm cache | **14–16 ms** | 31–36 ms | — |
| Single-file re-index (debounce excluded) | **4–10 ms** | **7–19 ms** | — |
| `navgraph/search` | **1.2–2.1 ms** | 3.2 ms | — |
| `navgraph/grep` (literal) | **1.9–3.4 ms** | 6.4–6.6 ms | — |
| `navgraph/blast` depth 3 | **0.1 ms** | 0.4–0.5 ms | — |
| `navgraph/callers` depth 2 | **≤ 0.1 ms** | 0.2 ms | — |
| Peak resident memory | 10.8 MB | 20.5 MB | **34.8–36.1 MB** |

Against the v1 targets: initial index of this repo < 1 s (36–46 ms), single-file
re-index < 100 ms on a 50k-line tree (7–19 ms), search / grep / blast(3) each
< 30 ms (≤ 3.4 ms), resident memory < 200 MB at 100k lines (≈ 35 MB).

**Targeted re-resolution was measured and is not needed.** A re-index re-parses
only the changed file and re-assembles the graph from the already-parsed rest;
full reference re-resolution over a 59k-line tree costs single-digit to low-tens
of milliseconds, an order of magnitude inside the budget. Restricting resolution
to the files affected by a changed definition would add real complexity (and a
new correctness surface) to buy nothing measurable, so the simple whole-graph
re-assembly stands.

Reproduce with a client that drives the binary over a pipe: `initialize` →
`initialized`, read the `ms` from `navgraph/indexed`, then time
`didChange` → `navgraph/status` round trips and the query methods.

## Limitations

- Symbol ids are per-generation (see above).
- `textDocument/definition` returns the resolved definition first, then the
  other same-name candidates, so an ambiguous name still offers every choice.
- The parse cache is not written while a document is open: the live index then
  holds unsaved text, which must never be stored in a cache keyed by disk mtime.
- No diagnostics are published — NavGraph is a navigator, not a compiler.
- `navgraph/diff` (and `navgraph/blast`'s `{ ref }` form) misses an untracked
  file: `git diff` never lists one, and an unsaved buffer whose text matches
  the new file on disk looks unchanged to the overlay half too. Matches the
  CLI's `diff`, which has the same gap. Save the file under a tracked path (or
  `git add` it) to bring it into `diff`'s view.

## Neovim

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "zig", "python", "javascript", "typescript", "go", "rust", "ruby", "lua", "c", "cpp", "cs" },
  callback = function(args)
    local root = vim.fs.root(args.buf, { ".git", "build.zig", "package.json", "go.mod", "Cargo.toml" })
    if not root then return end
    vim.lsp.start({
      name = "navgraph",
      cmd = { "navgraph", "lsp" },
      root_dir = root,
      init_options = { depth = 3, debounceMs = 120 },
    }, { bufnr = args.buf })
  end,
})

-- A custom method, for a blast-radius picker:
-- vim.lsp.buf_request(0, "navgraph/blast",
--   { uri = vim.uri_from_bufnr(0), position = { line = 10, character = 4 }, depth = 3 },
--   function(err, result) ... end)
```

## Implementation map

`src/lsp/` — each layer depends only on the ones below it.

| File | Responsibility |
| --- | --- |
| `loop.zig` | The stdio run loop, the read deadline, logging. |
| `handlers.zig` | The method table, `initialize` negotiation, error mapping. |
| `queries.zig` | Target resolution, blast, call trees, hover, document symbols, grep, and every other `navgraph/*` adapter. |
| `search.zig` | Fuzzy ranking, include globs, grep patterns. |
| `payload.zig` | The JSON shapes above — one writer each. |
| `session.zig` | The resident index: overlays, re-index, watching, ownership. |
| `overlay.zig` | The document store and `file://` URIs. |
| `position.zig` | Position ↔ byte offset, identifier extraction. |
| `rpc.zig` | Framing and JSON-RPC envelopes. |
| `regex.zig` | The bounded grep regex engine. |

Nothing here re-implements NavGraph's semantics: name resolution, edge
confidence, call-site lines, test classification and dead-read filtering all
come from `src/query.zig` and `src/index.zig`.

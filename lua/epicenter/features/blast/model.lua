--- Pure core of the blast panel: query parameters, the ring/file/node row
--- model, and the diff between two results. No windows, no buffers, no server
--- - so every rendering and realtime-diff rule is testable without a UI.
---
--- Field names follow the protocol (`docs/lsp.md` v1): a node carries `depth`
--- and `exact`, and the counts come from the server's `summary` rather than
--- being recounted here.
local M = {}

--- @class epicenter.blast.Node
--- @field key string stable across re-queries: uri plus qualified name
--- @field symbol table the protocol's Symbol
--- @field depth integer 1-based distance from a root
--- @field exact boolean false when the edge was resolved by name alone
--- @field state? "added"|"removed" set only while a realtime transition plays

M.DIRECTIONS = { "callers", "callees" }
M.TESTS = { "with", "without", "only" }

--- Params a panel may send. `uri`+`position`, `symbol`, `file` and `ref` are
--- the protocol's Target forms; the rest is the query mode.
local TARGET_KEYS = { "uri", "position", "symbol", "file", "ref" }

--- @param direction "callers"|"callees"
function M.flip_direction(direction)
  return direction == "callers" and "callees" or "callers"
end

--- @param tests "with"|"without"|"only"
function M.cycle_tests(tests)
  local at = 1
  for i, value in ipairs(M.TESTS) do
    if value == tests then
      at = i
    end
  end
  return M.TESTS[(at % #M.TESTS) + 1]
end

--- @return integer depth clamped to 1..max
function M.clamp_depth(depth, max)
  return math.max(1, math.min(math.floor(depth), max))
end

--- Request parameters shared by `navgraph/blast` and `navgraph/diff`.
--- @param state { depth: integer, direction: string, tests: string, strict: boolean }
--- @param target table one of the protocol's Target forms
function M.params(state, target)
  local params = {
    depth = state.depth,
    direction = state.direction,
    tests = state.tests,
    strict = state.strict,
  }
  for _, key in ipairs(TARGET_KEYS) do
    params[key] = target[key]
  end
  return params
end

local function node_key(symbol)
  return ("%s#%s"):format(symbol.uri or symbol.file or "?", symbol.qualified or symbol.name or "?")
end

M.node_key = node_key

--- Total order of the panel body: depth, then file, then position in the file.
local function before(a, b)
  if a.depth ~= b.depth then
    return a.depth < b.depth
  end
  if a.symbol.file ~= b.symbol.file then
    return a.symbol.file < b.symbol.file
  end
  if a.symbol.line ~= b.symbol.line then
    return a.symbol.line < b.symbol.line
  end
  return a.key < b.key
end

--- Normalizes a `navgraph/blast` result into sorted nodes. The server already
--- emits each symbol once at its minimum depth; a duplicate is folded anyway
--- so a stricter server contract can never produce two rows for one symbol.
--- @param result table|nil a `navgraph/blast` payload
--- @return epicenter.blast.Node[]
function M.nodes(result)
  local by_identity, occupied, nodes = {}, {}, {}
  for _, entry in ipairs(result and result.nodes or {}) do
    local symbol = entry.symbol
    if symbol then
      local base_key = node_key(symbol)
      -- Distinguishes the SAME definition reached twice (fold, keep min
      -- depth) from a DIFFERENT definition that happens to share base_key.
      local identity = base_key .. "\0" .. tostring(symbol.line)
      local depth = math.max(1, math.floor(entry.depth or 1))
      local node = by_identity[identity]
      if not node then
        -- Two distinct definitions can share a uri#qualified key (same-named
        -- locals, overloads); disambiguate the second and later by line so
        -- neither collapses into the first. The first keeps the line-free
        -- key so an unrelated re-index (which shifts lines) still reads it
        -- as the same node.
        local key = occupied[base_key] and (base_key .. "@" .. tostring(symbol.line)) or base_key
        occupied[base_key] = true
        node = { key = key, symbol = symbol, depth = depth, exact = entry.exact ~= false }
        by_identity[identity] = node
        table.insert(nodes, node)
      elseif depth < node.depth then
        node.depth = depth
        node.exact = entry.exact ~= false
      end
    end
  end
  table.sort(nodes, before)
  return nodes
end

--- The empty summary, for a panel with no answer yet.
function M.empty_summary()
  return { symbols = 0, files = 0, tests = 0, maxDepth = 0, truncated = false }
end

--- @return { added: string[], removed: string[] } node keys, sorted
function M.diff(old, new)
  local was, is = {}, {}
  for _, node in ipairs(old or {}) do
    was[node.key] = true
  end
  for _, node in ipairs(new or {}) do
    is[node.key] = true
  end
  local added, removed = {}, {}
  for key in pairs(is) do
    if not was[key] then
      table.insert(added, key)
    end
  end
  for key in pairs(was) do
    if not is[key] then
      table.insert(removed, key)
    end
  end
  table.sort(added)
  table.sort(removed)
  return { added = added, removed = removed }
end

--- The set the panel paints while a realtime update plays: the new nodes plus
--- the ones that just left, each flagged, in the same total order. Keeping the
--- departing rows in place is what makes the update read as a change rather
--- than a rebuild.
--- @return epicenter.blast.Node[]
function M.transition(old, new)
  local delta = M.diff(old, new)
  local added, removed = {}, {}
  for _, key in ipairs(delta.added) do
    added[key] = true
  end
  for _, key in ipairs(delta.removed) do
    removed[key] = true
  end

  local out = {}
  for _, node in ipairs(new or {}) do
    local copy = vim.tbl_extend("keep", {}, node)
    copy.state = added[node.key] and "added" or nil
    table.insert(out, copy)
  end
  for _, node in ipairs(old or {}) do
    if removed[node.key] then
      local copy = vim.tbl_extend("keep", {}, node)
      copy.state = "removed"
      table.insert(out, copy)
    end
  end
  table.sort(out, before)
  return out
end

-- Rows -------------------------------------------------------------------------

--- @class epicenter.blast.Row
--- @field kind "ring"|"file"|"node"
--- @field depth integer
--- @field file? string
--- @field count? integer nodes under a ring or file heading
--- @field node? epicenter.blast.Node

--- Groups nodes into depth rings, each ring grouped by file. Pure.
--- @param nodes epicenter.blast.Node[]
--- @return epicenter.blast.Row[]
function M.rows(nodes)
  local rows = {}
  local depth, file = nil, nil
  local ring_row, file_row = nil, nil

  for _, node in ipairs(nodes) do
    if node.depth ~= depth then
      depth, file = node.depth, nil
      ring_row = { kind = "ring", depth = depth, count = 0 }
      table.insert(rows, ring_row)
    end
    if node.symbol.file ~= file then
      file = node.symbol.file
      file_row = { kind = "file", depth = depth, file = file, count = 0 }
      table.insert(rows, file_row)
    end
    ring_row.count = ring_row.count + 1
    file_row.count = file_row.count + 1
    table.insert(rows, { kind = "node", depth = depth, file = file, node = node })
  end
  return rows
end

--- Jump target of a row, or nil for a heading.
--- @return { path: string, line: integer, end_line?: integer }|nil
function M.target(row)
  if not row or row.kind ~= "node" then
    return nil
  end
  local symbol = row.node.symbol
  return {
    path = vim.uri_to_fname(symbol.uri),
    line = symbol.line,
    end_line = symbol.endLine,
  }
end

-- Rendering ---------------------------------------------------------------------

local function append(text, spans, chunk, hl)
  if chunk == "" then
    return text
  end
  table.insert(spans, { hl = hl, from = #text, to = #text + #chunk })
  return text .. chunk
end

M.append = append

--- @return string e.g. "1 file", "3 files"
function M.plural(count, noun)
  return ("%d %s"):format(count, count == 1 and noun or (noun .. "s"))
end

local plural = M.plural

--- @param row epicenter.blast.Row
--- @return { text: string, spans: table[] }
function M.render_row(row)
  local icons = require("epicenter.ui.icons")
  local spans, text = {}, ""

  if row.kind == "ring" then
    text = append(text, spans, ("  ring %d"):format(row.depth), "EpicenterTitle")
    return {
      text = append(text, spans, ("  %d"):format(row.count), "EpicenterCount"),
      spans = spans,
    }
  end

  if row.kind == "file" then
    return { text = append(text, spans, "    " .. row.file, "EpicenterMuted"), spans = spans }
  end

  local node = row.node
  local symbol = node.symbol
  local dim = node.state == "removed" or symbol.test == true
  text = append(text, spans, "      " .. icons.kind(symbol.kind) .. " ", "EpicenterMuted")
  text = append(
    text,
    spans,
    symbol.qualified or symbol.name or "?",
    dim and "EpicenterMuted" or "EpicenterNormal"
  )
  text = append(text, spans, ("  %s:%d"):format(symbol.file, symbol.line), "EpicenterMuted")
  if not node.exact then
    text = append(text, spans, "  ?", "EpicenterMuted")
  end
  if symbol.test then
    text = append(text, spans, "  test", "EpicenterHint")
  end
  return { text = text, spans = spans }
end

--- Header line naming what the panel is showing.
--- @param meta { kind: "blast"|"diff", root?: table, ref?: string }
function M.title_line(meta)
  local icons = require("epicenter.ui.icons")
  local spans, text = {}, ""
  if meta.kind == "diff" then
    text = append(text, spans, "  changes vs ", "EpicenterMuted")
    return { text = append(text, spans, meta.ref or "HEAD", "EpicenterAccent"), spans = spans }
  end

  local root = meta.root
  if not root then
    return {
      text = append(text, spans, "  no symbol under the cursor", "EpicenterMuted"),
      spans = spans,
    }
  end
  text = append(text, spans, "  " .. icons.kind(root.kind) .. " ", "EpicenterAccent")
  text = append(text, spans, root.qualified or root.name or "?", "EpicenterAccent")
  return {
    text = append(text, spans, ("  %s:%d"):format(root.file, root.line), "EpicenterMuted"),
    spans = spans,
  }
end

--- The server's summary as chips, plus the query mode the keys drive.
--- @param summary { symbols: integer, files: integer, tests: integer, maxDepth: integer,
---   truncated?: boolean, changed?: integer }
--- @param state { direction: string, tests: string, strict: boolean, follow: boolean }
function M.chips_line(summary, state)
  local icons = require("epicenter.ui.icons")
  local chips = {}
  if summary.changed then
    table.insert(chips, ("%d changed"):format(summary.changed))
  end
  table.insert(chips, plural(summary.symbols, "symbol"))
  table.insert(chips, plural(summary.files, "file"))
  table.insert(chips, plural(summary.tests, "test"))
  table.insert(chips, ("depth %d"):format(summary.maxDepth))
  if summary.truncated then
    table.insert(chips, "truncated")
  end

  local arrow = state.direction == "callers" and icons.ui("fan_in") or icons.ui("fan_out")
  local mode = { arrow .. " " .. state.direction, "tests " .. state.tests }
  if state.strict then
    table.insert(mode, "strict")
  end
  if state.follow then
    table.insert(mode, "follow")
  end

  local spans, text = {}, ""
  text = append(text, spans, "  " .. table.concat(chips, " · "), "EpicenterCount")
  return {
    text = append(text, spans, "    " .. table.concat(mode, " · "), "EpicenterHint"),
    spans = spans,
  }
end

return M

--- Pure core of the blast panel: query parameters, the ring/file/node row
--- model, and the diff between two results. No windows, no buffers, no server
--- - so every rendering and realtime-diff rule is testable without a UI.
local M = {}

--- @class epicenter.blast.Node
--- @field key string stable across re-queries: uri plus qualified name
--- @field symbol table the navgraph symbol
--- @field ring integer 1-based distance from a root
--- @field heuristic boolean the edge that reached it was resolved by name only
--- @field state? "added"|"removed" set only while a realtime transition plays

M.DIRECTIONS = { "callers", "callees" }
M.TESTS = { "with", "without", "only" }

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
--- @param target { uri?: string, position?: table, symbol?: string, ref?: string }
function M.params(state, target)
  local params = {
    depth = state.depth,
    direction = state.direction,
    tests = state.tests,
    strict = state.strict,
  }
  for _, key in ipairs({ "uri", "position", "symbol", "ref" }) do
    params[key] = target[key]
  end
  return params
end

local function node_key(symbol)
  return ("%s#%s"):format(symbol.uri or symbol.file or "?", symbol.qualified or symbol.name or "?")
end

M.node_key = node_key

--- Total order of the panel body: ring, then file, then position in the file.
local function before(a, b)
  if a.ring ~= b.ring then
    return a.ring < b.ring
  end
  if a.symbol.file ~= b.symbol.file then
    return a.symbol.file < b.symbol.file
  end
  if a.symbol.line ~= b.symbol.line then
    return a.symbol.line < b.symbol.line
  end
  return a.key < b.key
end

--- Normalizes a `navgraph/blast` or `navgraph/diff` result into sorted nodes.
--- A node reported twice (two paths reach it) keeps its shallowest ring.
--- @param result table|nil
--- @return epicenter.blast.Node[]
function M.nodes(result)
  local seen, nodes = {}, {}
  for _, entry in ipairs(result and result.nodes or {}) do
    local symbol = entry.symbol
    if symbol then
      local key = node_key(symbol)
      local node = seen[key]
      local ring = math.max(1, math.floor(entry.ring or 1))
      if not node then
        node = { key = key, symbol = symbol, ring = ring, heuristic = entry.heuristic == true }
        seen[key] = node
        table.insert(nodes, node)
      elseif ring < node.ring then
        node.ring = ring
        node.heuristic = entry.heuristic == true
      end
    end
  end
  table.sort(nodes, before)
  return nodes
end

--- Counts the panel's summary chips from the nodes it will actually show, so
--- the chips can never disagree with the body.
--- @param nodes epicenter.blast.Node[]
--- @return { symbols: integer, files: integer, tests: integer, max_depth: integer }
function M.counts(nodes)
  local files, count, tests, max_depth = {}, 0, 0, 0
  for _, node in ipairs(nodes) do
    if node.state ~= "removed" then
      count = count + 1
      files[node.symbol.file] = true
      if node.symbol.test then
        tests = tests + 1
      end
      max_depth = math.max(max_depth, node.ring)
    end
  end
  return { symbols = count, files = vim.tbl_count(files), tests = tests, max_depth = max_depth }
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
--- @field ring integer
--- @field file? string
--- @field count? integer nodes under a ring or file heading
--- @field node? epicenter.blast.Node

--- Groups nodes into depth rings, each ring grouped by file. Pure.
--- @param nodes epicenter.blast.Node[]
--- @return epicenter.blast.Row[]
function M.rows(nodes)
  local rows = {}
  local ring, file = nil, nil
  local ring_row, file_row = nil, nil

  for _, node in ipairs(nodes) do
    if node.ring ~= ring then
      ring, file = node.ring, nil
      ring_row = { kind = "ring", ring = ring, count = 0 }
      table.insert(rows, ring_row)
    end
    if node.symbol.file ~= file then
      file = node.symbol.file
      file_row = { kind = "file", ring = ring, file = file, count = 0 }
      table.insert(rows, file_row)
    end
    ring_row.count = ring_row.count + 1
    file_row.count = file_row.count + 1
    table.insert(rows, { kind = "node", ring = ring, file = file, node = node })
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

--- @param row epicenter.blast.Row
--- @return { text: string, spans: table[] }
function M.render_row(row)
  local icons = require("epicenter.ui.icons")
  local spans, text = {}, ""

  if row.kind == "ring" then
    text = append(text, spans, ("  ring %d"):format(row.ring), "EpicenterTitle")
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
  if node.heuristic then
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

--- Summary chips plus the query mode the keys drive.
--- @param counts { symbols: integer, files: integer, tests: integer, max_depth: integer, changed?: integer }
--- @param state { direction: string, tests: string, strict: boolean, follow: boolean }
--- @return string e.g. "1 file", "3 files"
function M.plural(count, noun)
  return ("%d %s"):format(count, count == 1 and noun or (noun .. "s"))
end

local plural = M.plural

function M.chips_line(counts, state)
  local icons = require("epicenter.ui.icons")
  local chips = {}
  if counts.changed then
    table.insert(chips, ("%d changed"):format(counts.changed))
  end
  table.insert(chips, plural(counts.symbols, "symbol"))
  table.insert(chips, plural(counts.files, "file"))
  table.insert(chips, plural(counts.tests, "test"))
  table.insert(chips, ("depth %d"):format(counts.max_depth))

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

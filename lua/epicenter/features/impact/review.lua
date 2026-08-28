--- The impact review panel: every definition the working change reaches,
--- grouped under the changed hunk that reaches it, with the ones already
--- looked at ticked off.
---
--- The grouping, the counts and the exported checklist are pure functions of
--- one `navgraph/impact` answer, so all three are testable without a server.
local M = {}

local approvals = require("epicenter.features.impact.approvals")

--- `file:line` of a hunk, the way its rows name it.
--- @param hunk { uri: string, range: table }
--- @return string
function M.hunk_label(hunk)
  local file = vim.fn.fnamemodify(vim.uri_to_fname(hunk.uri), ":~:.")
  return ("%s:%d"):format(file, (hunk.range.start.line or 0) + 1)
end

--- Who reaches whom, from the edges the server returned. An impact walk over
--- `callers` starts at the changed definition and moves to its callers, so
--- the step out from `id` is every edge pointing AT it.
--- @param direction "callers"|"callees"
local function step_map(edges, direction)
  local out = {}
  for _, edge in ipairs(edges or {}) do
    local from = direction == "callees" and edge.from or edge.to
    local to = direction == "callees" and edge.to or edge.from
    out[from] = out[from] or {}
    table.insert(out[from], to)
  end
  return out
end

--- Nodes grouped under the hunk that reaches them: a walk out from each
--- hunk's own roots over the returned edges, first hunk to arrive claiming
--- the node. A node no edge reaches is still reported, under `elsewhere`,
--- rather than dropped from a panel that claims to list the whole impact.
--- Pure.
--- @param result table a `navgraph/impact` answer
--- @param direction "callers"|"callees"
--- @return { label: string, hunk: table|nil, nodes: table[] }[]
function M.group_by_hunk(result, direction)
  local by_id = {}
  for _, node in ipairs(result.nodes or {}) do
    by_id[node.symbol.id] = node
  end
  local steps = step_map(result.edges, direction)

  local claimed, groups = {}, {}
  for _, hunk in ipairs(result.hunks or {}) do
    local group = { label = M.hunk_label(hunk), hunk = hunk, nodes = {} }
    local frontier = vim.tbl_map(function(symbol)
      return symbol.id
    end, hunk.roots or {})
    local seen = {}
    while #frontier > 0 do
      local next_frontier = {}
      for _, id in ipairs(frontier) do
        for _, other in ipairs(steps[id] or {}) do
          if not seen[other] then
            seen[other] = true
            table.insert(next_frontier, other)
            local node = by_id[other]
            if node and not claimed[other] then
              claimed[other] = true
              table.insert(group.nodes, node)
            end
          end
        end
      end
      frontier = next_frontier
    end
    table.insert(groups, group)
  end

  local orphans = {}
  for _, node in ipairs(result.nodes or {}) do
    if not claimed[node.symbol.id] then
      table.insert(orphans, node)
    end
  end
  if #orphans > 0 then
    table.insert(groups, { label = "elsewhere", hunk = nil, nodes = orphans })
  end

  for _, group in ipairs(groups) do
    table.sort(group.nodes, function(a, b)
      if a.depth ~= b.depth then
        return a.depth < b.depth
      end
      if a.symbol.file ~= b.symbol.file then
        return a.symbol.file < b.symbol.file
      end
      return a.symbol.line < b.symbol.line
    end)
  end
  return groups
end

--- Reviewed and total, the numbers the header and the statusline show. Pure.
--- @return integer reviewed, integer total
function M.counts(groups, state)
  local reviewed, total = 0, 0
  for _, group in ipairs(groups) do
    for _, node in ipairs(group.nodes) do
      total = total + 1
      if approvals.approved(state, node.symbol) then
        reviewed = reviewed + 1
      end
    end
  end
  return reviewed, total
end

--- A markdown checklist of the whole review, for a PR description. Pure.
--- @return string
function M.checklist(groups, state)
  local reviewed, total = M.counts(groups, state)
  local lines = { ("## impact · %d/%d reviewed"):format(reviewed, total), "" }
  for _, group in ipairs(groups) do
    table.insert(lines, ("### %s"):format(group.label))
    for _, node in ipairs(group.nodes) do
      table.insert(
        lines,
        ("- [%s] `%s` — %s:%d (depth %d)%s"):format(
          approvals.approved(state, node.symbol) and "x" or " ",
          node.symbol.qualified,
          node.symbol.file,
          node.symbol.line,
          node.depth,
          node.exact == false and " ?" or ""
        )
      )
    end
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

-- The panel ------------------------------------------------------------------------

--- The tree the panel draws: one node per hunk, its impacted definitions
--- underneath.
local function tree_of(groups)
  local roots = {}
  for _, group in ipairs(groups) do
    local node = { type = "hunk", key = "~" .. group.label, name = group.label, children = {} }
    for _, impacted in ipairs(group.nodes) do
      table.insert(node.children, {
        type = "impacted",
        key = ("%s#%s@%d"):format(group.label, impacted.symbol.qualified, impacted.symbol.line),
        name = impacted.symbol.qualified,
        node = impacted,
      })
    end
    table.insert(roots, node)
  end
  return roots
end

--- One display row. `state` is read at draw time so a fresh approval shows
--- without rebuilding the tree. Pure given both.
function M.render_row(row, state)
  local icons = require("epicenter.ui.icons")
  local node, spans = row.node, {}
  local indent = ("  "):rep(row.depth)

  local function append(text, chunk, hl)
    if chunk == "" then
      return text
    end
    table.insert(spans, { hl = hl, from = #text, to = #text + #chunk })
    return text .. chunk
  end

  if node.type == "hunk" then
    local text = indent .. icons.ui(row.expanded and "expanded" or "collapsed") .. " "
    return {
      text = append(text, ("%s (%d)"):format(node.name, #node.children), "EpicenterTitle"),
      spans = spans,
    }
  end

  local impacted = node.node
  local done = approvals.approved(state, impacted.symbol)
  local text = indent .. "  "
  text = append(text, done and (icons.ui("ok") .. " ") or "  ", "EpicenterHint")
  text = append(text, icons.kind(impacted.symbol.kind) .. " ", "EpicenterMuted")
  text = append(text, node.name, done and "EpicenterHint" or "EpicenterNormal")
  text =
    append(text, ("  %s:%d"):format(impacted.symbol.file, impacted.symbol.line), "EpicenterMuted")
  text = append(text, ("  d%d"):format(impacted.depth), "EpicenterCount")
  if impacted.exact == false then
    text = append(text, "  ?", "EpicenterInfo")
  end
  return { text = text, spans = spans }
end

--- @param session { root: string, result: table, groups: table[], state: table,
---   bufnr: integer, on_change: fun() }
--- @param gate_reason? string a `client.gate_notice` result (already
---   indented) - set when the server predates the protocol this needs, the
---   panel opens showing that instead of a (nonexistent) session
--- @return epicenter.Panel
function M.open(session, gate_reason)
  local panel_mod = require("epicenter.ui.panel")

  local function header()
    local reviewed, total = M.counts(session.groups, session.state)
    return (" impact review · %d/%d reviewed "):format(reviewed, total)
  end

  --- @param symbols table[] the definitions to mark, `approved` for each
  local function approve(panel, symbols, approved)
    if #symbols == 0 then
      return
    end
    -- L1: `not changed` used to always read as "no hash to key on", but the
    -- same false covers the ordinary no-op of `a` on an already-ticked row
    -- or `u` on one nobody ticked - track the two causes separately.
    local changed, no_hash = false, false
    for _, symbol in ipairs(symbols) do
      if not approvals.key(symbol) then
        no_hash = true
      elseif approvals.set(session.state, symbol, approved) then
        changed = true
      end
    end
    if not changed then
      if no_hash then
        require("epicenter").notify(
          "navgraph sent no content hash for this row - nothing to remember",
          "warn"
        )
      end
      return
    end
    local ok, err = approvals.save(session.root, session.state)
    if not ok then
      require("epicenter").notify(err, "error")
    end
    panel:set_title(header())
    panel:draw()
    session.on_change()
  end

  --- The definitions a key acts on: the row under the cursor, or - for `A` -
  --- every impacted definition in that row's file, collapsed groups
  --- included, which is what "approve the file" has to mean.
  local function selected_symbols(panel, whole_file)
    local row = panel:current()
    if not row or row.node.type ~= "impacted" then
      require("epicenter").notify("put the cursor on an impacted definition first", "warn")
      return {}
    end
    local symbol = row.node.node.symbol
    if not whole_file then
      return { symbol }
    end
    local out = {}
    for _, group in ipairs(session.groups) do
      for _, impacted in ipairs(group.nodes) do
        if impacted.symbol.file == symbol.file then
          table.insert(out, impacted.symbol)
        end
      end
    end
    return out
  end

  local panel = panel_mod.open({
    title = gate_reason and " impact review " or header(),
    footer = " a approve · A file · u undo · e export ",
    filetype = "epicenter-review",
    empty_text = "  nothing impacted by the working change",
    tree = {
      key_of = function(node)
        return node.key
      end,
      children_of = function(node)
        return node.children
      end,
    },
    render_row = function(row)
      return M.render_row(row, session.state)
    end,
    text_of = function(row)
      return row.node.name or ""
    end,
    target_of = function(row)
      local impacted = row.node.node
      if not impacted then
        return nil
      end
      return {
        path = vim.uri_to_fname(impacted.symbol.uri),
        line = impacted.symbol.line,
        end_line = impacted.symbol.endLine,
      }
    end,
    hints = {
      a = "approve this row",
      A = "approve every row in this file",
      u = "unapprove this row",
      e = "copy the checklist to the clipboard",
    },
    keys = {
      a = function(self)
        approve(self, selected_symbols(self, false), true)
      end,
      A = function(self)
        approve(self, selected_symbols(self, true), true)
      end,
      u = function(self)
        approve(self, selected_symbols(self, false), false)
      end,
      e = function()
        M.export(session)
      end,
    },
  })

  if gate_reason then
    panel:notice(gate_reason)
  else
    panel:set_roots(tree_of(session.groups), { expand_roots = true })
  end
  return panel
end

--- Repaints an open panel from a session whose answer has been replaced.
--- @param panel epicenter.Panel
--- @param session table|nil nil when the working change is gone
function M.reload(panel, session)
  if not panel:valid() then
    return
  end
  if not session then
    return panel:notice("  the working change is gone")
  end
  -- The cursor stays where the reader left it: a reindex arriving while
  -- they read row 12 must not send them back to row 1.
  local index = panel.list:index()
  panel:set_roots(tree_of(session.groups), { expand_roots = true })
  panel.list:select(index)
  panel:draw()
  panel:set_title(
    (" impact review · %d/%d reviewed "):format(M.counts(session.groups, session.state))
  )
end

--- Copies the checklist to the clipboard and says so.
--- M1: reached directly from the panel's `e` key (not through `run_review`'s
--- `current.answered` guard), so `session.groups` can be nil - the working
--- change vanished (a save) while the panel was still open and keyed.
function M.export(session)
  if not session.groups then
    return require("epicenter").notify("no working change to review", "info")
  end
  local register = require("epicenter.features.context").target_register()
  vim.fn.setreg(register, M.checklist(session.groups, session.state))
  local reviewed, total = M.counts(session.groups, session.state)
  require("epicenter").notify(("impact checklist yanked · %d/%d reviewed"):format(reviewed, total))
end

return M

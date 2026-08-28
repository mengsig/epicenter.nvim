--- The blast panel, the hover card and diff impact, against the real graph -
--- including the realtime path: an unsaved edit reindexes the server, the
--- notification comes back, and the open panel refreshes itself.
local epicenter = require("epicenter")
local events = require("epicenter.events")
local support = require("support")

local SERVICE = "py_fastapi/app/services/user_service.py"

local function names(panel)
  return vim.tbl_map(function(node)
    return node.symbol.qualified
  end, panel.nodes)
end

local function has(panel, qualified)
  return vim.tbl_contains(names(panel), qualified)
end

describe("real navgraph: blast radius", function()
  local root, buf, panel, original

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({
      ui = { icons = "ascii" },
      animate = false,
      lsp = { auto_start = false },
      blast = { depth = 2 },
    })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()

    local path = vim.fs.joinpath(root, SERVICE)
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
      vim.bo[buf].modified = false
    end
    events.clear()
  end)

  local function settled(target)
    return wait(function()
      return #target.nodes > 0 and target.nodes or nil
    end, 20000, "blast nodes")
  end

  it("walks the real callers of a named symbol, in depth rings", function()
    panel = epicenter.run("blast", { "UserService.fetch" }, buf)
    settled(panel)

    expect.truthy(has(panel, "get_user"), "route caller missing: " .. vim.inspect(names(panel)))
    expect.truthy(
      has(panel, "OrderService._resolve_owner"),
      "service caller missing: " .. vim.inspect(names(panel))
    )
    -- The summary is the server's, never recounted here (docs/lsp.md v1).
    expect.eq(panel.summary.symbols, #panel.nodes)
    expect.truthy(panel.summary.maxDepth >= 2, "depth 2 reaches a second ring")
    expect.truthy(panel.summary.files > 1, "the radius crosses files")
    for _, node in ipairs(panel.nodes) do
      expect.truthy(node.depth >= 1, "every node carries its ring")
    end
  end)

  it("blasts the definition the cursor sits in", function()
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(buf), { 11, 8 })
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    expect.truthy(has(panel, "get_user"), vim.inspect(names(panel)))
  end)

  it("refreshes the open panel when an unsaved edit reindexes the server", function()
    support.attach(root, buf)
    panel = epicenter.run("blast", { "UserService.fetch" }, buf)
    settled(panel)
    expect.falsy(has(panel, "UserService.audit"), "the new caller does not exist yet")

    local indexed = 0
    events.on(events.INDEXED, function()
      indexed = indexed + 1
    end)

    -- A new method calling fetch(): didChange -> reindex -> navgraph/indexed
    -- -> the panel re-queries itself and the caller appears.
    vim.api.nvim_buf_set_lines(buf, 54, 54, false, {
      "",
      "    def audit(self, id: int):",
      '        """Added by the real-lane realtime case."""',
      "        return self.fetch(id)",
    })

    wait(function()
      return indexed > 0
    end, 20000, "navgraph/indexed after the edit")
    wait(function()
      return has(panel, "UserService.audit")
    end, 20000, "the panel to pick up the new caller: " .. tostring(#panel.nodes) .. " nodes")
  end)

  it("shows the diff impact of an unsaved edit", function()
    support.attach(root, buf)
    vim.api.nvim_buf_set_lines(buf, 54, 54, false, {
      "",
      "    def audit(self, id: int):",
      "        return self.fetch(id)",
    })
    wait(function()
      local _, status = support.request(root, "navgraph/status", {})
      return (status.overlays or 0) > 0
    end, 20000, "the server to hold the buffer as an overlay")

    panel = epicenter.run("diff", {}, buf)
    settled(panel)
    expect.truthy(
      has(panel, "UserService.audit") or has(panel, "UserService.fetch"),
      "the changed file's definitions are the diff roots: " .. vim.inspect(names(panel))
    )
  end)
end)

describe("real navgraph: the hover card", function()
  local root, buf, card

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, SERVICE)))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if card then
      card:close()
      card = nil
    end
  end)

  it("names the symbol under the cursor and lists its real callers", function()
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(buf), { 11, 8 })
    card = epicenter.run("hover", {}, buf)
    local lines = wait(function()
      if not (card and card:valid()) then
        return nil
      end
      local text = vim.api.nvim_buf_get_lines(card.win.buf, 0, -1, false)
      return #text > 1 and text or nil
    end, 20000, "hover card content")

    local joined = table.concat(lines, "\n")
    expect.matches(joined, "fetch")
    expect.matches(joined, "get_user", "the card lists a real caller")
  end)
end)

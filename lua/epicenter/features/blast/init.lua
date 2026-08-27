--- Blast radius: what breaks if this symbol changes, in depth rings, live.
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

M.name = "blast"
M.summary = "Blast radius of a symbol, in depth rings, live"

M.options = {
  blast = {
    depth = 2,
    --- Upper bound for `+` in the panel.
    max_depth = 6,
    direction = "callers",
    tests = "with",
    strict = false,
    layout = "float",
    follow_debounce_ms = 80,
    realtime_debounce_ms = 150,
  },
  --- Ring-graded marks on the impacted lines while a panel is open.
  ripples = true,
}

M.option_rules = {
  enums = {
    ["blast.direction"] = { "callers", "callees" },
    ["blast.tests"] = { "with", "without", "only" },
    ["blast.layout"] = { "float", "vsplit" },
  },
  positive = {
    ["blast.depth"] = true,
    ["blast.max_depth"] = true,
    ["blast.follow_debounce_ms"] = true,
    ["blast.realtime_debounce_ms"] = true,
  },
}

--- @param bufnr integer
--- @return { uri: string, position: { line: integer, character: integer } }
function M.cursor_target(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
  return {
    uri = vim.uri_from_bufnr(bufnr),
    position = { line = cursor[1] - 1, character = cursor[2] },
  }
end

M.commands = {
  {
    name = "blast",
    desc = "Blast radius of the symbol under the cursor",
    run = function(ctx)
      local name = ctx.args[1]
      return require("epicenter.features.blast.panel").open({
        kind = "blast",
        target = name and { symbol = name } or M.cursor_target(ctx.bufnr),
        bufnr = ctx.bufnr,
      })
    end,
  },
}

M.keymaps = {
  { suffix = "e", command = "blast", desc = "Epicenter: blast radius" },
}

return M

--- Peek: the definition under the cursor, in a float you do not have to leave
--- what you are doing to read. No config requires at file scope - see
--- `epicenter.registry`.
local M = {}

--- Definition the cursor points at: the symbol under it, else the definition
--- whose body it sits in. Pure over a `navgraph/symbolAt` answer.
--- @param result table|nil
--- @return epicenter.Target|nil
function M.target_of(result)
  local symbol = result and result.symbol
  if not symbol or symbol == vim.NIL then
    symbol = result and result.enclosing
  end
  if not symbol or symbol == vim.NIL then
    return nil
  end
  return {
    path = vim.uri_to_fname(symbol.uri),
    line = symbol.line,
    end_line = symbol.endLine,
  }
end

local function open(ctx)
  local blast = require("epicenter.features.blast")
  local client = require("epicenter.client")
  local target = blast.cursor_target(ctx.bufnr)
  local origin_win = vim.api.nvim_get_current_win()

  client.symbol_at(target, function(err, result)
    -- An unfocused peek borrows <CR> and `q` on the buffer the reader is in.
    -- If they moved on while the server thought, those keys - and the float -
    -- would land on a place they never asked about.
    if
      vim.api.nvim_get_current_win() ~= origin_win
      or vim.api.nvim_get_current_buf() ~= ctx.bufnr
    then
      return
    end
    if err then
      return require("epicenter").notify(err.message or "navgraph did not answer", "error")
    end
    local resolved = M.target_of(result)
    if not resolved then
      return require("epicenter").notify("no definition under the cursor")
    end
    require("epicenter.ui.peek").open(resolved, { focus = false })
  end, { bufnr = ctx.bufnr, channel = "peek" })
end

M.name = "peek"
M.summary = "Read the definition under the cursor without going there"

M.commands = {
  {
    name = "peek",
    desc = "Read the definition under the cursor",
    run = open,
  },
}

M.keymaps = {
  { suffix = "P", command = "peek", desc = "Epicenter: peek the definition" },
}

return M

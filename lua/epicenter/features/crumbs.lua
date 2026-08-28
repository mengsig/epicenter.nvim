--- Where you are, and how connected it is: the enclosing chain for a winbar
--- and a fan-in/fan-out fragment for a statusline.
---
--- Both are read on every redraw, so the accessors do nothing but look at a
--- cache and, when the cursor has reached a new line, arm one debounced
--- request. Everything expensive - resolving the root, finding the session,
--- talking to the server - happens in that request, never in a redraw. With
--- no server for the buffer's project the accessors return an empty string
--- and no request is ever sent.
---
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

--- bufnr -> { wanted: string, shown: string|nil, crumbs: string, fan: table|nil,
---   debounce: table }
local cache = {}

--- What "the answer is still current" means: the buffer's contents and the
--- line the cursor is on. Moving along a line costs nothing.
local function key_of(bufnr, line)
  return ("%d:%d"):format(vim.api.nvim_buf_get_changedtick(bufnr), line)
end

local function forget(bufnr)
  local entry = cache[bufnr]
  if entry then
    entry.debounce.close()
    cache[bufnr] = nil
  end
end

--- Names of the enclosing chain, outermost first. A v1.0 server answers
--- `navgraph/symbolAt` without `breadcrumbs`; the enclosing definition alone
--- is then the honest answer, not an invented chain.
--- @param result table|nil a `navgraph/symbolAt` answer
--- @return string[]
function M.chain_of(result)
  local crumbs = result and result.breadcrumbs
  if type(crumbs) == "table" and #crumbs > 0 then
    return vim.tbl_map(function(symbol)
      return symbol.name
    end, crumbs)
  end
  local enclosing = result and result.enclosing
  if enclosing and enclosing ~= vim.NIL then
    return { enclosing.name }
  end
  return {}
end

--- Fan-in / fan-out of whatever the cursor is inside. The innermost crumb is
--- consulted before `enclosing`: off an identifier the server reports neither
--- a symbol NOR an enclosing definition - it resolves an identifier under the
--- column and nothing off one - but the chain is a property of the line and
--- is still there.
--- @param result table|nil a `navgraph/symbolAt` answer
--- @return { ["in"]: integer, out: integer }|nil
function M.fan_of(result)
  if not result then
    return nil
  end
  local function fan(symbol)
    if type(symbol) ~= "table" or symbol == vim.NIL or symbol.callers == nil then
      return nil
    end
    return { ["in"] = symbol.callers, out = symbol.callees or 0 }
  end
  local crumbs = type(result.breadcrumbs) == "table" and result.breadcrumbs or {}
  return fan(result.symbol) or fan(crumbs[#crumbs]) or fan(result.enclosing)
end

--- The statusline fragment. Pure, so its shape is testable without a server.
--- @param fan { ["in"]: integer, out: integer }|nil
--- @return string
function M.fan_text(fan)
  if not fan then
    return ""
  end
  local icons = require("epicenter.ui.icons")
  return ("%s %d %s · %d %s"):format(
    icons.ui("impact"),
    fan["in"],
    icons.ui("fan_in"),
    fan.out,
    icons.ui("fan_out")
  )
end

local function fetch(bufnr)
  local entry = cache[bufnr]
  if not entry or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local wanted = entry.wanted
  local line = tonumber(wanted:match(":(%d+)$"))
  if not line then
    return
  end

  local client = require("epicenter.client")
  -- Nothing serving this project: no request, and the accessors stay empty.
  if not client.session_for_buf(bufnr) then
    return
  end

  -- Column 0 on purpose: the enclosing chain and the enclosing definition are
  -- properties of the LINE, so moving along one must not cost a round trip.
  client.symbol_at({
    uri = vim.uri_from_bufnr(bufnr),
    position = { line = line - 1, character = 0 },
  }, function(err, result)
    local current = cache[bufnr]
    if err or not current or current.wanted ~= wanted then
      return
    end
    current.shown = wanted
    current.crumbs = M.chain_of(result)
    current.fan = M.fan_of(result)
    -- The winbar and statusline are only repainted when Neovim decides to;
    -- a fresh answer has to ask for that itself.
    vim.cmd("redrawstatus")
  end, { bufnr = bufnr, channel = "crumbs:" .. bufnr })
end

--- Cache entry for `bufnr`, arming one debounced request when the cursor has
--- reached a line the cache does not cover. Cheap: this runs on every redraw.
local function entry_for(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 or vim.bo[bufnr].buftype ~= "" then
    return nil
  end

  local entry = cache[bufnr]
  if not entry then
    local cfg = require("epicenter.config").get()
    entry = { crumbs = {}, fan = nil, wanted = nil, shown = nil }
    entry.debounce = require("epicenter.ui.prompt").debounce(cfg.crumbs.debounce_ms, function()
      fetch(bufnr)
    end)
    cache[bufnr] = entry
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      buffer = bufnr,
      once = true,
      callback = function()
        forget(bufnr)
      end,
    })
  end

  local wanted = key_of(bufnr, vim.api.nvim_win_get_cursor(win)[1])
  if entry.wanted ~= wanted then
    entry.wanted = wanted
    entry.debounce.call()
  end
  return entry
end

--- The enclosing chain of the cursor's line, for a winbar. Empty until the
--- first answer lands, and empty for good with no server.
--- @param bufnr? integer
--- @return string
function M.breadcrumbs(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local entry = entry_for(bufnr)
  if not entry or #entry.crumbs == 0 then
    return ""
  end
  return table.concat(entry.crumbs, require("epicenter.config").get().crumbs.separator)
end

--- The fan-in/fan-out fragment for a statusline, e.g. `⌁ 12 ← · 4 →`.
--- @param bufnr? integer
--- @return string
function M.statusline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local entry = entry_for(bufnr)
  return entry and M.fan_text(entry.fan) or ""
end

-- The winbar ---------------------------------------------------------------------

--- `%{...}`, not `%{%...%}`: the result is text, never re-read as statusline
--- items, so a symbol named with a `%` cannot break the bar.
local WINBAR = "%#EpicenterMuted# %{v:lua.require'epicenter'.breadcrumbs()}"

local group = nil
--- Windows this feature set a winbar on, so turning the option off takes it
--- back down instead of leaving it behind.
local installed = {}

local function install_winbar(win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then
    return
  end
  if vim.wo[win].winbar ~= "" and not installed[win] then
    return -- the user's own winbar; never overwrite it
  end
  installed[win] = true
  vim.wo[win].winbar = WINBAR
end

local function remove_winbars()
  for win in pairs(installed) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].winbar == WINBAR then
      vim.wo[win].winbar = ""
    end
  end
  installed = {}
end

--- @param cfg table resolved config
function M.setup(cfg)
  group = group or vim.api.nvim_create_augroup("EpicenterCrumbs", { clear = true })
  vim.api.nvim_clear_autocmds({ group = group })
  if not cfg.crumbs.winbar then
    return remove_winbars()
  end
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    callback = function()
      install_winbar(vim.api.nvim_get_current_win())
    end,
  })
  install_winbar(vim.api.nvim_get_current_win())
end

--- `:Epicenter crumbs` - the winbar in this window, on or off, without
--- editing the config for a one-off look.
local function toggle_winbar()
  local win = vim.api.nvim_get_current_win()
  if installed[win] then
    installed[win] = nil
    vim.wo[win].winbar = ""
    require("epicenter").notify("breadcrumbs off in this window")
    return
  end
  install_winbar(win)
  if not installed[win] then
    require("epicenter").notify("this window already has a winbar of its own", "warn")
  end
end

M.name = "crumbs"
M.summary = "Breadcrumbs for the winbar and a fan-in/out statusline component"

M.options = {
  crumbs = {
    --- Installs the winbar on every code window.
    winbar = false,
    debounce_ms = 120,
    separator = " › ",
  },
}

M.option_docs = {
  ["crumbs.winbar"] = "install the breadcrumb winbar on code windows",
  ["crumbs.separator"] = "drawn between the crumbs",
}

M.option_rules = {
  positive = { ["crumbs.debounce_ms"] = true },
}

M.commands = {
  {
    name = "crumbs",
    desc = "Toggle the breadcrumb winbar in this window",
    run = toggle_winbar,
  },
}

--- Test seam: drops every cached answer and closes its timer.
function M.reset()
  for bufnr in pairs(cache) do
    forget(bufnr)
  end
  remove_winbars()
end

return M

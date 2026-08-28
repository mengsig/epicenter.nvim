--- Drives one headline surface for `make screenshots`.
---
--- Run by `scripts/screenshots.sh` as the init of a real (not headless) Neovim
--- inside a 120x36 tmux pane, against the REAL navgraph binary over
--- `tests/fixtures/real`. `EPICENTER_SHOT` names the surface; the script opens
--- it, waits for it to settle, and then just sits there so tmux can capture
--- the pane.
local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/tests/?.lua;" .. repo .. "/tests/?/init.lua;" .. package.path

vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.number = true
vim.o.wrap = false
vim.o.signcolumn = "no"
vim.o.fillchars = "eob: "
vim.cmd.colorscheme(vim.env.EPICENTER_SHOT_COLORS or "habamax")

-- The capture says "default colour" as SGR 39/49 and never says what that is,
-- so hand the converter the scheme's Normal.
if vim.env.EPICENTER_SHOT_NORMAL_FILE then
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  local file = assert(io.open(vim.env.EPICENTER_SHOT_NORMAL_FILE, "w"))
  file:write(("#%06x #%06x\n"):format(normal.fg or 0xd0d0d0, normal.bg or 0x1c1c1c))
  file:close()
end

-- `screenshots.sh` points this at a throwaway copy of the fixture tree under a
-- throwaway HOME, so the dashboard's paths in a committed asset are `~/demo`
-- and not whoever ran `make screenshots`.
local root = vim.fs.normalize(vim.env.EPICENTER_SHOT_ROOT or (repo .. "/tests/fixtures/real"))
local binary = assert(vim.env.NAVGRAPH_BIN, "NAVGRAPH_BIN must name the navgraph binary")

--- Every shot: which file to open, and how to drive the surface once the
--- server is answering. `wait` is what "settled" means for that surface.
local SHOTS = {}

--- Opens a fixture file and attaches it to the running server, so the answers
--- in the shot include the buffer as an overlay - the way a real session works.
local function open_file(relative, line)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  local bufnr = vim.api.nvim_get_current_buf()
  assert(require("epicenter.client").start({ root = root, bufnr = bufnr }))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
  return bufnr
end

--- Presses a panel's own mapping, the way a user would.
local function press(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs and map.callback then
      return map.callback()
    end
  end
  error("no mapping for " .. lhs)
end

local function settle(pred, label)
  assert(vim.wait(20000, pred, 20), "timed out waiting for " .. label)
end

SHOTS.search = function()
  local buf = open_file("py_fastapi/app/services/user_service.py", 22)
  local palette = require("epicenter").run("search", {}, buf)
  -- What typing leaves behind: the text on the prompt line, and the query the
  -- prompt's own on_change then runs.
  palette.prompt:set_text("user")
  palette:query("user")
  settle(function()
    local item = palette.list:current()
    return item ~= nil and #(item.matches or {}) > 0
  end, "search results")
end

SHOTS.blast = function()
  local buf = open_file("py_fastapi/app/services/user_service.py", 22)
  local panel = require("epicenter").run("blast", { "UserService.create" }, buf)
  settle(function()
    return panel.answered > 0
  end, "blast results")
end

SHOTS.explorer = function()
  local buf = open_file("py_fastapi/app/services/user_service.py", 22)
  local panel = require("epicenter").run("callers", { "normalize_email" }, buf)
  settle(function()
    return panel.list:count() > 1
  end, "the first level of callers")
  -- Two levels: expand the first caller, so the tree shows a fetched level.
  panel.list:select(2)
  press(panel.win.buf, "l")
  settle(function()
    return panel.list:count() > 2
  end, "the second level of callers")
end

SHOTS["outline-status"] = function()
  local buf = open_file("py_fastapi/app/services/user_service.py", 22)
  local outline = require("epicenter").run("outline", {}, buf)
  settle(function()
    return outline.list:count() > 0
  end, "the outline")
  local dashboard = require("epicenter").run("status", {}, buf)
  settle(function()
    return table
      .concat(vim.api.nvim_buf_get_lines(dashboard.buf, 0, -1, false), "\n")
      :match("files") ~= nil
  end, "the dashboard")
end

local name = assert(vim.env.EPICENTER_SHOT, "EPICENTER_SHOT must name a surface")
local shot = assert(SHOTS[name], "unknown surface " .. name)

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("epicenter").setup({
      ui = { icons = "ascii" },
      animate = false,
      lsp = { auto_start = false },
      -- The source window stays visible beside the panel, so the ripple marks
      -- it paints into the code are in the frame.
      blast = { layout = "vsplit" },
    })
    local client = require("epicenter.client")
    local id = assert(client.start({ root = root, cmd = { binary, "lsp", "--root", root } }))
    settle(function()
      local c = vim.lsp.get_client_by_id(id)
      return c ~= nil and c.initialized == true and client.session_for_root(root) ~= nil
    end, "the navgraph server")
    shot()
    vim.cmd("redraw!")
  end,
})

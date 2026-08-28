-- Real-Neovim smoke: loads the plugin from the runtimepath only (no test
-- init), drives the search palette against the fake server with animation ON,
-- and asserts geometry, buffer content, highlights and a clean :messages.
--
--   make smoke
local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
package.path = repo .. "/tests/?.lua;" .. repo .. "/tests/?/init.lua;" .. package.path

local checks, failures = 0, 0

local function check(label, ok, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
  end
  io.write(
    ("%s  %s%s\n"):format(ok and "PASS" or "FAIL", label, detail and ("  [" .. detail .. "]") or "")
  )
  io.stdout:flush()
end

local function wait_for(label, pred, timeout)
  local ok = vim.wait(timeout or 10000, pred, 10)
  check(label, ok)
  return ok
end

vim.o.columns = 160
vim.o.lines = 40

check(":Epicenter exists after loading only this repo", vim.fn.exists(":Epicenter") == 2)
check(
  "runtimepath carries exactly one epicenter",
  #vim.api.nvim_get_runtime_file("lua/epicenter/init.lua", true) == 1
)

local registry = require("epicenter.registry")
local EXPECTED_COMMANDS = {
  "search",
  "grep",
  "blast",
  "hover",
  "diff",
  "callers",
  "callees",
  "peek",
  "path",
  "outline",
  "hot",
  "unused",
  "graph",
  "status",
  "install",
  "restart",
  "rescan",
  "log",
}
check(
  "registry indexes every subcommand",
  vim.deep_equal(registry.command_names(), EXPECTED_COMMANDS),
  table.concat(registry.command_names(), ",")
)

require("epicenter").setup({ ui = { icons = "ascii" } })
check("animation is on for this run", require("epicenter.config").motion_enabled() == true)

local support = require("support")
local root = support.start_fake()
check("fake navgraph server initialized", root ~= nil, root)

vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/config.lua")))
local buf = vim.api.nvim_get_current_buf()

local palette = require("epicenter").run("search", {}, buf)
check(
  "palette opened three panes",
  palette.prompt_win:valid() and palette.results_win:valid() and palette.preview_win:valid()
)

-- The open animation runs on a uv timer; wait for it to land on full size.
wait_for("open animation settled", function()
  return palette.tween == nil
end, 3000)

local expected = palette:_box()
local layout = require("epicenter.ui.palette").layout(expected, true)
local geometry = palette.results_win:geometry()
check(
  "results pane at its computed geometry",
  vim.deep_equal(geometry, layout.results),
  ("%dx%d @ %d,%d"):format(geometry.width, geometry.height, geometry.row, geometry.col)
)

palette:query("handle_request")
-- The palette shows the unfiltered list on open, so wait for a row that
-- actually carries match indices rather than for any row at all.
wait_for("results for the query arrived", function()
  local item = palette.list:current()
  return item ~= nil and #(item.matches or {}) > 0
end)

local lines = vim.api.nvim_buf_get_lines(palette.results_win.buf, 0, -1, false)
io.write("     results buffer:\n")
for i = 1, math.min(#lines, 4) do
  io.write(("       %d| %s\n"):format(i, lines[i]))
end
check(
  "top hit is the lua definition",
  palette.list:current().symbol.qualified == "M.handle_request",
  lines[1]
)
check("row shows file:line", lines[1]:match("app/server%.lua:9") ~= nil)
check("row shows fan-in", lines[1]:match("%d$") ~= nil)

local marks =
  vim.api.nvim_buf_get_extmarks(palette.results_win.buf, palette.list.ns, 0, -1, { details = true })
local match_marks, selection_marks = 0, 0
for _, mark in ipairs(marks) do
  if mark[4].hl_group == "EpicenterMatch" then
    match_marks = match_marks + 1
  end
  if mark[4].line_hl_group == "EpicenterSelection" then
    selection_marks = selection_marks + 1
  end
end
check("matched characters highlighted", match_marks > 0, match_marks .. " spans")
check("selected row highlighted", selection_marks == 1)

local preview_lines = vim.api.nvim_buf_get_lines(palette.preview_win.buf, 0, -1, false)
check(
  "preview shows the definition",
  table.concat(preview_lines, "\n"):match("function M%.handle_request") ~= nil
)

palette:accept("edit")
wait_for("jumped to the definition", function()
  return vim.api.nvim_buf_get_name(0):match("server%.lua") ~= nil
end, 5000)
local cursor = vim.api.nvim_win_get_cursor(0)
check("cursor on the definition line", cursor[1] == 9, "line " .. cursor[1])
check(
  "line under the cursor is the definition",
  vim.api.nvim_get_current_line():match("function M%.handle_request") ~= nil
)
wait_for("palette closed after the jump", function()
  return not palette.prompt_win:valid() and not palette.results_win:valid()
end, 3000)
check("jumplist entry pushed", vim.fn.getpos("''")[2] > 0)

-- F2: the open animation scales up from ~0.88 of the settled target, so a
-- width right at the preview threshold could dip below it on an early
-- frame even though the target itself has room - this is the exact width
-- the review pinned as broken (a red "animation stopped" notice on every
-- open, from the tween's own pcall). `tween == nil` alone does not catch
-- it: the tween still "settles" by giving up after the error. Capture the
-- notify instead. Safe to change columns here: no float is open yet.
local notified_error = nil
local original_notify = vim.notify
vim.notify = function(msg, level, ...)
  if level == vim.log.levels.ERROR then
    notified_error = msg
  end
  return original_notify(msg, level, ...)
end

vim.o.columns = 100
local narrow = require("epicenter").run("search", {}, buf)
wait_for("narrow-width (100 cols) open animation settled", function()
  return narrow.tween == nil
end, 3000)
vim.notify = original_notify
check("narrow-width open raised no error notification", notified_error == nil, notified_error)
check(
  "narrow palette still has all three panes",
  narrow.prompt_win:valid()
    and narrow.results_win:valid()
    and narrow.preview_win ~= nil
    and narrow.preview_win:valid()
)
narrow:close({ motion = false })
vim.o.columns = 160

-- === ep-explore wave: explorer/path/outline/hot/status panels, animation on ===
-- Each wave keeps its own smoke block delimited like this rather than
-- interleaving at a shared anchor, so a sibling wave's own block is a pure
-- addition here (F15).
local function press(panel, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
    if map.lhs == lhs and map.callback then
      return map.callback()
    end
  end
  error("no mapping for " .. lhs)
end

local source = vim.api.nvim_get_current_buf()
local explorer = require("epicenter").run("callers", { "log_request" }, source)
wait_for("explorer listed the callers", function()
  return explorer.list:count() == 2
end)
local tree_lines = vim.api.nvim_buf_get_lines(explorer.win.buf, 0, -1, false)
check("explorer roots at the symbol", tree_lines[1]:match("log_request") ~= nil, tree_lines[1])
check("its caller is the child row", tree_lines[2]:match("M%.handle_request") ~= nil, tree_lines[2])
explorer.list:select(2)
press(explorer, "l")
wait_for("expanding fetched the caller's caller", function()
  local line = vim.api.nvim_buf_get_lines(explorer.win.buf, 0, -1, false)[3]
  return line ~= nil and line:match("M%.start") ~= nil
end)
check("the level replaced the placeholder", explorer.list:count() == 3)
explorer:close()

-- The outline sidebar is a real vertical split (F8), and it is checked at the
-- very end of this file: `--headless` has no UI attached, so `vim.o.columns`,
-- `vim.o.lines` and `laststatus` are bookkeeping rather than a real grid, and
-- changing any of them once a real split has been drawn trips an assertion
-- inside Neovim 0.12.4's own grid code. Reproducible with no plugin loaded,
-- and headless only - a real terminal is fine. So every screen-size and
-- laststatus case runs first, and the split runs last.

local hot = require("epicenter").run("hot", {}, source)
wait_for("hot spots ranked the file", function()
  return hot.list:count() > 0
end)
check(
  "the busiest symbol carries a bar",
  vim.api.nvim_buf_get_lines(hot.win.buf, 0, -1, false)[1]:match("[#\226\150\136]") ~= nil
)
hot:close()

local dashboard = require("epicenter").run("status", {}, source)
wait_for("dashboard reported the index", function()
  return table
    .concat(vim.api.nvim_buf_get_lines(dashboard.buf, 0, -1, false), "\n")
    :match("3 files") ~= nil
end)
dashboard:close()
-- === end ep-explore wave ===

-- === compat wave: winborder, winblend, laststatus=3, splitkeep, motion on ===
-- Each of these is a user setting the plugin has to be immune to. Neovim
-- applies `winborder` and `winblend` to any float that does not name its own,
-- so the assertion is that every float still names both.
local source_win = vim.api.nvim_get_current_win()
local has_winborder = vim.fn.exists("&winborder") == 1
if has_winborder then
  vim.o.winborder = "double"
end
vim.o.winblend = 40

local peeked = require("epicenter.ui.panel").peek({
  path = vim.fs.joinpath(root, "app/server.lua"),
  line = 9,
})
local peek_border = vim.api.nvim_win_get_config(peeked.win.win).border
check(
  "a float keeps its own border under &winborder=double",
  peek_border == "rounded" or (type(peek_border) == "table" and peek_border[1] == "\226\149\173"),
  has_winborder and vim.inspect(peek_border) or "&winborder absent on this Neovim"
)
check(
  "a float keeps its own winblend under &winblend=40",
  vim.wo[peeked.win.win].winblend == 0,
  tostring(vim.wo[peeked.win.win].winblend)
)
peeked:close()
wait_for("peek closed", function()
  return not peeked:valid()
end, 3000)
vim.o.winblend = 0
if has_winborder then
  vim.o.winborder = ""
end
vim.api.nvim_set_current_win(source_win)

-- laststatus=3 puts one statusline at the bottom of the whole editor. The
-- palette's grid already reserves that row; what it must never do is paint
-- over it.
vim.o.laststatus = 3
local global_bar = require("epicenter").run("search", {}, buf)
wait_for("laststatus=3 open animation settled", function()
  return global_bar.tween == nil
end, 3000)
local global_box = global_bar:_box()
check(
  "laststatus=3 lays the palette out on the same grid",
  vim.deep_equal(
    global_bar.results_win:geometry(),
    require("epicenter.ui.palette").layout(global_box, true).results
  )
)
local usable_rows = vim.o.lines - vim.o.cmdheight - 1
check(
  "the palette never reaches the global statusline",
  global_box.row + global_box.height + 1 <= usable_rows,
  ("bottom row %d of %d"):format(global_box.row + global_box.height + 1, usable_rows)
)
global_bar:close({ motion = false })
wait_for("laststatus=3 palette closed", function()
  return not global_bar.results_win:valid()
end, 3000)
vim.o.laststatus = 2

-- splitkeep governs what happens to a window's view when a horizontal split
-- changes its height. Every epicenter surface is a float or a vertical split,
-- so whatever the user set, the source window's view must not move. The
-- screen is shrunk here so the fixture is actually longer than the window.
local saved_lines = vim.o.lines
vim.o.lines = 12
vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
local split_buf = vim.api.nvim_get_current_buf()
local split_win = vim.api.nvim_get_current_win()

for _, keep in ipairs({ "cursor", "screen", "topline" }) do
  vim.o.splitkeep = keep
  for _, blast_layout in ipairs({ "float", "vsplit" }) do
    require("epicenter").setup({ ui = { icons = "ascii" }, blast = { layout = blast_layout } })
    vim.api.nvim_set_current_win(split_win)
    vim.api.nvim_win_set_cursor(split_win, { 18, 0 })
    vim.cmd("normal! zz")
    local before_top = vim.fn.line("w0", split_win)
    local label = ("splitkeep=%s, %s layout"):format(keep, blast_layout)
    check(label .. ": the source window starts scrolled", before_top > 1, "w0 " .. before_top)

    local blast = require("epicenter").run("blast", { "M.handle_request" }, split_buf)
    wait_for(label .. ": blast answered", function()
      return blast.answered > 0
    end, 10000)
    local after_top = vim.fn.line("w0", split_win)
    check(
      label .. ": source view unmoved",
      after_top == before_top and vim.deep_equal(vim.api.nvim_win_get_cursor(split_win), { 18, 0 }),
      ("first line %d -> %d"):format(before_top, after_top)
    )

    blast:close()
    -- `valid()` goes false the moment the close starts; the float's fade-out
    -- still owns a real window (and the focus) for another frame.
    wait_for(label .. ": panel window gone", function()
      return #vim.api.nvim_list_wins() == 1
    end, 5000)
  end
end
vim.o.splitkeep = "cursor"
vim.o.lines = saved_lines
require("epicenter").setup({ ui = { icons = "ascii" } })
-- === end compat wave ===

-- === outline sidebar: a real split, so it goes last (see the note above) ===
local outline = require("epicenter").run("outline", {}, source)
wait_for("outline listed the buffer's symbols", function()
  return outline.list:count() >= 3
end)
-- F8: a real window on the left, not a float painted over the source. The
-- source keeps every column it still owns.
local outline_win = outline.win.win
local source_win_before = vim.fn.bufwinid(source)
check("the sidebar is a real window", vim.api.nvim_win_get_config(outline_win).relative == "")
check(
  "the winbar carries its title",
  vim.wo[outline_win].winbar:match("outline: server%.lua") ~= nil,
  vim.wo[outline_win].winbar
)
check("the sidebar is anchored on the left", vim.api.nvim_win_get_position(outline_win)[2] == 0)
check(
  "the source starts right of it",
  vim.api.nvim_win_get_position(source_win_before)[2] > vim.api.nvim_win_get_width(outline_win)
)
check(
  "nothing of the file is hidden",
  vim.api.nvim_win_get_width(outline_win) + 1 + vim.api.nvim_win_get_width(source_win_before)
    == vim.o.columns
)
outline:close()
check(
  "closing it gives the columns back",
  vim.api.nvim_win_get_position(vim.fn.bufwinid(source))[2] == 0
)

local messages = vim.api.nvim_exec2("messages", { output = true }).output
local bad = {}
for _, line in ipairs(vim.split(messages, "\n", { plain = true })) do
  if line:match("^E%d+") or line:match("[Ee]rror") then
    table.insert(bad, line)
  end
end
check("no errors in :messages", #bad == 0, #bad > 0 and bad[1] or "clean")

support.stop_fake(root)
io.write(("\n%d checks, %d failed\n"):format(checks, failures))
io.stdout:flush()
os.exit(failures == 0 and 0 or 1)

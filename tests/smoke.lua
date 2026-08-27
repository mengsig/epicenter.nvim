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
  "callers",
  "callees",
  "outline",
  "hot",
  "diff",
  "path",
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

-- Dependency-free test harness: describe/it, assertions with readable diffs,
-- per-file module isolation, non-zero exit on failure.
local M = {}

local state = {
  suites = {},
  stack = {},
  results = {},
}

local function current()
  return state.stack[#state.stack]
end

function M.describe(name, fn)
  local suite = {
    name = name,
    parent = current(),
    before = {},
    after = {},
  }
  table.insert(state.stack, suite)
  local ok, err = pcall(fn)
  table.remove(state.stack)
  if not ok then
    error(("describe(%q) failed to load: %s"):format(name, err), 0)
  end
end

local function full_name(name)
  local parts = { name }
  for i = #state.stack, 1, -1 do
    table.insert(parts, 1, state.stack[i].name)
  end
  return table.concat(parts, " > ")
end

local function hooks(kind)
  local out = {}
  for _, suite in ipairs(state.stack) do
    for _, fn in ipairs(suite[kind]) do
      table.insert(out, fn)
    end
  end
  return out
end

function M.before_each(fn)
  local suite = current()
  assert(suite, "before_each outside describe")
  table.insert(suite.before, fn)
end

function M.after_each(fn)
  local suite = current()
  assert(suite, "after_each outside describe")
  table.insert(suite.after, fn)
end

local function traceback(err)
  return debug.traceback(tostring(err), 3)
end

function M.it(name, fn)
  local case = { name = full_name(name), file = state.file }
  local before, after = hooks("before"), hooks("after")

  local ok, err = true, nil
  for _, hook in ipairs(before) do
    ok, err = xpcall(hook, traceback)
    if not ok then
      break
    end
  end
  if ok then
    ok, err = xpcall(fn, traceback)
  end
  for _, hook in ipairs(after) do
    -- Cleanup always runs; a cleanup failure must not mask the real failure.
    local cok, cerr = xpcall(hook, traceback)
    if ok and not cok then
      ok, err = false, cerr
    end
  end

  case.ok = ok
  case.err = err
  table.insert(state.results, case)
end

-- Assertions -----------------------------------------------------------------

local function render(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  return vim.inspect(v)
end

local function diff(a, b)
  local la = vim.split(render(a), "\n", { plain = true })
  local lb = vim.split(render(b), "\n", { plain = true })
  if #la == 1 and #lb == 1 then
    return ("expected: %s\n  actual: %s"):format(lb[1], la[1])
  end
  local out = { "expected (-) vs actual (+):" }
  for i = 1, math.max(#la, #lb) do
    local x, y = la[i], lb[i]
    if x == y then
      table.insert(out, "   " .. (x or ""))
    else
      if y ~= nil then
        table.insert(out, " - " .. y)
      end
      if x ~= nil then
        table.insert(out, " + " .. x)
      end
    end
  end
  return table.concat(out, "\n")
end

local expect = {}

function expect.eq(actual, want, msg)
  if not vim.deep_equal(actual, want) then
    error((msg and (msg .. "\n") or "") .. diff(actual, want), 2)
  end
end

function expect.ne(actual, want, msg)
  if vim.deep_equal(actual, want) then
    error((msg or "values are equal but should differ") .. ": " .. render(actual), 2)
  end
end

function expect.truthy(v, msg)
  if not v then
    error(msg or ("expected truthy, got " .. render(v)), 2)
  end
end

function expect.falsy(v, msg)
  if v then
    error(msg or ("expected falsy, got " .. render(v)), 2)
  end
end

function expect.near(actual, want, eps, msg)
  eps = eps or 1e-6
  if type(actual) ~= "number" or math.abs(actual - want) > eps then
    error(
      (msg and (msg .. "\n") or "")
        .. ("expected %s +/- %s, got %s"):format(want, eps, render(actual)),
      2
    )
  end
end

function expect.matches(s, pattern, msg)
  if type(s) ~= "string" or not s:match(pattern) then
    error(
      (msg and (msg .. "\n") or "") .. ("expected %s to match %q"):format(render(s), pattern),
      2
    )
  end
end

--- Asserts fn errors, and that the message matches pattern when given.
function expect.errors(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    error(msg or "expected an error, call succeeded", 2)
  end
  if pattern and not tostring(err):match(pattern) then
    error(
      (msg and (msg .. "\n") or "") .. ("error %q does not match %q"):format(tostring(err), pattern),
      2
    )
  end
  return err
end

M.expect = expect

--- Blocks until pred() is truthy. Returns the predicate's value.
--- Fails the test on timeout so an async hang never reads as a pass.
function M.wait(pred, timeout_ms, label)
  timeout_ms = timeout_ms or 5000
  local value
  local ok = vim.wait(timeout_ms, function()
    value = pred()
    return value ~= nil and value ~= false
  end, 5)
  if not ok then
    error(("timed out after %dms waiting for %s"):format(timeout_ms, label or "condition"), 2)
  end
  return value
end

-- Runner ---------------------------------------------------------------------

--- Per-file isolation: a spec file starts with no epicenter module loaded, no
--- language server running and no floating window left over. Without this a
--- leaked server from one file blocks the event loop in the next.
local function isolate()
  -- Route through epicenter.client first: a raw client:stop() below never
  -- sets its state.stopping, so its on_exit reads the stop as a crash and
  -- schedule_restart respawns a zombie server the next file never sees.
  local ok, client_mod = pcall(require, "epicenter.client")
  if ok then
    client_mod.stop_all()
  end

  -- Graceful stop, never force: the fake server blocks on a stdin read, so a
  -- SIGTERM only lands once it returns. shutdown/exit over stdio does land -
  -- and on 0.10 `client:stop()` would pass the client itself as `force`.
  for _, client in ipairs(vim.lsp.get_clients()) do
    require("epicenter.compat").lsp_stop(client)
  end
  vim.wait(5000, function()
    return #vim.lsp.get_clients() == 0
  end, 10)

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for name in pairs(package.loaded) do
    if
      name == "epicenter"
      or name:match("^epicenter%.")
      or name == "fake"
      or name:match("^fake%.")
    then
      package.loaded[name] = nil
    end
  end
end

--- Runs each spec file in module-isolation. Returns passed, failed, results.
function M.run(files)
  for _, file in ipairs(files) do
    isolate()
    state.stack = {}
    state.file = file
    local chunk, load_err = loadfile(file)
    if not chunk then
      table.insert(state.results, { name = file, ok = false, err = load_err, file = file })
    else
      local ok, err = xpcall(chunk, traceback)
      if not ok then
        table.insert(
          state.results,
          { name = file .. " (load)", ok = false, err = err, file = file }
        )
      end
    end
  end

  local passed, failed = 0, 0
  for _, case in ipairs(state.results) do
    if case.ok then
      passed = passed + 1
    else
      failed = failed + 1
    end
  end
  return passed, failed, state.results
end

--- Prints the failures and the one-line tally, and returns the exit code.
--- Shared by both lanes' runners so their output is identical.
--- @return integer exit_code
function M.report(passed, failed, results, file_count, elapsed_ms)
  local out = {}
  local function w(fmt, ...)
    table.insert(out, select("#", ...) > 0 and fmt:format(...) or fmt)
  end

  for _, case in ipairs(results) do
    if not case.ok then
      w("FAIL  %s", case.name)
      for _, line in ipairs(vim.split(tostring(case.err), "\n", { plain = true })) do
        w("      %s", line)
      end
      w("")
    end
  end

  w("%d passed, %d failed  (%d files, %.0fms)", passed, failed, file_count, elapsed_ms)
  io.write(table.concat(out, "\n"), "\n")
  io.stdout:flush()
  return failed == 0 and 0 or 1
end

--- Installs the DSL as globals for spec files.
function M.install_globals()
  _G.describe = M.describe
  _G.it = M.it
  _G.before_each = M.before_each
  _G.after_each = M.after_each
  _G.expect = M.expect
  _G.wait = M.wait
end

return M

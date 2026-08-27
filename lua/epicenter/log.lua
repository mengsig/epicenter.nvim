--- Leveled file logger. Standalone: never requires other epicenter modules, so
--- any module may log during its own initialization.
local M = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }

local state = {
  level = LEVELS.warn,
  path = nil,
  handle = nil,
  open_failed = false,
}

function M.levels()
  return vim.tbl_keys(LEVELS)
end

local function default_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "epicenter.log")
end

--- Resolved log file path (creation is lazy, on first write).
function M.path()
  return state.path or default_path()
end

--- @param opts { level?: string, file?: string }
function M.configure(opts)
  opts = opts or {}
  if opts.level then
    local n = LEVELS[opts.level]
    if not n then
      error(("epicenter.log: unknown level %q"):format(opts.level))
    end
    state.level = n
  end
  if opts.file ~= state.path then
    M.close()
    state.path = opts.file
    state.open_failed = false
  end
end

function M.close()
  if state.handle then
    state.handle:close()
    state.handle = nil
  end
end

local function handle()
  if state.handle then
    return state.handle
  end
  if state.open_failed then
    return nil
  end
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fh, err = io.open(path, "a")
  if not fh then
    -- One loud notice, then stay quiet: a broken log must not spam the editor.
    state.open_failed = true
    vim.schedule(function()
      vim.notify(("epicenter: cannot open log %s: %s"):format(path, err), vim.log.levels.WARN)
    end)
    return nil
  end
  state.handle = fh
  return fh
end

local function write(level, msg, ...)
  if LEVELS[level] > state.level then
    return
  end
  local fh = handle()
  if not fh then
    return
  end
  local text = select("#", ...) > 0 and msg:format(...) or msg
  fh:write(("%s [%s] %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), level, text))
  fh:flush()
end

for level in pairs(LEVELS) do
  M[level] = function(msg, ...)
    write(level, msg, ...)
  end
end

return M

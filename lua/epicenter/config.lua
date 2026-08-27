--- Defaults, merge and validation. Unknown keys and wrong types are hard
--- errors at `setup()` time - a silently ignored option is a bug you find
--- months later.
local M = {}

local registry = require("epicenter.registry")

--- Base defaults. Feature-owned option tables are merged in by `M.defaults()`.
local BASE = {
  navgraph = {
    --- Explicit binary path; otherwise `$PATH`, then the managed install.
    path = nil,
    --- Extra arguments appended to `navgraph lsp`.
    args = {},
    --- GitHub repo used by `:Epicenter install`.
    repo = "mengsig/NavGraph",
    --- Git ref to build from when falling back to a source build.
    install_ref = nil,
  },
  lsp = {
    auto_start = true,
    --- Checked in order at each directory level walking upward.
    root_markers = { ".navgraph", ".git" },
    --- When true, navgraph's definition/references/hover/documentSymbol are
    --- hidden on buffers that already have another client offering them.
    fallback_only = true,
    --- Passed verbatim as LSP `initializationOptions`.
    init_options = {
      tests = "with",
      strict = false,
      debounceMs = 120,
      watch = true,
      watchIntervalMs = 2000,
      depth = 3,
    },
    restart = {
      max = 3,
      backoff_ms = { 500, 2000, 5000 },
    },
  },
  ui = {
    border = "rounded",
    --- Fractions of the editor when <= 1, absolute cells when > 1.
    width = 0.8,
    height = 0.8,
    max_width = 120,
    max_height = 30,
    winblend = 0,
    --- "auto" picks nerd glyphs when `vim.g.have_nerd_font` is set.
    icons = "auto",
    preview = true,
  },
  --- Master motion switch; `vim.g.epicenter_reduce_motion` overrides it.
  animate = true,
  animation = {
    open_ms = 120,
    close_ms = 90,
    stagger_ms = 8,
    fps = 60,
    --- A frame costing more than this skips the next tick.
    frame_budget_ms = 8,
  },
  --- Overrides for derived `Epicenter*` groups, e.g. `{ EpicenterAccent = { fg = "#7aa2f7" } }`.
  highlights = {},
  --- `false` installs no keymaps.
  keymaps = {
    prefix = "<leader>e",
  },
  log = {
    level = "warn",
    --- Defaults to `stdpath("state")/epicenter.log`.
    file = nil,
  },
}

--- Paths whose default is nil or which accept more than one type.
local VARIANTS = {
  ["navgraph.path"] = { "string" },
  ["navgraph.install_ref"] = { "string" },
  ["log.file"] = { "string" },
  ["keymaps"] = { "table", "boolean" },
  ["ui.border"] = { "string", "table" },
}

--- Subtrees copied wholesale, with no key checking.
local FREE_FORM = { highlights = true }

local ENUMS = {
  ["ui.icons"] = { "auto", "nerd", "ascii" },
  ["log.level"] = { "error", "warn", "info", "debug", "trace" },
  ["lsp.init_options.tests"] = { "with", "without", "only" },
}

local POSITIVE = {
  ["ui.max_width"] = true,
  ["ui.max_height"] = true,
  ["animation.open_ms"] = true,
  ["animation.close_ms"] = true,
  ["animation.fps"] = true,
  ["animation.frame_budget_ms"] = true,
  ["lsp.init_options.debounceMs"] = true,
  ["lsp.init_options.watchIntervalMs"] = true,
  ["lsp.init_options.depth"] = true,
}

local FRACTION = { ["ui.width"] = true, ["ui.height"] = true }

--- A boolean here is only ever meaningful as `false`; `true` would silently
--- mean "the default table", which install_keymaps never does.
local FALSE_ONLY = { ["keymaps"] = true }

local function fail(fmt, ...)
  error("epicenter.setup: " .. fmt:format(...), 0)
end

local function join(prefix, key)
  return prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
end

local function check_value(path, value)
  local enum = ENUMS[path]
  if enum and not vim.tbl_contains(enum, value) then
    fail("%s must be one of %s, got %q", path, table.concat(enum, ", "), tostring(value))
  end
  if POSITIVE[path] and (type(value) ~= "number" or value <= 0) then
    fail("%s must be a positive number, got %s", path, tostring(value))
  end
  if FRACTION[path] and (type(value) ~= "number" or value <= 0) then
    fail("%s must be > 0 (a fraction of the editor, or absolute cells when > 1)", path)
  end
  if FALSE_ONLY[path] and type(value) == "boolean" and value ~= false then
    fail("%s must be a table or `false`, got true", path)
  end
end

local function merge(defaults, opts, prefix)
  local out = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    local path = join(prefix, key)
    local allowed = VARIANTS[path]
    local default = defaults[key]

    if not allowed then
      if default == nil then
        local known = vim.tbl_keys(defaults)
        table.sort(known)
        fail("unknown option %q (known here: %s)", path, table.concat(known, ", "))
      end
      allowed = { type(default) }
    end

    if not vim.tbl_contains(allowed, type(value)) then
      fail("%s must be %s, got %s", path, table.concat(allowed, " or "), type(value))
    end

    check_value(path, value)

    if FREE_FORM[key] and prefix == "" then
      out[key] = vim.deepcopy(value)
    elseif type(value) == "table" and type(default) == "table" and not vim.islist(default) then
      out[key] = merge(default, value, path)
    else
      out[key] = vim.deepcopy(value)
    end
  end
  return out
end

--- Full default table, including every feature's own options.
function M.defaults()
  local out = vim.deepcopy(BASE)
  for key, value in pairs(registry.options()) do
    if out[key] ~= nil then
      error(("epicenter: feature option %q collides with a core option"):format(key), 0)
    end
    out[key] = value
  end
  return out
end

local current = nil

--- @param opts? table user options
--- @return table resolved config
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    fail("expected a table, got %s", type(opts))
  end
  current = merge(M.defaults(), opts, "")
  require("epicenter.log").configure(current.log)
  return current
end

--- Resolved config; defaults apply when `setup()` was never called.
function M.get()
  if not current then
    current = M.defaults()
  end
  return current
end

--- True when motion is enabled for this session.
function M.motion_enabled()
  if vim.g.epicenter_reduce_motion then
    return false
  end
  return M.get().animate == true
end

--- Test seam: forgets any `setup()` call.
function M.reset()
  current = nil
end

return M

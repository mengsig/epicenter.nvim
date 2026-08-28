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

--- Options whose default is nil, and so are absent from BASE. Named here so
--- the generated config reference can still list them.
M.OPTIONAL_PATHS = { "log.file", "navgraph.install_ref", "navgraph.path" }

--- One line per core option path, for the generated config reference. Feature
--- options carry their own `option_docs`; `epicenter.registry` merges them.
--- The long-form reference is `doc/epicenter.txt`; these are the margin notes.
local DOCS = {
  ["animate"] = "master switch; vim.g.epicenter_reduce_motion wins",
  ["animation.frame_budget_ms"] = "a frame costing more than this drops the next one",
  ["highlights"] = 'e.g. { EpicenterAccent = { fg = "#7aa2f7" } }',
  ["keymaps"] = "or false, to install none",
  ["log"] = 'file defaults to stdpath("state")/epicenter.log',
  ["lsp.fallback_only"] = "yield definition/references/hover to another server",
  ["lsp.init_options"] = "passed verbatim as LSP initializationOptions",
  ["lsp.root_markers"] = "checked in order at each level, walking upward",
  ["lsp.init_options.tests"] = '"with" | "without" | "only"',
  ["navgraph.args"] = "extra arguments appended to `navgraph lsp`",
  ["navgraph.install_ref"] = "git ref to build from, on the source route",
  ["navgraph.path"] = "explicit path; else $PATH, then the managed install",
  ["navgraph.repo"] = "source for :Epicenter install",
  ["ui.height"] = "fraction of the editor when <= 1, else cells",
  ["ui.icons"] = '"auto" | "nerd" | "ascii"',
  ["ui.width"] = "fraction of the editor when <= 1, else cells",
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

--- Subtrees that pass an option unknown to their own defaults straight
--- through, e.g. a newer navgraph's init_options key this plugin does not
--- know about yet - a documented option still gets its own validation.
local ALLOW_UNKNOWN = { ["lsp.init_options"] = true }

local ENUMS = {
  ["ui.icons"] = { "auto", "nerd", "ascii" },
  ["log.level"] = { "error", "warn", "info", "debug", "trace" },
  ["lsp.init_options.tests"] = { "with", "without", "only" },
  --- Only the string shorthand is enumerated; a table border spec (custom
  --- per-side chars) is free-form, checked only by `nvim_open_win` itself.
  ["ui.border"] = { "none", "single", "double", "rounded", "solid", "shadow" },
}

--- Strings that must not be empty: an empty keymaps.prefix installs bare
--- normal-mode maps (`s`, `g`, ...), clobbering unrelated motions.
local NONEMPTY_STRING = { ["keymaps.prefix"] = true }

local POSITIVE = {
  ["ui.max_width"] = true,
  ["ui.max_height"] = true,
  ["animation.open_ms"] = true,
  ["animation.close_ms"] = true,
  ["animation.stagger_ms"] = true,
  ["animation.fps"] = true,
  ["animation.frame_budget_ms"] = true,
  ["lsp.init_options.debounceMs"] = true,
  ["lsp.init_options.watchIntervalMs"] = true,
  ["lsp.init_options.depth"] = true,
  ["lsp.restart.max"] = true,
  ["search.debounce_ms"] = true,
  ["search.limit"] = true,
  ["grep.debounce_ms"] = true,
  ["grep.limit"] = true,
}

local FRACTION = { ["ui.width"] = true, ["ui.height"] = true }

--- Inclusive numeric ranges, checked after POSITIVE/FRACTION so a value can
--- be positive and still out of range (e.g. winblend > 100).
local RANGE = {
  ["ui.winblend"] = { 0, 100 },
}

--- A boolean here is only ever meaningful as `false`; `true` would silently
--- mean "the default table", which install_keymaps never does.
local FALSE_ONLY = { ["keymaps"] = true }

--- Lists that must not be replaced with an empty table: an empty
--- backoff_ms leaves the crash-recovery path with no delay to index into.
local LIST_NONEMPTY_NUMBERS = { ["lsp.restart.backoff_ms"] = true }

--- Lists whose elements must be strings; unlike backoff_ms these may be
--- empty (an empty argv extension is the default).
local LIST_STRINGS = { ["navgraph.args"] = true }

local function fail(fmt, ...)
  error("epicenter.setup: " .. fmt:format(...), 0)
end

local function join(prefix, key)
  return prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
end

--- Core rules plus the ones features declared for their own options.
--- @return { variants: table, enums: table, positive: table }
local function rules()
  local extra = registry.option_rules()
  return {
    variants = vim.tbl_extend("force", VARIANTS, extra.variants),
    enums = vim.tbl_extend("force", ENUMS, extra.enums),
    positive = vim.tbl_extend("force", POSITIVE, extra.positive),
  }
end

local function readable(values)
  return table.concat(
    vim.tbl_map(function(v)
      return tostring(v)
    end, values),
    ", "
  )
end

local function check_value(rule, path, value)
  local enum = rule.enums[path]
  if enum and type(value) == "string" and not vim.tbl_contains(enum, value) then
    fail("%s must be one of %s, got %s", path, readable(enum), tostring(value))
  end
  if NONEMPTY_STRING[path] and value == "" then
    fail("%s must not be empty", path)
  end
  if LIST_STRINGS[path] then
    for _, element in ipairs(value) do
      if type(element) ~= "string" then
        fail("%s must be a list of strings, got a %s element", path, type(element))
      end
    end
  end
  if rule.positive[path] and (type(value) ~= "number" or value <= 0) then
    fail("%s must be a positive number, got %s", path, tostring(value))
  end
  if FRACTION[path] and (type(value) ~= "number" or value <= 0) then
    fail("%s must be > 0 (a fraction of the editor, or absolute cells when > 1)", path)
  end
  local range = RANGE[path]
  if range and (type(value) ~= "number" or value < range[1] or value > range[2]) then
    fail("%s must be between %d and %d, got %s", path, range[1], range[2], tostring(value))
  end
  if FALSE_ONLY[path] and type(value) == "boolean" and value ~= false then
    fail("%s must be a table or `false`, got true", path)
  end
  if LIST_NONEMPTY_NUMBERS[path] then
    if type(value) ~= "table" or #value == 0 then
      fail("%s must be a non-empty list of numbers", path)
    end
    for _, n in ipairs(value) do
      if type(n) ~= "number" or n <= 0 then
        fail("%s must be a non-empty list of positive numbers, got %s", path, tostring(n))
      end
    end
  end
end

local function merge(defaults, opts, prefix, rule, allow_unknown)
  local out = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    local path = join(prefix, key)
    local allowed = rule.variants[path]
    local default = defaults[key]

    if not allowed and default == nil and allow_unknown then
      -- Unrecognised, but this subtree passes it through verbatim (F6).
      out[key] = vim.deepcopy(value)
    else
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

      check_value(rule, path, value)

      if FREE_FORM[key] and prefix == "" then
        out[key] = vim.deepcopy(value)
      elseif type(value) == "table" and type(default) == "table" and not vim.islist(default) then
        out[key] = merge(default, value, path, rule, ALLOW_UNKNOWN[path])
      else
        out[key] = vim.deepcopy(value)
      end
    end
  end
  return out
end

--- One-line documentation per option path: the core ones above plus every
--- feature's own. Drives the generated config reference.
--- @return table<string, string>
function M.option_docs()
  return vim.tbl_extend("force", DOCS, registry.option_docs())
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
  current = merge(M.defaults(), opts, "", rules())
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

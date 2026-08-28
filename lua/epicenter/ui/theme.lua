--- `Epicenter*` highlight groups derived from the active colourscheme, so the
--- plugin inherits any theme instead of shipping its own palette. Re-derived on
--- `ColorScheme`; every group overridable via `config.highlights`.
local M = {}

--- Colourscheme groups the derivation reads.
M.SOURCES = {
  "Normal",
  "NormalFloat",
  "FloatBorder",
  "Comment",
  "Title",
  "Function",
  "Special",
  "DiagnosticInfo",
}

--- Groups this plugin defines. Order is stable for docs and tests.
M.GROUPS = {
  "EpicenterNormal",
  "EpicenterBorder",
  "EpicenterTitle",
  "EpicenterAccent",
  "EpicenterMatch",
  "EpicenterMuted",
  "EpicenterCount",
  "EpicenterInfo",
  "EpicenterSelection",
  "EpicenterPrompt",
  "EpicenterHint",
  "EpicenterRange",
}

--- Mixes two 24-bit colours. `alpha` is the weight of `fg`.
--- @param fg integer|nil
--- @param bg integer|nil
--- @param alpha number 0..1
--- @return integer|nil
function M.blend(fg, bg, alpha)
  if not fg or not bg then
    return fg or bg
  end
  local function channel(shift)
    local a = math.floor(fg / shift) % 256
    local b = math.floor(bg / shift) % 256
    return math.floor(b + (a - b) * alpha + 0.5)
  end
  return channel(65536) * 65536 + channel(256) * 256 + channel(1)
end

local function pick(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v ~= nil then
      return v
    end
  end
  return nil
end

--- `config.theme.accent`: "auto" derives it from the colourscheme (today's
--- behaviour); "mono" drops the extra hue entirely - one palette, the
--- calmest option; anything else is a literal `#rrggbb` or the name of a
--- highlight group to borrow `fg` from.
--- @param accent string|nil
--- @param attr fun(group: string, key: string): any
--- @param fg integer|nil
--- @param muted integer|nil
--- @return integer|nil
local function resolve_accent(accent, attr, fg, muted)
  if accent == nil or accent == "auto" then
    return pick(attr("Function", "fg"), attr("Title", "fg"), fg)
  end
  if accent == "mono" then
    return muted
  end
  local hex = accent:match("^#(%x%x%x%x%x%x)$")
  if hex then
    return tonumber(hex, 16)
  end
  local hl = vim.api.nvim_get_hl(0, { name = accent, link = false })
  return pick(hl.fg, fg)
end

--- Pure derivation, so the colour maths is testable without a UI.
--- @param src table<string, table> attrs keyed by the names in M.SOURCES
--- @param overrides? table<string, table>
--- @param accent? string see `resolve_accent`
--- @return table<string, table> attrs keyed by the names in M.GROUPS
function M.derive(src, overrides, accent)
  src = src or {}
  local function attr(group, key)
    local hl = src[group]
    return hl and hl[key] or nil
  end

  local bg = pick(attr("NormalFloat", "bg"), attr("Normal", "bg"))
  local fg = pick(attr("NormalFloat", "fg"), attr("Normal", "fg"))
  local muted = pick(attr("Comment", "fg"), fg)
  local resolved_accent = resolve_accent(accent, attr, fg, muted)

  local out = {
    EpicenterNormal = { fg = fg, bg = bg },
    EpicenterBorder = { fg = pick(attr("FloatBorder", "fg"), muted), bg = bg },
    EpicenterTitle = { fg = pick(attr("Title", "fg"), fg), bg = bg, bold = true },
    EpicenterAccent = { fg = resolved_accent, bg = bg },
    EpicenterMatch = { fg = resolved_accent, bg = bg, bold = true },
    EpicenterMuted = { fg = muted, bg = bg },
    EpicenterCount = { fg = pick(attr("Special", "fg"), muted), bg = bg },
    EpicenterInfo = { fg = pick(attr("DiagnosticInfo", "fg"), muted), bg = bg },
    EpicenterSelection = { fg = fg, bg = M.blend(resolved_accent, bg, 0.16), bold = true },
    EpicenterPrompt = { fg = resolved_accent, bg = bg },
    EpicenterHint = { fg = muted, bg = bg, italic = true },
    EpicenterRange = { bg = M.blend(resolved_accent, bg, 0.22) },
  }

  for group, override in pairs(overrides or {}) do
    out[group] = vim.tbl_extend("force", out[group] or {}, override)
  end
  return out
end

local function read_sources()
  local src = {}
  for _, name in ipairs(M.SOURCES) do
    src[name] = vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  return src
end

--- Derives from the live colourscheme and defines the groups.
function M.apply()
  local cfg = require("epicenter.config").get()
  for group, attrs in pairs(M.derive(read_sources(), cfg.highlights, cfg.theme.accent)) do
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

local group = nil

--- Applies now and re-applies on every `ColorScheme`.
function M.setup()
  M.apply()
  group = group or vim.api.nvim_create_augroup("EpicenterTheme", { clear = true })
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      M.apply()
    end,
  })
end

return M

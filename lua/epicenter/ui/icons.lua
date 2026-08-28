--- Nerd-font glyphs with a plain-ASCII fallback. One accessor, so no module
--- hard-codes a glyph.
local M = {}

local NERD = {
  kinds = {
    fn = "󰊕",
    ["function"] = "󰊕",
    method = "󰆧",
    struct = "󰙅",
    class = "󰠱",
    type = "󰊄",
    enum = "",
    interface = "",
    const = "󰏿",
    var = "󰀫",
    field = "󰜢",
    module = "",
    test = "󰙨",
    file = "󰈔",
    dir = "󰉋",
    unknown = "󰘦",
  },
  ui = {
    search = "",
    prompt = "",
    fan_in = "",
    fan_out = "",
    collapsed = "",
    expanded = "",
    dot = "",
    ok = "",
    warn = "",
    err = "",
    chain = "│",
    chain_end = "▼",
    marked = "●",
    impact = "⌁",
    progress_full = "█",
    progress_empty = "░",
  },
}

local ASCII = {
  kinds = {
    fn = "fn",
    ["function"] = "fn",
    method = "me",
    struct = "st",
    class = "cl",
    type = "ty",
    enum = "en",
    interface = "in",
    const = "co",
    var = "va",
    field = "fi",
    module = "mo",
    test = "te",
    file = "f",
    dir = "d",
    unknown = "?",
  },
  ui = {
    search = ">",
    prompt = ">",
    fan_in = "<-",
    fan_out = "->",
    collapsed = ">",
    expanded = "v",
    dot = "*",
    ok = "+",
    warn = "!",
    err = "x",
    chain = "|",
    chain_end = "v",
    marked = "*",
    impact = "!",
    progress_full = "#",
    progress_empty = "-",
  },
}

--- @param mode "auto"|"nerd"|"ascii"
--- @return table
function M.set(mode)
  if mode == "nerd" then
    return NERD
  end
  if mode == "ascii" then
    return ASCII
  end
  return vim.g.have_nerd_font and NERD or ASCII
end

--- Icon set selected by config.
function M.get()
  return M.set(require("epicenter.config").get().ui.icons)
end

--- Glyph for a navgraph symbol kind, falling back to the unknown glyph.
--- @param kind string|nil
function M.kind(kind)
  local set = M.get().kinds
  return set[kind or "unknown"] or set.unknown
end

--- @param name string
function M.ui(name)
  local set = M.get().ui
  return assert(set[name], "unknown ui icon: " .. tostring(name))
end

M.nerd = NERD
M.ascii = ASCII

return M

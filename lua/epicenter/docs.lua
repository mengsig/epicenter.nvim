--- The registry, rendered. `make docs-check` compares these tables against the
--- marked regions in `README.md` and `doc/epicenter.txt`, so the keymap table,
--- the command table and the defaults block cannot drift from the code.
---
--- Nothing requires this at startup; it loads only when something asks for a
--- rendering.
local M = {}

local config = require("epicenter.config")
local registry = require("epicenter.registry")

--- Widest table that still reads well on one line.
local INLINE_MAX_KEYS = 3
local INLINE_MAX_WIDTH = 60

--- Stands in for an option whose default is nil: absent from the defaults
--- table, but part of the reference.
local NONE = setmetatable({}, {
  __tostring = function()
    return "nil"
  end,
})

-- The rows ---------------------------------------------------------------------

--- @return { lhs: string, command: string, desc: string }[]
function M.keymap_rows()
  local prefix = config.defaults().keymaps.prefix
  local rows = {}
  for _, map in ipairs(registry.keymaps()) do
    table.insert(rows, {
      lhs = prefix .. map.suffix,
      command = map.command,
      desc = registry.command(map.command).desc,
    })
  end
  return rows
end

--- @return { name: string, feature: string, desc: string, status: string }[]
function M.command_rows()
  local rows = {}
  for _, cmd in ipairs(registry.commands()) do
    table.insert(rows, {
      name = cmd.name,
      feature = cmd.feature,
      desc = cmd.desc,
      status = cmd.status,
    })
  end
  return rows
end

-- Values -----------------------------------------------------------------------

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  return keys
end

local function scalar(value)
  if value == NONE then
    return "nil"
  end
  if type(value) == "string" then
    return ("%q"):format(value)
  end
  if type(value) == "number" then
    -- 0.8 must not render as 0.80000000000000004, nor 120 as 120.0.
    return value == math.floor(value) and ("%d"):format(value) or tostring(value)
  end
  return tostring(value)
end

local function is_scalar_list(value)
  if value == NONE or type(value) ~= "table" or not vim.islist(value) then
    return false
  end
  for _, element in ipairs(value) do
    if type(element) == "table" then
      return false
    end
  end
  return true
end

local function inline(value)
  if value == NONE or type(value) ~= "table" then
    return scalar(value)
  end
  if is_scalar_list(value) then
    if #value == 0 then
      return "{}"
    end
    return "{ " .. table.concat(vim.tbl_map(scalar, value), ", ") .. " }"
  end
  local parts = {}
  for _, key in ipairs(sorted_keys(value)) do
    table.insert(parts, ("%s = %s"):format(key, inline(value[key])))
  end
  if #parts == 0 then
    return "{}"
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

--- A keyed table small enough to read on one line.
local function inlineable(value)
  if value == NONE or type(value) ~= "table" or vim.islist(value) then
    return true
  end
  local keys = sorted_keys(value)
  if #keys > INLINE_MAX_KEYS then
    return false
  end
  for _, key in ipairs(keys) do
    local child = value[key]
    if type(child) == "table" and not is_scalar_list(child) and not inlineable(child) then
      return false
    end
  end
  return #inline(value) <= INLINE_MAX_WIDTH
end

-- The defaults block ------------------------------------------------------------

--- The defaults, plus a `NONE` at every path whose default is nil - so the
--- reference lists an option that BASE cannot carry, and the inline/multiline
--- decision counts it like any other key.
local function documented_defaults()
  local tree = config.defaults()
  for _, path in ipairs(config.OPTIONAL_PATHS) do
    local parts = vim.split(path, ".", { plain = true })
    local at = tree
    for i = 1, #parts - 1 do
      at[parts[i]] = at[parts[i]] or {}
      at = at[parts[i]]
    end
    if at[parts[#parts]] == nil then
      at[parts[#parts]] = NONE
    end
  end
  return tree
end

--- Emits `key = value,` lines for one table.
--- @param out { code: string, doc: string|nil }[]
local function emit(out, value, path, indent, docs)
  for _, key in ipairs(sorted_keys(value)) do
    local child = value[key]
    local child_path = path == "" and key or (path .. "." .. key)
    if inlineable(child) then
      table.insert(
        out,
        { code = ("%s%s = %s,"):format(indent, key, inline(child)), doc = docs[child_path] }
      )
    else
      table.insert(out, { code = ("%s%s = {"):format(indent, key), doc = docs[child_path] })
      emit(out, child, child_path, indent .. "  ", docs)
      table.insert(out, { code = indent .. "},", doc = nil })
    end
  end
end

--- Every option and its default, alphabetical at every level, wrapped in
--- `open`/`close`. Comments are the one-line reference entries, aligned.
--- @param opts? { comments?: boolean, indent?: string, open?: string, close?: string }
--- @return string[] lines
function M.defaults_lines(opts)
  opts = opts or {}
  local indent = opts.indent or ""
  local docs = opts.comments and config.option_docs() or {}

  local rows = {}
  emit(rows, documented_defaults(), "", indent .. "  ", docs)

  local column = 0
  for _, row in ipairs(rows) do
    if row.doc then
      column = math.max(column, #row.code + 1)
    end
  end

  local lines = { indent .. (opts.open or "{") }
  for _, row in ipairs(rows) do
    if row.doc then
      table.insert(lines, ("%s%s-- %s"):format(row.code, (" "):rep(column - #row.code), row.doc))
    else
      table.insert(lines, row.code)
    end
  end
  table.insert(lines, indent .. (opts.close or "}"))
  return lines
end

-- Markdown ----------------------------------------------------------------------

local function markdown_table(headers, rows)
  local widths = vim.tbl_map(function(header)
    return #header
  end, headers)
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
      widths[i] = math.max(widths[i], #cell)
    end
  end

  local function line(cells, pad)
    local out = {}
    for i, cell in ipairs(cells) do
      table.insert(out, cell .. (pad or " "):rep(widths[i] - #cell))
    end
    return "| " .. table.concat(out, " | ") .. " |"
  end

  local rule = {}
  for i = 1, #headers do
    rule[i] = ("-"):rep(widths[i])
  end

  local lines = { line(headers), line(rule, "-") }
  for _, row in ipairs(rows) do
    table.insert(lines, line(row))
  end
  return lines
end

function M.markdown_keymaps()
  return markdown_table(
    { "Key", "Command", "Does" },
    vim.tbl_map(function(row)
      return { "`" .. row.lhs .. "`", ("`:Epicenter %s`"):format(row.command), row.desc }
    end, M.keymap_rows())
  )
end

function M.markdown_commands()
  return markdown_table(
    { "Subcommand", "Does" },
    vim.tbl_map(function(row)
      local desc = row.status == "planned" and (row.desc .. " (a later release)") or row.desc
      return { "`" .. row.name .. "`", desc }
    end, M.command_rows())
  )
end

function M.markdown_defaults()
  local lines = { "```lua" }
  vim.list_extend(
    lines,
    M.defaults_lines({
      comments = true,
      open = 'require("epicenter").setup({',
      close = "})",
    })
  )
  table.insert(lines, "```")
  return lines
end

-- Vimdoc -------------------------------------------------------------------------

local VIMDOC_INDENT = "    "

--- Pads `cells` into columns, each at least one space apart.
local function vimdoc_table(rows)
  local widths = {}
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
      widths[i] = math.max(widths[i] or 0, #cell)
    end
  end
  local lines = {}
  for _, row in ipairs(rows) do
    local out = {}
    for i, cell in ipairs(row) do
      table.insert(out, i == #row and cell or cell .. (" "):rep(widths[i] - #cell))
    end
    local text = VIMDOC_INDENT .. table.concat(out, "  ")
    table.insert(lines, (text:gsub("%s+$", "")))
  end
  return lines
end

function M.vimdoc_keymaps()
  return vimdoc_table(vim.tbl_map(function(row)
    return { row.lhs, ":Epicenter " .. row.command, row.desc }
  end, M.keymap_rows()))
end

function M.vimdoc_commands()
  return vimdoc_table(vim.tbl_map(function(row)
    local desc = row.status == "planned" and (row.desc .. " (a later release)") or row.desc
    return { row.name, ("|epicenter-%s|"):format(row.feature), desc }
  end, M.command_rows()))
end

function M.vimdoc_defaults()
  return M.defaults_lines({ indent = VIMDOC_INDENT })
end

--- Every generated region, by the name its marker carries.
--- @type table<string, table<string, fun(): string[]>>
M.REGIONS = {
  markdown = {
    keymaps = M.markdown_keymaps,
    commands = M.markdown_commands,
    config = M.markdown_defaults,
  },
  vimdoc = {
    ["epicenter-mappings-table"] = M.vimdoc_keymaps,
    ["epicenter-commands-table"] = M.vimdoc_commands,
    ["epicenter-config-table"] = M.vimdoc_defaults,
  },
}

return M

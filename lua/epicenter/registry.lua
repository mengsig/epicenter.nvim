--- The single index of everything a feature contributes. `plugin/epicenter.lua`,
--- `:Epicenter` completion, the keymap installer, `:checkhealth` and the config
--- defaults all iterate this, so adding a feature is one new file plus one line
--- in `lua/epicenter/features/init.lua`.
---
--- @class epicenter.Command
--- @field name string subcommand word
--- @field desc string one-line help
--- @field status? "ready"|"planned" default "ready"
--- @field run? fun(ctx: { args: string[], bufnr: integer }) required when ready
--- @field complete? fun(lead: string): string[] argument completion
---
--- @class epicenter.Keymap
--- @field suffix string appended to `config.keymaps.prefix`
--- @field command string subcommand to invoke
--- @field desc string
---
--- @class epicenter.FeatureSpec
--- @field name string unique feature id, also its vimdoc tag
--- @field summary string
--- @field commands epicenter.Command[]
--- @field keymaps? epicenter.Keymap[]
--- @field options? table merged into the config defaults under its own keys
--- @field health? fun(add: fun(level: "ok"|"warn"|"error", msg: string))
---
--- Feature modules must not `require("epicenter.config")` at file scope: config
--- builds its defaults from this registry, so that would be a cycle.
local M = {}

local index = nil

local function fail(fmt, ...)
  error("epicenter.registry: " .. fmt:format(...), 0)
end

local function validate_spec(spec, source)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    fail("%s did not return a feature spec with a name", source)
  end
  if type(spec.summary) ~= "string" then
    fail("feature %q has no summary", spec.name)
  end
  if type(spec.commands) ~= "table" then
    fail("feature %q has no commands list", spec.name)
  end
end

local function validate_command(cmd, feature)
  if type(cmd) ~= "table" or type(cmd.name) ~= "string" then
    fail("feature %q has a command without a name", feature)
  end
  if type(cmd.desc) ~= "string" then
    fail("command %q has no desc", cmd.name)
  end
  local status = cmd.status or "ready"
  if status ~= "ready" and status ~= "planned" then
    fail("command %q has unknown status %q", cmd.name, tostring(cmd.status))
  end
  if status == "ready" and type(cmd.run) ~= "function" then
    fail("command %q is ready but has no run function", cmd.name)
  end
  if status == "planned" and cmd.run ~= nil then
    fail("command %q is planned but carries a run function", cmd.name)
  end
end

local function build()
  local specs = require("epicenter.features")
  local built = { specs = {}, commands = {}, by_name = {}, keymaps = {}, options = {} }
  local feature_names, option_owner = {}, {}

  for i, spec in ipairs(specs) do
    validate_spec(spec, ("features[%d]"):format(i))
    if feature_names[spec.name] then
      fail("duplicate feature name %q", spec.name)
    end
    feature_names[spec.name] = true
    table.insert(built.specs, spec)

    for _, cmd in ipairs(spec.commands) do
      validate_command(cmd, spec.name)
      local clash = built.by_name[cmd.name]
      if clash then
        fail("subcommand %q claimed by both %q and %q", cmd.name, clash.feature, spec.name)
      end
      local entry = vim.tbl_extend("force", { status = "ready" }, cmd, { feature = spec.name })
      built.by_name[cmd.name] = entry
      table.insert(built.commands, entry)
    end

    for _, map in ipairs(spec.keymaps or {}) do
      if not built.by_name[map.command] then
        fail(
          "feature %q maps %q to unknown subcommand %q",
          spec.name,
          map.suffix,
          tostring(map.command)
        )
      end
      table.insert(built.keymaps, vim.tbl_extend("force", {}, map, { feature = spec.name }))
    end

    for key, value in pairs(spec.options or {}) do
      if option_owner[key] then
        fail("option key %q claimed by both %q and %q", key, option_owner[key], spec.name)
      end
      option_owner[key] = spec.name
      built.options[key] = vim.deepcopy(value)
    end
  end

  return built
end

local function get()
  if not index then
    index = build()
  end
  return index
end

--- @return epicenter.FeatureSpec[]
function M.specs()
  return get().specs
end

--- Every subcommand, in registration order (drives completion order).
function M.commands()
  return get().commands
end

--- @param name string
--- @return table|nil
function M.command(name)
  return get().by_name[name]
end

function M.command_names()
  return vim.tbl_map(function(c)
    return c.name
  end, get().commands)
end

function M.keymaps()
  return get().keymaps
end

--- Feature-owned config defaults, merged into `config.defaults()`.
function M.options()
  return vim.deepcopy(get().options)
end

--- Test seam: forces a rebuild on next access.
function M.reset()
  index = nil
end

return M

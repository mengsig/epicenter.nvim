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
--- @class epicenter.OptionRules
--- @field variants? table<string, string[]> config path -> the types it accepts
--- @field enums? table<string, any[]> config path -> the values it accepts
--- @field positive? table<string, boolean> config path -> must be a positive number
---
--- @class epicenter.FeatureSpec
--- @field name string unique feature id, also its vimdoc tag
--- @field summary string
--- @field commands epicenter.Command[]
--- @field keymaps? epicenter.Keymap[]
--- @field options? table merged into the config defaults under its own keys
--- @field option_rules? epicenter.OptionRules validation for the feature's own options
--- @field option_docs? table<string, string> config path -> its one-line reference entry
--- @field setup? fun(cfg: table) called by `epicenter.setup()`; must be idempotent
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
  if spec.setup ~= nil and type(spec.setup) ~= "function" then
    fail("feature %q has a non-function setup", spec.name)
  end
end

local RULE_KINDS = { "variants", "enums", "positive" }

--- Same ownership rule as the option rules: a feature may only document a
--- path rooted at an option key it owns.
local function collect_docs(spec, owned, into)
  for path, text in pairs(spec.option_docs or {}) do
    local key = tostring(path):match("^[^.]+")
    if not owned[key] then
      fail("feature %q documents option %q, which it does not own", spec.name, tostring(path))
    end
    if type(text) ~= "string" then
      fail("feature %q documents option %q with a %s", spec.name, tostring(path), type(text))
    end
    into[path] = text
  end
end

--- A feature may only relax or constrain option paths rooted at a key it owns,
--- so no feature can loosen another's option - or a core one.
local function collect_rules(spec, owned, into)
  for kind, rules in pairs(spec.option_rules or {}) do
    if not vim.tbl_contains(RULE_KINDS, kind) then
      fail("feature %q declares unknown option rule kind %q", spec.name, tostring(kind))
    end
    for path, rule in pairs(rules) do
      local key = tostring(path):match("^[^.]+")
      if not owned[key] then
        fail("feature %q rules on option %q, which it does not own", spec.name, tostring(path))
      end
      into[kind][path] = rule
    end
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
  local built = {
    specs = {},
    commands = {},
    by_name = {},
    keymaps = {},
    options = {},
    rules = { variants = {}, enums = {}, positive = {} },
    docs = {},
  }
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

    local owned = {}
    for key, value in pairs(spec.options or {}) do
      if option_owner[key] then
        fail("option key %q claimed by both %q and %q", key, option_owner[key], spec.name)
      end
      option_owner[key] = spec.name
      owned[key] = true
      built.options[key] = vim.deepcopy(value)
    end
    collect_rules(spec, owned, built.rules)
    collect_docs(spec, owned, built.docs)
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

--- Validation rules features declared for their own options, keyed by config
--- path. `epicenter.config` merges these over its own.
--- @return { variants: table, enums: table, positive: table }
function M.option_rules()
  return vim.deepcopy(get().rules)
end

--- One-line reference entries features declared for their own options, keyed
--- by config path. `epicenter.config` merges these with its own.
--- @return table<string, string>
function M.option_docs()
  return vim.deepcopy(get().docs)
end

--- Test seam: forces a rebuild on next access.
function M.reset()
  index = nil
end

return M

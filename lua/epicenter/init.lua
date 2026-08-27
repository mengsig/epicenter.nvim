--- Public entry point. Everything heavier than config is required lazily so a
--- session that never opens a panel never loads the UI kit.
local M = {}

local config = require("epicenter.config")
local registry = require("epicenter.registry")

local did_setup = false
--- Keys this plugin installed, so a second setup() can take them back down.
local installed_keys = {}

local function install_keymaps(cfg)
  for _, lhs in ipairs(installed_keys) do
    pcall(vim.keymap.del, "n", lhs)
  end
  installed_keys = {}
  if cfg.keymaps == false then
    return
  end
  for _, map in ipairs(registry.keymaps()) do
    local lhs = cfg.keymaps.prefix .. map.suffix
    vim.keymap.set("n", lhs, function()
      M.run(map.command, {})
    end, { desc = map.desc, silent = true })
    table.insert(installed_keys, lhs)
  end
end

--- @param opts? table
--- @return table resolved config
function M.setup(opts)
  local cfg = config.setup(opts)
  did_setup = true
  require("epicenter.ui.theme").setup()
  install_keymaps(cfg)
  return cfg
end

--- Applies defaults once when the user never called `setup()`.
function M.ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

--- Runs a `:Epicenter` subcommand.
--- @param name string
--- @param args? string[]
--- @param bufnr? integer
function M.run(name, args, bufnr)
  local cmd = registry.command(name)
  if not cmd then
    M.notify(("unknown subcommand %q (try :Epicenter <Tab>)"):format(name), "error")
    return
  end
  if cmd.status == "planned" then
    M.notify(("%s is coming in this release"):format(name), "info")
    return
  end
  cmd.run({ args = args or {}, bufnr = bufnr or vim.api.nvim_get_current_buf() })
end

--- Single user-facing notice path, so every message looks the same.
--- @param msg string
--- @param level? "info"|"warn"|"error"
function M.notify(msg, level)
  require("epicenter.ui.toast").notify(msg, { level = level or "info" })
end

--- `:Epicenter` completion: subcommands first, then per-command arguments.
function M.complete(lead, line, _)
  local before = line:sub(1, #line):match("^%s*%S+%s+(.*)$") or ""
  local words = vim.split(before, "%s+")
  if #words <= 1 then
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, registry.command_names())
  end
  local cmd = registry.command(words[1])
  if cmd and cmd.complete then
    return cmd.complete(lead)
  end
  return {}
end

--- lazy.nvim `build =` hook: `build = function() require("epicenter").install() end`
function M.install(opts)
  return require("epicenter.install").install(opts)
end

--- Test seam: forgets setup state and config.
function M.reset()
  did_setup = false
  installed_keys = {}
  config.reset()
  registry.reset()
end

return M

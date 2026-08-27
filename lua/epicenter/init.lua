--- Public entry point. Everything heavier than config is required lazily so a
--- session that never opens a panel never loads the UI kit.
local M = {}

local config = require("epicenter.config")
local registry = require("epicenter.registry")

local did_setup = false
--- Keys this plugin installed, so a second setup() can take them back down.
local installed_keys = {}

local function remove_keymaps()
  for _, lhs in ipairs(installed_keys) do
    pcall(vim.keymap.del, "n", lhs)
  end
  installed_keys = {}
end

local function install_keymaps(cfg)
  remove_keymaps()
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

local function install_autocmds(cfg)
  local group = vim.api.nvim_create_augroup("Epicenter", { clear = true })
  if not cfg.lsp.auto_start then
    return
  end
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(event)
      require("epicenter.client").attach(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("epicenter.client").stop_all()
    end,
  })
end

--- @param opts? table
--- @return table resolved config
function M.setup(opts)
  local cfg = config.setup(opts)
  did_setup = true
  require("epicenter.ui.theme").setup()
  install_keymaps(cfg)
  install_autocmds(cfg)
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
--- @return any panel handle when the subcommand opened one
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
  -- The command's return value is its panel handle, if it opened one.
  return cmd.run({ args = args or {}, bufnr = bufnr or vim.api.nvim_get_current_buf() })
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
  remove_keymaps()
  config.reset()
  registry.reset()
end

return M

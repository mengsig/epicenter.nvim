--- Public entry point. Everything heavier than config is required lazily so a
--- session that never opens a panel never loads the UI kit.
local M = {}

local config = require("epicenter.config")
local registry = require("epicenter.registry")

local did_setup = false
--- Keys this plugin installed, so a second setup() can take them back down.
local installed_keys = {}
--- Keys the last install_keymaps() overwrote an existing mapping to install
--- (F13): `vim.keymap.set` replaces silently, so this is the only place that
--- ever sees what a leaf key clobbered - recorded here for `:checkhealth`.
local displaced_keys = {}

local function remove_keymaps()
  for _, lhs in ipairs(installed_keys) do
    pcall(vim.keymap.del, "n", lhs)
  end
  installed_keys = {}
  displaced_keys = {}
end

local function install_keymaps(cfg)
  remove_keymaps()
  if cfg.keymaps == false then
    return
  end
  for _, map in ipairs(registry.keymaps()) do
    local lhs = cfg.keymaps.prefix .. map.suffix
    local existing = vim.fn.maparg(lhs, "n", false, true)
    if not vim.tbl_isempty(existing) then
      table.insert(
        displaced_keys,
        { lhs = lhs, was = existing.desc or existing.rhs or "another mapping" }
      )
    end
    vim.keymap.set("n", lhs, function()
      M.run(map.command, {})
    end, { desc = map.desc, silent = true })
    table.insert(installed_keys, lhs)
  end
end

local function install_autocmds(cfg)
  local group = vim.api.nvim_create_augroup("Epicenter", { clear = true })

  -- Adopts a navgraph client `vim.lsp.enable` started (F7) - unconditional
  -- on `auto_start`, since setting that false is exactly how the README
  -- tells a `vim.lsp.enable` user to configure the plugin.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client.name == "navgraph" then
        require("epicenter.client").adopt(client, event.buf)
      end
    end,
  })

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
  -- Buffers already loaded when setup() runs (the common case under
  -- lazy-loading on cmd/keys) never fire BufReadPost/BufNewFile again.
  local client = require("epicenter.client")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      client.attach(bufnr)
    end
  end
end

--- Lets a feature install whatever it needs to watch the session (autocmds,
--- buffer-local keys). Must be idempotent: a second `setup()` calls it again.
local function setup_features(cfg)
  for _, spec in ipairs(registry.specs()) do
    if spec.setup then
      local ok, err = pcall(spec.setup, cfg)
      if not ok then
        error(("epicenter: feature %q failed to set up: %s"):format(spec.name, err), 0)
      end
    end
  end
end

--- @param opts? table
--- @return table resolved config
function M.setup(opts)
  local cfg = config.setup(opts)
  did_setup = true
  require("epicenter.ui.theme").setup()
  install_keymaps(cfg)
  install_autocmds(cfg)
  setup_features(cfg)
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
    M.notify(("%s is coming in a later release"):format(name), "info")
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

--- Plugin-manager `build =` hook: `build = function() require("epicenter").install({ wait = true }) end`
--- `wait = true` blocks until installation actually finishes - the build
--- step is otherwise considered done the instant this function returns,
--- while the download/build is still running in the background.
function M.install(opts)
  return require("epicenter.install").install(opts)
end

--- Keys the last setup() silently replaced an existing mapping to install
--- (F13) - `:checkhealth epicenter` surfaces this so a user whose own
--- mapping got overwritten gets a signal from somewhere.
--- @return { lhs: string, was: string }[]
function M.displaced_keymaps()
  return displaced_keys
end

--- Test seam: forgets setup state and config.
function M.reset()
  did_setup = false
  remove_keymaps()
  config.reset()
  registry.reset()
end

return M

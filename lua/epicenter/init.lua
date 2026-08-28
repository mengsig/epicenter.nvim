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

--- Flags every row-producing subcommand accepts: hand the result set to a Vim
--- list instead of leaving it in a panel. Applied here, once, so no feature
--- reimplements them.
local EXPORT_FLAGS = { ["--qf"] = "quickfix", ["--loc"] = "loclist" }

M.EXPORT_FLAGS = EXPORT_FLAGS

--- Splits an argument list into the command's own arguments and the export
--- flag, if any. Pure.
--- @param args string[]
--- @return string[] rest, string|nil list
function M.split_export_flag(args)
  local rest, list = {}, nil
  for _, arg in ipairs(args or {}) do
    local mapped = EXPORT_FLAGS[arg]
    if mapped then
      list = mapped
    else
      table.insert(rest, arg)
    end
  end
  return rest, list
end

--- Sends `handle`'s first answered result set to a Vim list, once. Registered
--- rather than read now: the rows do not exist until the server answers - and
--- a panel that answered synchronously fires the hook the moment it registers.
local function export_when_answered(handle, list, name)
  -- A live palette answers a query the user has not typed yet: it arms the
  -- flag on <CR> instead, so the export is the rows they were looking at.
  if type(handle) == "table" and type(handle.arm_export) == "function" then
    return handle:arm_export(list)
  end
  -- A gated panel's rows will never arrive on this server: say so now,
  -- instead of registering a hook that either never fires (this buffer's
  -- gate never clears) or fires later when a capable session appears and
  -- closes the panel minutes after the command ran.
  if type(handle) == "table" and handle.gate_reason then
    M.notify(vim.trim(handle.gate_reason), "warn")
    return
  end
  if type(handle) ~= "table" or type(handle.on_populate) ~= "function" then
    M.notify(("%s has no rows to send to a list"):format(name), "warn")
    return
  end
  local done = false
  handle:on_populate(function(populated)
    if done then
      return
    end
    done = true
    -- Out of the paint that is still running: the export closes the panel.
    vim.schedule(function()
      populated:export(list)
    end)
  end)
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
  local rest, list = M.split_export_flag(args)
  -- The command's return value is its panel handle, if it opened one.
  local handle = cmd.run({ args = rest, bufnr = bufnr or vim.api.nvim_get_current_buf() })
  if list then
    export_when_answered(handle, list, name)
  end
  return handle
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
  local out = (cmd and cmd.complete) and cmd.complete(lead) or {}
  if cmd and cmd.rows then
    for flag in pairs(EXPORT_FLAGS) do
      if vim.startswith(flag, lead) then
        table.insert(out, flag)
      end
    end
    table.sort(out)
  end
  return out
end

--- Plugin-manager `build =` hook: `build = function() require("epicenter").install({ wait = true }) end`
--- `wait = true` blocks until installation actually finishes - the build
--- step is otherwise considered done the instant this function returns,
--- while the download/build is still running in the background.
function M.install(opts)
  return require("epicenter.install").install(opts)
end

--- The enclosing chain of the cursor's line, for a winbar:
--- `vim.wo.winbar = "%{v:lua.require'epicenter'.breadcrumbs()}"`. Empty while
--- the first answer is in flight, and empty for good when no server is
--- running for the buffer's project.
--- @param bufnr? integer
--- @return string
function M.breadcrumbs(bufnr)
  return require("epicenter.features.crumbs").breadcrumbs(bufnr)
end

--- The fan-in/fan-out fragment for a statusline (lualine, heirline, or
--- `%{...}` in `statusline` itself), e.g. `⌁ 12 ← · 4 →`. Same cost rules as
--- `M.breadcrumbs`.
--- @param bufnr? integer
--- @return string
function M.statusline(bufnr)
  return require("epicenter.features.crumbs").statusline(bufnr)
end

--- The working change's review progress for a statusline, e.g.
--- `⌁ impact 3/12 reviewed`. Empty while there is no working change. Reads a
--- cached answer only - the request behind it is the debounced ambient one.
--- @return string
function M.impact()
  return require("epicenter.features.impact").statusline()
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

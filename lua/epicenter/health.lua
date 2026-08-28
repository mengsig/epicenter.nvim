--- `:checkhealth epicenter`
local M = {}

local PROTOCOL_VERSION = 1

local function check_neovim()
  if vim.fn.has("nvim-0.10") == 0 then
    vim.health.error("neovim 0.10 or newer is required")
    return
  end
  local version = "neovim " .. tostring(vim.version())
  if require("epicenter.compat").HAS_011 then
    vim.health.ok(version)
  else
    -- 0.10 is supported, but `vim.lsp.enable` and `winborder` are not there.
    vim.health.ok(version .. " (0.11+ adds vim.lsp.enable and 'winborder')")
  end
end

--- `navgraph --version` answers with a capabilities document, not a version
--- string, and pasting it whole turns the health report into 30KB of JSON.
--- Anything that is not that document still reports its first line, capped.
--- @return string
local function version_from(output)
  local text = vim.trim(output or "")
  if text == "" then
    return "no output"
  end
  local ok, decoded = pcall(vim.json.decode, text)
  local build = ok and type(decoded) == "table" and decoded.build or nil
  if type(build) == "table" then
    local version = build.buildVersion or build.version
    if type(version) == "string" then
      return version
    end
  end
  local first = vim.split(text, "\n", { plain = true })[1]
  return #first > 120 and (first:sub(1, 117) .. "...") or first
end

local function check_binary()
  local install = require("epicenter.install")
  local path, err = install.resolve()
  if not path then
    vim.health.error(err, { "Run `:Epicenter install`, or set `navgraph.path` in setup()." })
    return
  end
  vim.health.ok("navgraph binary: " .. path)

  local result = vim.system({ path, "--version" }, { text = true }):wait(3000)
  if result.code ~= 0 then
    vim.health.warn(("`%s --version` exited %d"):format(path, result.code))
    return
  end
  vim.health.ok("navgraph version: " .. version_from(result.stdout))
end

local function check_servers()
  local client = require("epicenter.client")
  local roots = client.roots()
  if #roots == 0 then
    vim.health.info("no navgraph server running yet (one starts on the first indexed buffer)")
    return
  end
  for _, root in ipairs(roots) do
    local info = client.info(root)
    if info.protocol_version == PROTOCOL_VERSION then
      vim.health.ok(("%s: protocol %d"):format(root, info.protocol_version))
    elseif info.protocol_version == nil then
      vim.health.warn(("%s: server did not report a protocol version"):format(root))
    else
      vim.health.error(
        ("%s: protocol %s, this plugin speaks %d"):format(
          root,
          tostring(info.protocol_version),
          PROTOCOL_VERSION
        ),
        { "Update navgraph (`:Epicenter install`) or epicenter.nvim." }
      )
    end
    if info.restarts > 0 then
      vim.health.warn(
        ("%s: the server has restarted %d time(s) - see %s"):format(
          root,
          info.restarts,
          require("epicenter.log").path()
        )
      )
    end
  end
end

--- A mapping the plugin did NOT install can only be seen from here after the
--- fact: `setup()` has already run, and `vim.keymap.set` replaces silently.
--- The prefix itself is the conflict worth naming - `<leader>e` mapped on its
--- own makes every epicenter key wait out `timeoutlen` before it fires. A
--- leaf key it silently overwrote (F13) is reported separately below, from
--- what `install_keymaps()` recorded at setup() time - the one place that
--- ever saw what was there before.
local function check_keymaps()
  local cfg = require("epicenter.config").get()
  if cfg.keymaps == false then
    vim.health.info("keymaps: none installed (keymaps = false)")
    return
  end
  local prefix = cfg.keymaps.prefix
  local direct = vim.fn.maparg(prefix, "n", false, true)
  if not vim.tbl_isempty(direct) then
    vim.health.warn(
      ("`%s` is mapped on its own (%s), so every epicenter key waits for 'timeoutlen' first"):format(
        prefix,
        direct.desc or direct.rhs or "another mapping"
      ),
      { "Change `keymaps.prefix`, or drop the conflicting mapping." }
    )
  end

  local displaced = require("epicenter").displaced_keymaps()
  if #displaced > 0 then
    local items = {}
    for _, d in ipairs(displaced) do
      table.insert(items, ("%s (was: %s)"):format(d.lhs, d.was))
    end
    vim.health.warn(
      "setup() silently replaced an existing mapping: " .. table.concat(items, ", "),
      { "vim.keymap.set overwrites with no error - change keymaps.prefix if you meant to keep it." }
    )
  end

  local taken = {}
  for _, map in ipairs(require("epicenter.registry").keymaps()) do
    local lhs = prefix .. map.suffix
    local existing = vim.fn.maparg(lhs, "n", false, true)
    if vim.tbl_isempty(existing) then
      table.insert(taken, lhs .. " (not installed)")
    elseif existing.desc ~= map.desc then
      table.insert(taken, ("%s (%s)"):format(lhs, existing.desc or existing.rhs or "?"))
    end
  end
  if #taken == 0 then
    vim.health.ok(
      ("keymaps: %s + %d keys, all installed"):format(
        prefix,
        #require("epicenter.registry").keymaps()
      )
    )
  else
    vim.health.warn(
      "keymaps another mapping owns: " .. table.concat(taken, ", "),
      { "epicenter did not install these, or something replaced them after setup()." }
    )
  end
end

local function check_icons()
  local cfg = require("epicenter.config").get()
  if cfg.ui.icons == "ascii" then
    vim.health.info("icons: ascii (configured)")
  elseif cfg.ui.icons == "nerd" or vim.g.have_nerd_font then
    vim.health.ok("icons: nerd-font glyphs")
  else
    vim.health.info("icons: ascii fallback (set `vim.g.have_nerd_font = true` for glyphs)")
  end
end

function M.check()
  vim.health.start("epicenter.nvim")
  vim.health.info("epicenter.nvim " .. require("epicenter.version"))
  check_neovim()
  check_binary()
  check_servers()
  check_icons()
  check_keymaps()
  vim.health.info("log: " .. require("epicenter.log").path())

  for _, spec in ipairs(require("epicenter.registry").specs()) do
    if spec.health then
      vim.health.start("epicenter.nvim: " .. spec.name)
      spec.health(vim.health)
    end
  end
end

return M

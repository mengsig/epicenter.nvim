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
  vim.health.ok("navgraph version: " .. vim.trim(result.stdout or ""))
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
  check_neovim()
  check_binary()
  check_servers()
  check_icons()

  for _, spec in ipairs(require("epicenter.registry").specs()) do
    if spec.health then
      vim.health.start("epicenter.nvim: " .. spec.name)
      spec.health(vim.health)
    end
  end
end

return M

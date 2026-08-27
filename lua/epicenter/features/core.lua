--- Server-level subcommands: what the index knows, and the three ways to
--- nudge it. No config requires at file scope - see `epicenter.registry`.

local function root_for(ctx)
  return require("epicenter.root").find(
    ctx.bufnr,
    require("epicenter.config").get().lsp.root_markers
  )
end

local function show_status(status, root)
  local window = require("epicenter.ui.window")
  local icons = require("epicenter.ui.icons")

  local languages = {}
  for ext, count in pairs(status.languages or {}) do
    table.insert(languages, ("%s %d"):format(ext, count))
  end
  table.sort(languages)

  local lines = {
    "",
    ("  root        %s"):format(vim.fn.fnamemodify(root, ":~")),
    ("  version     %s  (protocol %s)"):format(
      status.version or "?",
      tostring(status.protocolVersion)
    ),
    ("  files       %d"):format(status.files or 0),
    ("  symbols     %d"):format(status.symbols or 0),
    ("  edges       %d"):format(status.edges or 0),
    ("  languages   %s"):format(#languages > 0 and table.concat(languages, "  ") or "-"),
    ("  overlays    %d unsaved"):format(status.overlays or 0),
    ("  last index  %dms  %s"):format(status.lastIndexMs or 0, status.indexedAt or "?"),
    "",
  }

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end

  local win = window.open({
    box = window.box({ width = width, height = #lines }),
    title = (" %s navgraph "):format(icons.ui("dot")),
    footer = " q close ",
    enter = true,
  })
  win:set_lines(lines)
  win:reveal()
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      win:close()
    end, { buffer = win.buf, nowait = true, silent = true })
  end
end

--- @type epicenter.FeatureSpec
return {
  name = "core",
  summary = "Server status and lifecycle",
  commands = {
    {
      name = "status",
      desc = "What the index knows about this project",
      run = function(ctx)
        local root = root_for(ctx)
        require("epicenter.client").status(nil, function(err, status)
          if err then
            require("epicenter").notify(err.message or "navgraph did not answer", "error")
            return
          end
          show_status(status, root)
        end, { root = root })
      end,
    },
    {
      name = "restart",
      desc = "Restart the navgraph server for this project",
      run = function(ctx)
        local client = require("epicenter.client")
        local root = root_for(ctx)
        client.stop(root)
        local _, err = client.start({ root = root, bufnr = ctx.bufnr })
        require("epicenter").notify(
          err or ("navgraph restarted for " .. vim.fn.fnamemodify(root, ":~")),
          err and "error" or "info"
        )
      end,
    },
    {
      name = "rescan",
      desc = "Re-stat every file and rebuild the index",
      run = function(ctx)
        local progress = require("epicenter.ui.toast").progress("rescanning")
        require("epicenter.client").rescan({ full = ctx.args[1] == "full" }, function(err, status)
          if err then
            progress.finish(err.message or "rescan failed", "error")
            return
          end
          progress.finish(
            ("indexed %d symbols in %d files"):format(status.symbols or 0, status.files or 0)
          )
        end, { root = root_for(ctx) })
      end,
      complete = function(lead)
        return vim.tbl_filter(function(value)
          return vim.startswith(value, lead)
        end, { "full" })
      end,
    },
    {
      name = "log",
      desc = "Open the epicenter log",
      run = function()
        local path = require("epicenter.log").path()
        if not (vim.uv or vim.loop).fs_stat(path) then
          require("epicenter").notify("nothing logged yet: " .. path, "info")
          return
        end
        vim.cmd.split(vim.fn.fnameescape(path))
      end,
    },
  },
}

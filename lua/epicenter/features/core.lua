--- Server-level subcommands: the status dashboard, and the three ways to nudge
--- the server - each reachable from the dashboard as well as from its own
--- subcommand. No config requires at file scope - see `epicenter.registry`.
local M = {}

local LABEL_WIDTH = 12
local BAR_WIDTH = 10

local function root_for(ctx)
  return require("epicenter.root").find(
    ctx.bufnr,
    require("epicenter.config").get().lsp.root_markers
  )
end

--- What this session knows about the server for `root`: whether it is up, and
--- how to identify it. `client.rpc.pid` is Neovim's own record of the
--- spawned process, not anything the server reports - `navgraph/status`
--- carries no pid (F2).
--- @return { running: boolean, client_id: integer|nil, protocol: integer|nil, restarts: integer }
function M.server_info(root)
  local info = require("epicenter.client").info(root)
  local client = info.client_id and vim.lsp.get_client_by_id(info.client_id) or nil
  return {
    running = client ~= nil,
    client_id = info.client_id,
    protocol = info.protocol_version,
    restarts = info.restarts,
    failed = info.failed and info.failed.reason or nil,
    pid = client and client.rpc and client.rpc.pid or nil,
  }
end

local function row(lines, spans, label, value)
  local text = ("  %s%s"):format(label .. (" "):rep(math.max(1, LABEL_WIDTH - #label)), value)
  table.insert(spans, { row = #lines, hl = "EpicenterMuted", from = 2, to = 2 + #label })
  table.insert(lines, text)
end

--- The dashboard as buffer content. Pure, and it renders a server that did not
--- answer just as readily as one that did.
--- @param view { root: string, status?: table, server: table, error?: string, log: string }
--- @return { lines: string[], spans: table[] }
function M.dashboard_lines(view)
  local icons = require("epicenter.ui.icons")
  local toast = require("epicenter.ui.toast")
  local status, server = view.status, view.server
  local lines, spans = { "" }, {}

  row(lines, spans, "epicenter", require("epicenter.version"))
  row(lines, spans, "root", vim.fn.fnamemodify(view.root, ":~"))

  -- A server this session gave up on reads as its reason, not a bare
  -- "stopped" that could equally mean "not started yet" (F7).
  local server_parts = { server.failed or (server.running and "running" or "stopped") }
  if server.pid then
    table.insert(server_parts, "pid " .. server.pid)
  elseif server.client_id then
    table.insert(server_parts, "client " .. server.client_id)
  end
  if status and status.version then
    table.insert(server_parts, "navgraph " .. status.version)
  end
  if server.protocol then
    table.insert(server_parts, "protocol " .. server.protocol)
  end
  if (server.restarts or 0) > 0 then
    table.insert(server_parts, ("%d restarts"):format(server.restarts))
  end
  row(lines, spans, "server", table.concat(server_parts, " · "))

  if not status then
    row(lines, spans, "index", view.error or "the server did not answer")
    table.insert(spans, {
      row = #lines - 1,
      hl = "EpicenterInfo",
      from = 2 + LABEL_WIDTH,
      to = #lines[#lines],
    })
  else
    row(
      lines,
      spans,
      "index",
      ("%d files · %d symbols · %d edges"):format(
        status.files or 0,
        status.symbols or 0,
        status.edges or 0
      )
    )
    -- `overlays` is every buffer the server holds an in-memory version of
    -- while it's open, not the buffers with unsaved changes (F14) - an
    -- untouched open file was reading "1 unsaved", which is simply false.
    row(lines, spans, "overlays", ("%d open"):format(status.overlays or 0))
    -- `make screenshots` freeze (F8): navgraph/status is wall-clock and
    -- indexing-timing dependent, so a screenshot run pins both via env vars
    -- to keep the committed asset byte-identical run over run.
    local last_index_ms = tonumber(vim.env.EPICENTER_SHOT_FREEZE_MS) or status.lastIndexMs or 0
    local indexed_at = vim.env.EPICENTER_SHOT_FREEZE_AT or status.indexedAt or "?"
    row(lines, spans, "last index", ("%dms  %s"):format(last_index_ms, indexed_at))

    local languages, max = {}, 0
    for ext, count in pairs(status.languages or {}) do
      table.insert(languages, { ext = ext, count = count })
      max = math.max(max, count)
    end
    table.sort(languages, function(a, b)
      if a.count ~= b.count then
        return a.count > b.count
      end
      return a.ext < b.ext
    end)

    if #languages > 0 then
      table.insert(lines, "")
      row(lines, spans, "languages", "")
      for _, language in ipairs(languages) do
        local bar = toast.bar(
          max > 0 and language.count / max or 0,
          BAR_WIDTH,
          icons.ui("progress_full"),
          icons.ui("progress_empty")
        )
        local text = ("    %s%s %d"):format(
          language.ext .. (" "):rep(math.max(1, LABEL_WIDTH - #language.ext - 2)),
          bar,
          language.count
        )
        table.insert(spans, {
          row = #lines,
          hl = "EpicenterAccent",
          from = #text - #bar - #tostring(language.count) - 1,
          to = #text - #tostring(language.count) - 1,
        })
        table.insert(lines, text)
      end
    end
  end

  table.insert(lines, "")
  row(lines, spans, "log", vim.fn.fnamemodify(view.log, ":~"))
  table.insert(lines, "")
  return { lines = lines, spans = spans }
end

local function rescan(ctx, on_done)
  local progress = require("epicenter.ui.toast").progress("rescanning")
  require("epicenter.client").rescan({ full = ctx.args[1] == "full" }, function(err, status)
    if err then
      progress.finish(err.message or "rescan failed", "error")
    else
      progress.finish(
        ("indexed %d symbols in %d files"):format(status.symbols or 0, status.files or 0)
      )
    end
    if on_done then
      on_done()
    end
  end, { root = root_for(ctx) })
end

local function restart(ctx, on_done)
  local client = require("epicenter.client")
  local root = root_for(ctx)
  local _, err = client.restart({ root = root, bufnr = ctx.bufnr })
  require("epicenter").notify(
    err or ("navgraph restarted for " .. vim.fn.fnamemodify(root, ":~")),
    err and "error" or "info"
  )
  if on_done then
    on_done()
  end
end

local function open_log()
  local path = require("epicenter.log").path()
  if not (vim.uv or vim.loop).fs_stat(path) then
    -- The tilde form the dashboard shows beside this (F14): an absolute path
    -- both disagreed with it and was the more likely one to clip in a toast.
    require("epicenter").notify("nothing logged yet: " .. vim.fn.fnamemodify(path, ":~"), "info")
    return
  end
  -- vim.cmd.X() args are literal, not re-parsed - fnameescape here
  -- would double-escape and land backslashes in the filename.
  vim.cmd.split(path)
end

--- Box sized to `lines`' content, clamped to the screen (F14): a fixed
--- 62x14 float either clipped six-plus-language repos or wasted space on a
--- one-language one.
function M.box_for(lines)
  local cfg = require("epicenter.config").get()
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 4)
  end
  return require("epicenter.ui.window").box({
    width = math.max(width, 40),
    height = math.max(#lines, 3),
    max_width = cfg.ui.max_width,
    max_height = cfg.ui.max_height,
  })
end

--- The dashboard: what the index knows, and the actions that change it.
local function show_status(ctx)
  local client = require("epicenter.client")
  local icons = require("epicenter.ui.icons")
  local window = require("epicenter.ui.window")
  local root = root_for(ctx)
  local ns = vim.api.nvim_create_namespace("epicenter.status")

  local last_lines = { "", "  loading...", "" }

  local win = window.open({
    box = M.box_for(last_lines),
    title = (" %s navgraph "):format(icons.ui("dot")),
    footer = " r rescan · R restart · l log · q close ",
    filetype = "epicenter-status",
    enter = true,
    reflow = function()
      return M.box_for(last_lines)
    end,
  })

  local function paint(view)
    if not win:valid() then
      return
    end
    local rendered = M.dashboard_lines(view)
    last_lines = rendered.lines
    win:set_geometry(M.box_for(rendered.lines))
    win:set_lines(rendered.lines)
    vim.api.nvim_buf_clear_namespace(win.buf, ns, 0, -1)
    for _, span in ipairs(rendered.spans) do
      pcall(vim.api.nvim_buf_set_extmark, win.buf, ns, span.row, span.from, {
        end_col = span.to,
        hl_group = span.hl,
        strict = false,
      })
    end
  end

  local function reload()
    client.status(nil, function(err, status)
      paint({
        root = root,
        status = not err and status or nil,
        error = err and (err.message or "the server did not answer") or nil,
        server = M.server_info(root),
        log = require("epicenter.log").path(),
      })
      -- Per panel, not per session: a channel is there to drop THIS view's
      -- superseded answers. Shared, a closed dashboard's deferred reload
      -- (after `R`) supersedes a freshly opened one's first request and
      -- leaves it sitting on "loading...".
    end, { root = root, channel = ("status:%d"):format(win.buf) })
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = win.buf, nowait = true, silent = true })
  end
  map("r", function()
    rescan(ctx, reload)
  end)
  map("R", function()
    restart(ctx, function()
      -- The new server answers once it has initialized; until then the panel
      -- honestly reports a server that is not up yet.
      vim.defer_fn(reload, 250)
    end)
  end)
  map("l", function()
    win:close()
    open_log()
  end)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map(lhs, function()
      win:close()
    end)
  end

  win:reveal()
  reload()
  return win
end

M.name = "core"
M.summary = "Server status and lifecycle"

M.commands = {
  {
    name = "status",
    desc = "Dashboard: index, server, languages, log",
    run = show_status,
  },
  {
    name = "install",
    desc = "Download or build the navgraph binary",
    run = function()
      require("epicenter.install").install()
    end,
  },
  {
    name = "restart",
    desc = "Restart the server for this project",
    run = restart,
  },
  {
    name = "rescan",
    desc = "Re-stat every file and rebuild the index",
    run = rescan,
    complete = function(lead)
      return vim.tbl_filter(function(value)
        return vim.startswith(value, lead)
      end, { "full" })
    end,
  },
  {
    name = "log",
    desc = "Open the epicenter log",
    run = open_log,
  },
}

M.keymaps = {
  { suffix = "x", command = "status", desc = "Epicenter: status dashboard" },
}

return M

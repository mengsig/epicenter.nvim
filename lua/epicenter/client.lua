--- One navgraph server per workspace root, and the typed request layer every
--- feature calls.
---
--- Requests are async and cancellable. A request tagged with a `channel` wins
--- over every earlier request on that channel: a response that arrives after a
--- newer request was issued is dropped, so a fast typist never sees results
--- for a query they have already replaced.
local M = {}

local config = require("epicenter.config")
local events = require("epicenter.events")
local log = require("epicenter.log")
local root_mod = require("epicenter.root")

--- Extensions navgraph indexes (see its README). Buffers outside this list
--- still use the panels - they query the root's client.
M.SUPPORTED_EXTENSIONS = {
  ".zig",
  ".c",
  ".h",
  ".cc",
  ".cpp",
  ".cxx",
  ".hpp",
  ".hh",
  ".cs",
  ".py",
  ".pyi",
  ".js",
  ".mjs",
  ".cjs",
  ".jsx",
  ".ts",
  ".mts",
  ".tsx",
  ".lua",
  ".go",
  ".rs",
  ".rb",
}

--- Standard providers hidden on buffers that already have a real language
--- server, so `gd`/`gr`/`K` never return duplicates.
local FALLBACK_METHODS = {
  ["textDocument/definition"] = true,
  ["textDocument/references"] = true,
  ["textDocument/hover"] = true,
  ["textDocument/documentSymbol"] = true,
}

--- How long a run must stay healthy (no crash) before the streak forgets a
--- prior crash - three restarts spread over hours must not permanently trip
--- the lsp.restart.max ceiling.
local RESTART_FORGIVE_MS = 60000

--- @param path string
function M.is_supported(path)
  local ext = path:match("(%.[%w_]+)$")
  return ext ~= nil and vim.tbl_contains(M.SUPPORTED_EXTENSIONS, ext:lower())
end

-- Session ---------------------------------------------------------------------

--- @class epicenter.Session
local Session = {}
Session.__index = Session

--- Wraps any rpc transport. Kept independent of `vim.lsp` so the sequencing,
--- cancellation and stale-drop rules are testable against a fake transport.
--- @param rpc { request: fun(method, params, handler): boolean, integer?, cancel: fun(id: integer) }
---   `request` returns ok plus the request id; `cancel` takes that id.
--- @return epicenter.Session
function M.session(rpc)
  return setmetatable({ rpc = rpc, seq = {}, dropped = 0 }, Session)
end

--- @param opts? { channel?: string }
--- @return { cancel: fun(), id: integer|nil }
function Session:request(method, params, cb, opts)
  opts = opts or {}
  local channel = opts.channel
  local seq
  if channel then
    self.seq[channel] = (self.seq[channel] or 0) + 1
    seq = self.seq[channel]
  end

  local handle = { cancelled = false, cancel = function() end }

  local ok, id = self.rpc.request(method, params, function(err, result)
    if handle.cancelled then
      return
    end
    if channel and self.seq[channel] ~= seq then
      self.dropped = self.dropped + 1
      return
    end
    cb(err, result)
  end)

  if not ok then
    cb({ code = -32603, message = "epicenter: could not send " .. method }, nil)
    return handle
  end

  handle.id = id
  handle.cancel = function()
    if handle.cancelled then
      return
    end
    handle.cancelled = true
    if id then
      self.rpc.cancel(id)
    end
  end
  return handle
end

--- Number of responses dropped as stale, for tests and `:Epicenter status`.
function Session:dropped_count()
  return self.dropped
end

-- Server lifecycle -------------------------------------------------------------

--- root -> { client_id, cmd, restarts, stopping, session }
local servers = {}

local function capabilities()
  local caps = vim.lsp.protocol.make_client_capabilities()
  caps.general = caps.general or {}
  caps.general.positionEncodings = { "utf-8", "utf-16" }
  return caps
end

local function lsp_rpc(client_id)
  return {
    request = function(method, params, handler)
      local client = vim.lsp.get_client_by_id(client_id)
      if not client then
        return false, nil
      end
      return client:request(method, params, function(err, result)
        handler(err, result)
      end)
    end,
    cancel = function(id)
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        client:cancel_request(id)
      end
    end,
  }
end

--- Hides the fallback providers on buffers that already have another server.
local function install_fallback_guard(client)
  local base = client.supports_method
  client.supports_method = function(a, b, c)
    local method, bufnr
    if a == client then
      method, bufnr = b, c
    else
      method, bufnr = a, b
    end
    if type(bufnr) == "table" then
      bufnr = bufnr.bufnr
    end
    if FALLBACK_METHODS[method] and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      for _, other in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        -- Two navgraph clients on one buffer would recurse into each
        -- other's guard without bound; only defer to a different server.
        if
          other.id ~= client.id
          and other.name ~= "navgraph"
          and other:supports_method(method, bufnr)
        then
          return false
        end
      end
    end
    return base(a, b, c)
  end
end

local function schedule_restart(root, state)
  local cfg = config.get().lsp.restart
  if state.restarts >= cfg.max then
    require("epicenter.ui.toast").notify(
      ("navgraph stopped after %d restarts - see %s"):format(state.restarts, log.path()),
      { level = "error", timeout = 8000 }
    )
    servers[root] = nil
    return
  end
  local delay = cfg.backoff_ms[math.min(state.restarts + 1, #cfg.backoff_ms)]
  state.restarts = state.restarts + 1
  log.warn("navgraph for %s exited; restart %d in %dms", root, state.restarts, delay)
  vim.defer_fn(function()
    if servers[root] == state then
      -- Re-attach every buffer the dead client served, not just the current one.
      M.restart({ root = root, restarts = state.restarts })
    end
  end, delay)
end

local function on_indexed(payload)
  events.emit(events.INDEXED, payload or {})
end

--- Starts (or reuses) the server for `root`.
--- @param opts { root: string, cmd?: string[], bufnr?: integer, restarts?: integer }
--- @return integer|nil client_id, string|nil err
function M.start(opts)
  local root = vim.fs.normalize(opts.root)
  local existing = servers[root]
  if existing and vim.lsp.get_client_by_id(existing.client_id) then
    if opts.cmd and not vim.deep_equal(opts.cmd, existing.cmd) then
      -- The caller asked for a specific binary; reusing whatever already
      -- runs there would silently ignore it. Restart with the requested cmd.
      return M.restart({ root = root, cmd = opts.cmd, bufnr = opts.bufnr })
    end
    if opts.bufnr then
      vim.lsp.buf_attach_client(opts.bufnr, existing.client_id)
      existing.buffers[opts.bufnr] = true
    end
    return existing.client_id, nil
  end

  local cfg = config.get()
  local cmd = opts.cmd
  if not cmd then
    local bin, err = require("epicenter.install").resolve()
    if not bin then
      return nil, err
    end
    cmd = vim.list_extend({ bin, "lsp" }, cfg.navgraph.args)
  end

  local state = {
    cmd = cmd,
    restarts = opts.restarts or 0,
    root = root,
    stopping = false,
    buffers = {},
    starting = true,
  }
  servers[root] = state

  local client_id = vim.lsp.start({
    name = "navgraph",
    cmd = cmd,
    root_dir = root,
    init_options = cfg.lsp.init_options,
    capabilities = capabilities(),
    handlers = {
      ["navgraph/indexed"] = function(_, payload)
        on_indexed(payload)
      end,
    },
    on_init = function(client)
      if cfg.lsp.fallback_only then
        install_fallback_guard(client)
      end
      state.starting = false
      state.session = M.session(lsp_rpc(client.id))
      local experimental = vim.tbl_get(client.server_capabilities or {}, "experimental", "navgraph")
      state.protocol_version = experimental and experimental.protocolVersion or nil
      log.info("navgraph attached to %s (protocol %s)", root, tostring(state.protocol_version))
      -- A crash streak must not disable the server forever: forgive it once
      -- this run has stayed healthy for a while.
      if state.restarts > 0 then
        vim.defer_fn(function()
          if servers[root] == state then
            state.restarts = 0
          end
        end, RESTART_FORGIVE_MS)
      end
    end,
    on_exit = function(code, signal)
      local crashed = not state.stopping and (code ~= 0 or signal ~= 0)
      if crashed then
        schedule_restart(root, state)
      elseif servers[root] == state then
        servers[root] = nil
      end
    end,
  }, { bufnr = opts.bufnr, attach = opts.bufnr ~= nil })

  if not client_id then
    servers[root] = nil
    return nil, "epicenter: could not start navgraph (cmd: " .. table.concat(cmd, " ") .. ")"
  end
  state.client_id = client_id
  if opts.bufnr then
    state.buffers[opts.bufnr] = true
  end
  return client_id, nil
end

--- Stops the server for `root`, then starts a fresh one with the same `cmd`
--- and re-attaches every buffer that was attached before the stop (crash or
--- explicit restart).
--- @param opts { root: string, cmd?: string[], bufnr?: integer, restarts?: integer }
--- @return integer|nil client_id, string|nil err
function M.restart(opts)
  local root = vim.fs.normalize(opts.root)
  local dying = servers[root]
  local buffers = dying and vim.deepcopy(dying.buffers) or {}
  if opts.bufnr then
    buffers[opts.bufnr] = true
  end
  local cmd = opts.cmd or (dying and dying.cmd)

  M.stop(root)
  local client_id, err =
    M.start({ root = root, cmd = cmd, bufnr = opts.bufnr, restarts = opts.restarts })
  if not client_id then
    return nil, err
  end

  for bufnr in pairs(buffers) do
    if bufnr ~= opts.bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.lsp.buf_attach_client(bufnr, client_id)
      servers[root].buffers[bufnr] = true
    end
  end
  return client_id, nil
end

--- Attaches the buffer to its root's server when the file type is indexed.
--- @param bufnr integer
function M.attach(bufnr)
  local cfg = config.get()
  if not cfg.lsp.auto_start or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" or not M.is_supported(name) then
    return
  end
  local root = root_mod.find(bufnr, cfg.lsp.root_markers)
  local _, err = M.start({ root = root, bufnr = bufnr })
  if err then
    log.warn("attach skipped for %s: %s", name, err)
  end
end

--- @param root string
--- @return epicenter.Session|nil
function M.session_for_root(root)
  local state = servers[vim.fs.normalize(root)]
  return state and state.session or nil
end

--- Session serving the buffer's root, or nil when no server runs there.
--- @param bufnr? integer
function M.session_for_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M.session_for_root(root_mod.find(bufnr, config.get().lsp.root_markers))
end

--- Stops the server for `root` (an intentional stop never restarts).
function M.stop(root)
  local state = servers[vim.fs.normalize(root)]
  if not state then
    return
  end
  state.stopping = true
  local client = vim.lsp.get_client_by_id(state.client_id)
  if client then
    client:stop()
  end
  servers[vim.fs.normalize(root)] = nil
end

function M.stop_all()
  -- vim.tbl_keys(servers): just the keys, not a deep copy of every session,
  -- rpc closure and buffer set - M.stop() only ever needs the root name.
  for _, root in ipairs(vim.tbl_keys(servers)) do
    M.stop(root)
  end
end

--- Roots with a live server, for `:Epicenter status` and health.
function M.roots()
  return vim.tbl_keys(servers)
end

--- @param root string
--- @return { client_id: integer|nil, protocol_version: integer|nil, restarts: integer }
function M.info(root)
  local state = servers[vim.fs.normalize(root)] or {}
  return {
    client_id = state.client_id,
    protocol_version = state.protocol_version,
    restarts = state.restarts or 0,
  }
end

--- Registers a session directly. Tests use it to drive the request layer
--- without spawning a process.
function M.register_session(root, session)
  servers[vim.fs.normalize(root)] =
    { session = session, cmd = {}, restarts = 0, root = root, buffers = {} }
end

-- Typed request layer ----------------------------------------------------------

--- @param method string
--- @param params table
--- @param cb fun(err: table|nil, result: any)
--- @param opts? { bufnr?: integer, root?: string, channel?: string }
--- @return { cancel: fun() }
function M.request(method, params, cb, opts)
  opts = opts or {}
  local root = opts.root and vim.fs.normalize(opts.root)
    or root_mod.find(opts.bufnr, config.get().lsp.root_markers)
  local session
  if opts.root then
    -- A caller naming a root wants that project or an explicit error, never
    -- another root's server (an `and/or` here would silently fall through).
    session = M.session_for_root(opts.root)
  else
    session = M.session_for_buf(opts.bufnr)
  end
  if not session then
    local state = servers[root]
    -- Requests between vim.lsp.start() returning and on_init are normal, not
    -- an absent server: say so, instead of an alarming "not running".
    if state and state.starting then
      cb(
        { code = -32002, message = "navgraph is starting for this project, try again shortly" },
        nil
      )
    else
      cb({ code = -32002, message = "navgraph is not running for this project" }, nil)
    end
    return { cancel = function() end }
  end
  return session:request(method, params, cb, { channel = opts.channel })
end

--- Per-method helpers. Features depend only on these, never on raw method
--- names, so a protocol change lands in one file.
local HELPERS = {
  status = "navgraph/status",
  symbol_at = "navgraph/symbolAt",
  search = "navgraph/search",
  grep = "navgraph/grep",
  blast = "navgraph/blast",
  callers = "navgraph/callers",
  calls = "navgraph/calls",
  neighbors = "navgraph/neighbors",
  path = "navgraph/path",
  outline = "navgraph/outline",
  hot = "navgraph/hot",
  unused = "navgraph/unused",
  diff = "navgraph/diff",
  routes = "navgraph/routes",
  events_ = "navgraph/events",
  imports = "navgraph/imports",
  importers = "navgraph/importers",
  rescan = "navgraph/rescan",
  graph = "navgraph/graph",
}

for name, method in pairs(HELPERS) do
  M[name] = function(params, cb, opts)
    return M.request(method, params or vim.empty_dict(), cb, opts)
  end
end

M.METHODS = HELPERS

return M

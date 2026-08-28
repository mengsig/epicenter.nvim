--- One navgraph server per workspace root, and the typed request layer every
--- feature calls.
---
--- Requests are async and cancellable. A request tagged with a `channel` wins
--- over every earlier request on that channel: a response that arrives after a
--- newer request was issued is dropped, so a fast typist never sees results
--- for a query they have already replaced.
local M = {}

local compat = require("epicenter.compat")
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

--- The filetypes those extensions carry, for `lsp/navgraph.lua` - Neovim's
--- own server definitions match on filetype, not on path.
M.FILETYPES = {
  "c",
  "cpp",
  "cs",
  "go",
  "javascript",
  "javascriptreact",
  "lua",
  "python",
  "ruby",
  "rust",
  "typescript",
  "typescriptreact",
  "zig",
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

--- Upper bound on how long a restart waits for the old client to fully leave
--- Neovim's own client registry before starting the replacement. `vim.lsp.
--- start`'s default `reuse_client` matches on name+root_dir, not `cmd`; on
--- 0.11 it also has no `is_stopped()` guard, so it can hand back a client
--- that already exited but whose removal from that registry is still a
--- scheduled callback away, silently reusing the old cmd instead of spawning
--- the caller's. Poll the same registry Neovim's own reuse check reads
--- (`vim.lsp.get_client_by_id`) rather than guessing a delay long enough for
--- its internal bookkeeping to catch up.
local RESTART_STOP_TIMEOUT_MS = 2000

--- The contract's disambiguating name form for a Symbol: `qualified@file`
--- (`docs/lsp.md`: "Names accept the same `Parent.name` / `name@path` forms
--- as every CLI name argument"). A bare `qualified` is NOT unique - `router`
--- is four definitions in the shipped fixture - so anything re-asking the
--- server by name sends this form instead.
--- @param symbol table a protocol Symbol
--- @return string|nil nil when the symbol carries no usable name
function M.symbol_ref(symbol)
  local qualified = symbol and (symbol.qualified or symbol.name)
  if type(qualified) ~= "string" or qualified == "" then
    return nil
  end
  if type(symbol.file) ~= "string" or symbol.file == "" then
    return qualified
  end
  return qualified .. "@" .. symbol.file
end

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

--- Nothing here consumes `$/progress` - the dashboard reports index state
--- from `navgraph/indexed` - and Neovim's default capabilities ask for it
--- anyway, which navgraph answers with a `window/workDoneProgress/create`
--- carrying a STRING id. It then answers the client's reply to that as if the
--- reply were a fresh request, and Neovim raises on a response id it never
--- issued. Decline it: `make_client_capabilities()` says true, so overriding
--- is what turns the handshake off.
local function capabilities()
  local caps = vim.lsp.protocol.make_client_capabilities()
  caps.general = caps.general or {}
  caps.general.positionEncodings = { "utf-8", "utf-16" }
  caps.window = caps.window or {}
  caps.window.workDoneProgress = false
  return caps
end

M.capabilities = capabilities

local function lsp_rpc(client_id)
  return {
    request = function(method, params, handler)
      local client = vim.lsp.get_client_by_id(client_id)
      if not client then
        return false, nil
      end
      return compat.lsp_request(client, method, params, function(err, result)
        handler(err, result)
      end)
    end,
    cancel = function(id)
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        compat.lsp_cancel(client, id)
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
          and compat.lsp_supports_method(other, method, bufnr)
        then
          return false
        end
      end
    end
    return base(a, b, c)
  end
end

--- Marks `root`'s server as given up on, and says so once. Deleting the
--- record instead (as this used to) erased the only thing `:checkhealth`
--- could have read: `client.roots()` came back empty, health reported "no
--- navgraph server running yet", and eight seconds after the toast nothing
--- in the session knew the server had ever run (F7).
local function give_up(root, state, reason)
  state.failed = { reason = reason, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  state.session = nil
  state.starting = false
  log.error("navgraph for %s: %s - see :checkhealth epicenter", root, reason)
  require("epicenter.ui.toast").notify(
    ("%s\n`:Epicenter install`, then `:checkhealth epicenter` - log: %s"):format(reason, log.path()),
    { level = "error", timeout = 10000 }
  )
end

local function schedule_restart(root, state)
  local cfg = config.get().lsp.restart
  if state.restarts >= cfg.max then
    give_up(root, state, ("navgraph stopped after %d restarts"):format(state.restarts))
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

--- Blocks until `client_id` is gone from Neovim's client registry, up to
--- `RESTART_STOP_TIMEOUT_MS`. A server that ignores the stop and never exits
--- must not hang the restart forever, so this gives up and proceeds after the
--- bound rather than waiting indefinitely.
--- @param client_id integer|nil the id M.stop asked to exit
local function wait_for_stop(client_id)
  if not client_id then
    return
  end
  vim.wait(RESTART_STOP_TIMEOUT_MS, function()
    return vim.lsp.get_client_by_id(client_id) == nil
  end, 10)
end

local function on_indexed(payload)
  events.emit(events.INDEXED, payload or {})
end

--- The `navgraph/indexed` handler `M.start` wires, exposed so `lsp/navgraph.lua`
--- (the `vim.lsp.enable` route, F7) can install the exact same one - live
--- refresh on reindex must work whichever path started the server.
function M.handlers()
  return {
    ["navgraph/indexed"] = function(_, payload)
      on_indexed(payload)
    end,
  }
end

--- Starts (or reuses) the server for `root`.
--- @param opts { root: string, cmd?: string[], bufnr?: integer, restarts?: integer }
--- @return integer|nil client_id, string|nil err
function M.start(opts)
  local root = vim.fs.normalize(opts.root)
  local existing = servers[root]
  -- A root this session already gave up on: an automatic attach must not
  -- walk back into the same crash loop, one raw exit notice per try. An
  -- explicit `:Epicenter restart` clears the record first, via `M.stop`.
  if existing and existing.failed and not opts.cmd then
    return nil, existing.failed.reason
  end
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
    local install = require("epicenter.install")
    local bin, err = install.resolve()
    if not bin then
      return nil, err
    end
    -- Ask the binary what it can do BEFORE spawning it. A build that predates
    -- the editor server answers `--version` fine and exits 2 on every start,
    -- so starting it produces one raw "Client navgraph quit with exit code 2"
    -- per restart and no word of the cause or the remedy (F7).
    local unservable = install.unservable_reason(bin)
    if unservable then
      servers[root] = {
        cmd = { bin, "lsp" },
        restarts = 0,
        root = root,
        stopping = false,
        buffers = {},
        starting = false,
        failed = { reason = unservable, at = os.date("!%Y-%m-%dT%H:%M:%SZ") },
      }
      log.error("navgraph for %s: %s", root, unservable)
      return nil, unservable
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

  local client_id = compat.lsp_start({
    name = "navgraph",
    cmd = cmd,
    root_dir = root,
    init_options = cfg.lsp.init_options,
    capabilities = capabilities(),
    handlers = M.handlers(),
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
  }, opts.bufnr)

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
  -- An explicit restart is the "I have fixed it, try again" gesture: what the
  -- binary at that path could do when we last asked may no longer be true.
  require("epicenter.install").forget_capabilities()
  local dying = servers[root]
  local buffers = dying and vim.deepcopy(dying.buffers) or {}
  if opts.bufnr then
    buffers[opts.bufnr] = true
  end
  local cmd = opts.cmd or (dying and dying.cmd)

  M.stop(root)
  -- Wait for the old client to actually leave Neovim's client registry
  -- before starting the replacement - see RESTART_STOP_TIMEOUT_MS.
  wait_for_stop(dying and dying.client_id)
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
    -- Says the reason itself, once - "there is no binary" is only one of them
    -- (F7); a binary that cannot serve is the likelier one.
    require("epicenter.install").announce(err)
  end
end

--- Adopts a navgraph client `vim.lsp.enable` started externally, via
--- `lsp/navgraph.lua` (F7): the `LspAttach` autocmd in `epicenter.init`
--- calls this so the request layer (`M.request`/`session_for_root`) can
--- route to it exactly as if `M.start` had started it. A no-op when this
--- root's server is one epicenter itself already tracks - `M.start`'s own
--- path fires `LspAttach` too, and this must not fight it.
--- @param client vim.lsp.Client
--- @param bufnr integer
function M.adopt(client, bufnr)
  local cfg = config.get()
  local root =
    vim.fs.normalize(client.config.root_dir or root_mod.find(bufnr, cfg.lsp.root_markers))
  local existing = servers[root]
  if existing and existing.client_id == client.id then
    if bufnr then
      existing.buffers[bufnr] = true
    end
    return
  end
  if existing and vim.lsp.get_client_by_id(existing.client_id) then
    -- Something else already serves this root (epicenter's own start, or an
    -- earlier adoption) - two navgraph clients on one root would double the
    -- index and race on which one a request lands. Leave the incumbent.
    log.warn("a navgraph client for %s is already tracked; not adopting a second one", root)
    return
  end

  if cfg.lsp.fallback_only then
    install_fallback_guard(client)
  end
  local experimental = vim.tbl_get(client.server_capabilities or {}, "experimental", "navgraph")
  local state = {
    cmd = client.config.cmd or {},
    restarts = 0,
    root = root,
    stopping = false,
    buffers = bufnr and { [bufnr] = true } or {},
    starting = false,
    client_id = client.id,
    adopted = true,
    protocol_version = experimental and experimental.protocolVersion or nil,
  }
  state.session = M.session(lsp_rpc(client.id))
  servers[root] = state
  log.info("navgraph adopted for %s (protocol %s)", root, tostring(state.protocol_version))
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
    compat.lsp_stop(client)
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
--- @return { client_id: integer|nil, protocol_version: integer|nil, restarts: integer,
---   failed: { reason: string, at: string }|nil }
function M.info(root)
  local state = servers[vim.fs.normalize(root)] or {}
  return {
    client_id = state.client_id,
    protocol_version = state.protocol_version,
    restarts = state.restarts or 0,
    failed = state.failed,
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
    if state and state.failed then
      cb({ code = -32002, message = state.failed.reason .. " - see :checkhealth epicenter" }, nil)
      return { cancel = function() end }
    end
    -- Requests between the server starting and on_init are normal, not
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

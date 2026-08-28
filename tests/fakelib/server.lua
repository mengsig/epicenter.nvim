--- Dispatch loop of the fake navgraph server: LSP framing, the standard
--- lifecycle and document-sync methods, and the per-area `navgraph/*` handlers
--- from `tests/fake/`.
local M = {}

local rpc = require("fakelib.rpc")
local index = require("fakelib.index")
local schema = require("contract.schema")

local PROTOCOL_VERSION = 1
local PROTOCOL_MINOR = 1

local function capabilities(methods)
  local navgraph_methods = vim.tbl_filter(function(name)
    return vim.startswith(name, "navgraph/")
  end, vim.tbl_keys(methods))
  table.sort(navgraph_methods)
  -- Only advertise what tests/fake actually implements: the client's
  -- FALLBACK_METHODS guard reads these at face value, and the real
  -- navgraph must be able to trust that too. hoverProvider is the one
  -- exception - blast's K routing (navgraph_owns_hover) reads it as a
  -- capability signal and never issues a literal textDocument/hover
  -- request, matching real navgraph's own protocol.
  -- v1.1: a standard-LSP addition announces itself the standard way, so the
  -- client's own capability gate can trust it (`epicenter.client.supports`).
  local standard = {
    ["textDocument/prepareCallHierarchy"] = "callHierarchyProvider",
    ["textDocument/prepareTypeHierarchy"] = "typeHierarchyProvider",
    ["textDocument/implementation"] = "implementationProvider",
  }
  local providers = {}
  for method, capability in pairs(standard) do
    if methods[method] then
      providers[capability] = true
    end
  end

  return vim.tbl_extend("error", providers, {
    textDocumentSync = { openClose = true, change = 1, save = { includeText = false } },
    definitionProvider = true,
    hoverProvider = true,
    documentSymbolProvider = true,
    positionEncoding = "utf-8",
    experimental = {
      navgraph = {
        protocolVersion = PROTOCOL_VERSION,
        protocolMinor = PROTOCOL_MINOR,
        methods = navgraph_methods,
      },
    },
  })
end

--- @param opts { root?: string, input?: file*, output?: file* }
function M.serve(opts)
  opts = opts or {}
  local input = opts.input or io.stdin
  local output = opts.output or io.stdout
  local handlers = require("fake").handlers()

  local ctx = {
    root = opts.root,
    overlays = {},
    index = nil,
    shutdown_requested = false,
  }

  function ctx.to_relative(uri)
    local path = vim.uri_to_fname(uri)
    if ctx.root and vim.startswith(path, ctx.root) then
      return path:sub(#ctx.root + 2)
    end
    return path
  end

  function ctx.reindex(reason, changed)
    ctx.index = index.build(ctx.root, ctx.overlays)
    local payload = {
      reason = reason,
      files = #ctx.index.files,
      symbols = #ctx.index.symbols,
      edges = 0,
      ms = ctx.index.ms,
      changedFiles = changed or {},
    }
    local bad = schema.check_indexed(payload)
    assert(not bad, bad)
    rpc.notify(output, "navgraph/indexed", payload)
  end

  local function handle_request(msg)
    local method, params, id = msg.method, msg.params or {}, msg.id

    if method == "initialize" then
      ctx.root = ctx.root
        or (params.rootUri and vim.uri_to_fname(params.rootUri))
        or (params.workspaceFolders and params.workspaceFolders[1] and vim.uri_to_fname(
          params.workspaceFolders[1].uri
        ))
        or vim.uv.cwd()
      ctx.root = vim.fs.normalize(ctx.root)
      ctx.init_options = params.initializationOptions or {}
      rpc.respond(output, id, {
        capabilities = capabilities(handlers),
        serverInfo = { name = "navgraph (fake)", version = "fake-0.1.0" },
      })
      return
    end

    if method == "shutdown" then
      ctx.shutdown_requested = true
      rpc.respond(output, id, vim.NIL)
      return
    end

    local handler = handlers[method]
    if not handler then
      rpc.respond_error(output, id, -32601, "method not found: " .. method)
      return
    end

    -- The contract, enforced on the wire: a request the client should never
    -- have been able to build is refused here, before any handler sees it.
    -- Every method the contract defines, custom or standard - v1.1 adds
    -- call/type hierarchy on the standard LSP names.
    if schema.method(method) then
      local bad = schema.check_params(method, params)
      if bad then
        rpc.respond_error(output, id, -32602, bad)
        return
      end
    end

    local ok, result = pcall(handler, ctx, params)
    if not ok then
      -- A handler raises `{ code, message }` to answer with a protocol error
      -- code of its own (-32001 for a target that resolves to nothing,
      -- -32602 for bad params); anything else is an internal failure.
      if type(result) == "table" and result.code then
        rpc.respond_error(output, id, result.code, result.message or "request failed")
      else
        rpc.respond_error(output, id, -32603, tostring(result))
      end
      return
    end
    -- ...and on the way back out, so a fake that drifts from the contract
    -- fails here rather than teaching a feature the wrong shape.
    if schema.method(method) then
      local bad = schema.check_result(method, result)
      if bad then
        rpc.respond_error(output, id, -32603, "fake server broke the contract: " .. bad)
        return
      end
    end
    rpc.respond(output, id, result)
  end

  local function handle_notification(msg)
    local method, params = msg.method, msg.params or {}

    if method == "initialized" then
      ctx.reindex("initial")
    elseif method == "textDocument/didOpen" then
      ctx.overlays[ctx.to_relative(params.textDocument.uri)] = params.textDocument.text
      ctx.reindex("change", { ctx.to_relative(params.textDocument.uri) })
    elseif method == "textDocument/didChange" then
      local last = params.contentChanges[#params.contentChanges]
      if last then
        ctx.overlays[ctx.to_relative(params.textDocument.uri)] = last.text
        ctx.reindex("change", { ctx.to_relative(params.textDocument.uri) })
      end
    elseif method == "textDocument/didClose" then
      ctx.overlays[ctx.to_relative(params.textDocument.uri)] = nil
      ctx.reindex("change", { ctx.to_relative(params.textDocument.uri) })
    elseif method == "textDocument/didSave" then
      ctx.reindex("save", { ctx.to_relative(params.textDocument.uri) })
    elseif method == "exit" then
      output:flush()
      os.exit(ctx.shutdown_requested and 0 or 1)
    end
    -- $/cancelRequest and anything else: accepted, best effort, no reply.
  end

  while true do
    local body = rpc.read_body(input)
    if body == nil then
      break -- stdin EOF
    end
    local ok, msg = pcall(vim.json.decode, body)
    if not ok then
      -- Contract: a parse failure is reported and the server keeps serving.
      rpc.respond_error(output, vim.NIL, -32700, "parse error")
    elseif msg.id ~= nil and msg.method ~= nil then
      handle_request(msg)
    elseif msg.method ~= nil then
      handle_notification(msg)
    end
  end

  os.exit(0)
end

return M

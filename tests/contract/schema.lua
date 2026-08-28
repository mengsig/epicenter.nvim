--- `docs/lsp.md` v1 (plus the v1.1 addendum) as data: one params shape and one
--- result shape per method, plus the shared `Symbol`/`Node`/`Edge` shapes.
--- The vendored copy of that document sits beside this file.
---
--- Requests are checked STRICTLY - an unknown or ill-typed param is an error,
--- so a feature cannot be written against an imagined shape. Responses are
--- checked FORWARD-COMPATIBLY - every promised field must be present and
--- well-typed, but a field a newer server adds is ignored.
local M = {}

M.VERSION = 1
--- The addendum this schema also covers. Every v1.1 method is gated behind
--- `epicenter.client.supports`, so a v1.0 server is never sent one.
M.MINOR = 1

-- Field specs -----------------------------------------------------------------
--
--   { kind = "string"|"integer"|"number"|"boolean"|"table"|"any",
--     required = true,            -- absent means optional
--     enum = { ... },             -- allowed values for a string
--     list = <spec>,              -- a list, each element matching <spec>
--     fields = { name = <spec> }, -- an object with these fields
--     nullable = true }           -- `vim.NIL` is an accepted value

local function str(over)
  return vim.tbl_extend("force", { kind = "string" }, over or {})
end

local function int(over)
  return vim.tbl_extend("force", { kind = "integer" }, over or {})
end

local function bool(over)
  return vim.tbl_extend("force", { kind = "boolean" }, over or {})
end

local function list_of(spec, over)
  return vim.tbl_extend("force", { kind = "table", list = spec }, over or {})
end

local function object(fields, over)
  return vim.tbl_extend("force", { kind = "table", fields = fields }, over or {})
end

local function required(spec)
  return vim.tbl_extend("force", spec, { required = true })
end

-- Shared shapes ---------------------------------------------------------------

local POSITION = object({
  line = required(int()),
  character = required(int()),
})

local RANGE = object({
  start = required(POSITION),
  ["end"] = required(POSITION),
})

--- Symbol, as `docs/lsp.md` "Shared result shapes" defines it. `doc` is the
--- only optional member: a definition with no doc comment omits it.
--- v1.1 adds `contentHash`, the key clients store per-site state under. It
--- stays OPTIONAL here for the same reason `protocolMinor` does: a v1.0
--- server answers every shared method without it, and response checking is
--- forward-compatible, not version-gated. Every v1.1-only method that keys
--- state on a hash requires its own copy of it.
local SYMBOL = object({
  id = required(int()),
  name = required(str()),
  qualified = required(str()),
  kind = required(str()),
  file = required(str()),
  uri = required(str()),
  line = required(int()),
  endLine = required(int()),
  sig = required(str()),
  doc = str(),
  language = required(str()),
  callers = required(int()),
  callees = required(int()),
  exported = required(bool()),
  test = required(bool()),
  contentHash = str(),
})

--- Node is recursive; `children` is patched in below.
local NODE = object({
  symbol = required(SYMBOL),
  exact = required(bool()),
  lines = required(list_of(int())),
  ext = required(list_of(str())),
  recursion = required(bool()),
})
NODE.fields.children = required(list_of(NODE))

local EDGE = object({
  from = required(int()),
  to = required(int()),
  exact = required(bool()),
  lines = required(list_of(int())),
})

local SUMMARY = object({
  symbols = required(int()),
  files = required(int()),
  tests = required(int()),
  maxDepth = required(int()),
  truncated = required(bool()),
  byDepth = required(list_of(int())),
  byFile = required(list_of(object({ file = required(str()), count = required(int()) }))),
})

local BLAST_RESULT = object({
  roots = required(list_of(SYMBOL)),
  nodes = required(list_of(object({
    symbol = required(SYMBOL),
    depth = required(int()),
    via = required(list_of(int())),
    exact = required(bool()),
  }))),
  edges = required(list_of(EDGE)),
  summary = required(SUMMARY),
})

--- v1.1 adds `protocolMinor` and `backend`; both optional, since a v1.0
--- server answers `navgraph/status` without them.
local STATUS_RESULT = object({
  root = required(str()),
  protocolVersion = required(int()),
  protocolMinor = int(),
  backend = object({
    default = required(str()),
    languages = required({ kind = "table" }),
  }),
  version = required(str()),
  files = required(int()),
  symbols = required(int()),
  edges = required(int()),
  languages = required({ kind = "table" }),
  overlays = required(int()),
  indexedAt = required(str()),
  lastIndexMs = required(int()),
  cache = required(bool()),
})

-- Params fragments ------------------------------------------------------------

--- `Scope = { strict?, tests? }`, on every walk.
local SCOPE = {
  strict = bool(),
  tests = str({ enum = { "with", "without", "only" } }),
}

--- `Target = { uri, position } | { symbol }`. Both forms are optional here;
--- `M.check_params` enforces that exactly one of them is supplied.
local TARGET = {
  uri = str(),
  position = POSITION,
  symbol = str(),
}

local DIRECTION = str({ enum = { "callers", "callees" } })

local function params(...)
  return vim.tbl_extend("error", {}, ...)
end

-- v1.1 shapes ------------------------------------------------------------------

--- The `data` a `CallHierarchyItem`/`TypeHierarchyItem` carries back, so a
--- follow-up request names the same definition the server resolved.
local HIERARCHY_DATA = object({
  id = required(int()),
  qualified = required(str()),
  file = required(str()),
  exact = bool(),
})

--- `CallHierarchyItem` and `TypeHierarchyItem` are the same shape.
local HIERARCHY_ITEM = object({
  name = required(str()),
  kind = required(int()),
  uri = required(str()),
  range = required(RANGE),
  selectionRange = required(RANGE),
  detail = str(),
  data = required(HIERARCHY_DATA),
})

local LOCATION = object({ uri = required(str()), range = required(RANGE) })

--- `{ textDocument: { uri }, position }`, the standard LSP request shape.
local TEXT_DOCUMENT_POSITION = {
  textDocument = required(object({ uri = required(str()) })),
  position = required(POSITION),
}

-- The method table ------------------------------------------------------------

--- @class epicenter.contract.Method
--- @field params table<string, table> the fields a request may carry
--- @field target? "required"|"blast" which Target forms the method accepts
--- @field result table the result shape

--- @type table<string, epicenter.contract.Method>
M.METHODS = {
  ["navgraph/status"] = {
    params = {},
    result = STATUS_RESULT,
  },

  -- v1.1 adds `range` and `breadcrumbs`. Both stay OPTIONAL here: a v1.0
  -- server answers this method without them, and the contract's response
  -- checking is forward-compatible, not version-gated.
  ["navgraph/symbolAt"] = {
    params = { uri = required(str()), position = required(POSITION) },
    result = object({
      word = required(str()),
      symbol = required(vim.tbl_extend("force", SYMBOL, { nullable = true })),
      enclosing = required(vim.tbl_extend("force", SYMBOL, { nullable = true })),
      candidates = required(list_of(SYMBOL)),
      range = vim.tbl_extend("force", RANGE, { nullable = true }),
      breadcrumbs = list_of(SYMBOL),
    }),
  },

  ["navgraph/search"] = {
    params = params(SCOPE, {
      query = required(str()),
      kinds = list_of(str()),
      refs = bool(),
      limit = int(),
    }),
    result = object({
      items = required(list_of(object({
        symbol = required(SYMBOL),
        score = required(int()),
        matches = required(list_of(int())),
        lines = list_of(int()),
      }))),
      total = required(int()),
    }),
  },

  ["navgraph/grep"] = {
    params = {
      pattern = required(str()),
      regex = bool(),
      caseSensitive = bool(),
      limit = int(),
      include = list_of(str()),
    },
    result = object({
      items = required(list_of(object({
        file = required(str()),
        uri = required(str()),
        line = required(int()),
        character = required(int()),
        text = required(str()),
        enclosing = required(vim.tbl_extend("force", SYMBOL, { nullable = true })),
      }))),
      total = required(int()),
      truncated = required(bool()),
    }),
  },

  ["navgraph/blast"] = {
    -- Blast alone also accepts the `{ file }` and `{ ref }` target forms.
    target = "blast",
    params = params(SCOPE, TARGET, {
      file = str(),
      ref = str(),
      depth = int(),
      direction = DIRECTION,
      limit = int(),
    }),
    result = BLAST_RESULT,
  },

  -- `{file}`/`{ref}` are accepted too, as for `navgraph/blast`, but a tree
  -- has one root: only the first definition they resolve to is walked.
  ["navgraph/callers"] = {
    target = "blast",
    params = params(SCOPE, TARGET, { file = str(), ref = str(), depth = int(), refs = bool() }),
    result = object({ root = required(NODE) }),
  },

  ["navgraph/calls"] = {
    target = "blast",
    params = params(SCOPE, TARGET, { file = str(), ref = str(), depth = int(), refs = bool() }),
    result = object({ root = required(NODE) }),
  },

  ["navgraph/neighbors"] = {
    target = "required",
    params = params(SCOPE, TARGET),
    result = object({
      items = required(list_of(object({
        symbol = required(SYMBOL),
        callees = required(list_of(object({
          symbol = required(SYMBOL),
          exact = required(bool()),
          lines = required(list_of(int())),
        }))),
        callers = required(list_of(object({
          symbol = required(SYMBOL),
          exact = required(bool()),
          lines = required(list_of(int())),
        }))),
      }))),
    }),
  },

  ["navgraph/path"] = {
    params = { from = required(str()), to = required(str()) },
    -- `path` is empty when either name is unknown or no path exists; an
    -- ambiguous endpoint (a name matching several definitions) instead
    -- comes back in `ambiguousFrom`/`ambiguousTo` and the walk is not run.
    result = object({
      path = required(list_of(SYMBOL)),
      ambiguousFrom = required(list_of(SYMBOL)),
      ambiguousTo = required(list_of(SYMBOL)),
    }),
  },

  ["navgraph/outline"] = {
    params = params(SCOPE, { path = str(), kinds = list_of(str()), limit = int() }),
    result = object({
      files = required(list_of(object({
        file = required(str()),
        lang = required(str()),
        symbols = required(list_of(SYMBOL)),
      }))),
    }),
  },

  ["navgraph/hot"] = {
    params = params(SCOPE, { path = str(), limit = int() }),
    result = object({
      items = required(list_of(object({
        symbol = required(SYMBOL),
        fanIn = required(int()),
        fanInExact = required(int()),
        fanInTest = required(int()),
        fanOut = required(int()),
        fanOutExact = required(int()),
      }))),
    }),
  },

  ["navgraph/unused"] = {
    params = params(SCOPE, {
      path = str(),
      noPublic = bool(),
      followImports = bool(),
      limit = int(),
    }),
    result = object({
      items = required(list_of(object({
        symbol = required(SYMBOL),
        testOnly = required(bool()),
      }))),
    }),
  },

  ["navgraph/diff"] = {
    params = params(SCOPE, {
      ref = str(),
      depth = int(),
      direction = DIRECTION,
      limit = int(),
    }),
    result = object({ ref = required(str()), blast = required(BLAST_RESULT) }),
  },

  ["navgraph/routes"] = {
    params = { filter = str(), limit = int() },
    result = object({
      items = required(list_of(object({
        symbol = required(SYMBOL),
        handler = required(vim.tbl_extend("force", SYMBOL, { nullable = true })),
        callers = required(list_of(SYMBOL)),
      }))),
    }),
  },

  ["navgraph/events"] = {
    params = { filter = str(), limit = int() },
    result = object({
      groups = required(list_of(object({
        key = required(str()),
        sites = required(list_of(object({
          role = required(str({ enum = { "handler", "emitter" } })),
          verb = required(str()),
          file = required(str()),
          uri = required(str()),
          line = required(int()),
          ["in"] = str(),
        }))),
      }))),
    }),
  },

  ["navgraph/imports"] = {
    params = { path = str(), limit = int() },
    result = object({
      files = required(list_of(object({
        file = required(str()),
        uri = required(str()),
        imports = required(list_of(object({
          target = required(str()),
          targetUri = required(str()),
          binding = required(str()),
        }))),
      }))),
    }),
  },

  ["navgraph/importers"] = {
    params = { path = required(str()) },
    result = object({
      files = required(list_of(object({
        file = required(str()),
        uri = required(str()),
        importers = required(list_of(object({ file = required(str()), uri = required(str()) }))),
      }))),
    }),
  },

  ["navgraph/rescan"] = {
    params = { full = bool() },
    result = STATUS_RESULT,
  },

  -- v1.1 ----------------------------------------------------------------------

  ["navgraph/tests"] = {
    target = "required",
    params = params(SCOPE, TARGET, { limit = int() }),
    result = object({
      symbol = required(SYMBOL),
      tests = required(list_of(object({
        symbol = required(SYMBOL),
        depth = required(int()),
        via = required(list_of(int())),
      }))),
      -- "Every list method reports `truncated`" - but the addendum does not
      -- say where, and navgraph reports it inside the summary. Both spots
      -- are accepted; a client reads whichever is there.
      summary = required(object({
        count = required(int()),
        maxDepth = required(int()),
        truncated = bool(),
      })),
      truncated = bool(),
    }),
  },

  ["navgraph/types"] = {
    target = "required",
    params = params(SCOPE, TARGET, { limit = int() }),
    result = object({
      symbol = required(SYMBOL),
      supertypes = required(list_of(SYMBOL)),
      subtypes = required(list_of(SYMBOL)),
      implementors = required(list_of(SYMBOL)),
      users = required(list_of(object({
        symbol = required(SYMBOL),
        kind = required(str({
          enum = {
            "param",
            "return",
            "field",
            "local",
            "extends",
            "implements",
            "annotation",
            "generic",
          },
        })),
      }))),
      truncated = bool(),
    }),
  },

  -- No `target` rule: "the whole working change" is the call with no target
  -- at all, which is the common one.
  ["navgraph/impact"] = {
    params = params(SCOPE, {
      uri = str(),
      range = RANGE,
      ref = str(),
      depth = int(),
      direction = DIRECTION,
      limit = int(),
    }),
    result = object({
      roots = required(list_of(SYMBOL)),
      nodes = required(list_of(object({
        symbol = required(SYMBOL),
        depth = required(int()),
        via = required(list_of(int())),
        exact = required(bool()),
        contentHash = required(str()),
      }))),
      edges = required(list_of(EDGE)),
      summary = required(SUMMARY),
      --- Hash of the whole working change: client state scoped to one change.
      changeId = required(str()),
      hunks = required(list_of(object({
        uri = required(str()),
        range = required(RANGE),
        roots = required(list_of(SYMBOL)),
      }))),
      -- The blast summary already carries the walk's own `truncated`; a
      -- top-level copy is accepted but not demanded.
      truncated = bool(),
    }),
  },

  --- Everything an editing agent needs about one symbol, in one call,
  --- trimmed to `budget` tokens.
  ["navgraph/context"] = {
    target = "required",
    params = params(TARGET, {
      budget = int(),
      include = list_of(str({
        enum = { "callers", "callees", "types", "tests", "body" },
      })),
    }),
    result = object({
      symbol = required(SYMBOL),
      definition = required(object({ text = required(str()), range = required(RANGE) })),
      signature = required(str()),
      doc = str(),
      callers = required(list_of(SYMBOL)),
      callees = required(list_of(SYMBOL)),
      types = required(list_of(SYMBOL)),
      tests = required(list_of(SYMBOL)),
      truncated = required(bool()),
      tokensEstimate = required(int()),
    }),
  },

  --- The symbol enclosing a line - a stack-trace or diff-hunk lookup, which
  --- is a LINE, not a cursor position, so no `position` here.
  ["navgraph/where"] = {
    params = { uri = required(str()), line = required(int()) },
    result = object({
      enclosing = required(vim.tbl_extend("force", SYMBOL, { nullable = true })),
      breadcrumbs = required(list_of(SYMBOL)),
      file = required(str()),
    }),
  },

  ["textDocument/prepareCallHierarchy"] = {
    params = TEXT_DOCUMENT_POSITION,
    result = list_of(HIERARCHY_ITEM),
  },

  ["callHierarchy/incomingCalls"] = {
    params = { item = required(HIERARCHY_ITEM) },
    result = list_of(object({
      from = required(HIERARCHY_ITEM),
      fromRanges = required(list_of(RANGE)),
    })),
  },

  ["callHierarchy/outgoingCalls"] = {
    params = { item = required(HIERARCHY_ITEM) },
    result = list_of(object({
      to = required(HIERARCHY_ITEM),
      fromRanges = required(list_of(RANGE)),
    })),
  },

  ["textDocument/prepareTypeHierarchy"] = {
    params = TEXT_DOCUMENT_POSITION,
    result = list_of(HIERARCHY_ITEM),
  },

  ["typeHierarchy/supertypes"] = {
    params = { item = required(HIERARCHY_ITEM) },
    result = list_of(HIERARCHY_ITEM),
  },

  ["typeHierarchy/subtypes"] = {
    params = { item = required(HIERARCHY_ITEM) },
    result = list_of(HIERARCHY_ITEM),
  },

  ["textDocument/implementation"] = {
    params = TEXT_DOCUMENT_POSITION,
    result = list_of(LOCATION),
  },

  ["navgraph/graph"] = {
    params = params(SCOPE, { path = str() }),
    -- `truncated` says the page holds only `nodes` of `nodesTotal` symbols
    -- (the renderer's own node cap) - a client must say so rather than
    -- present a capped subgraph as the whole graph.
    result = object({
      path = required(str()),
      nodes = required(int()),
      nodesTotal = required(int()),
      truncated = required(bool()),
    }),
  },
}

--- The server -> client notification, checked the same way as a result.
M.INDEXED = object({
  reason = required(str({ enum = { "initial", "change", "save", "rescan", "watch" } })),
  files = required(int()),
  symbols = required(int()),
  edges = required(int()),
  ms = required(int()),
  changedFiles = required(list_of(str())),
})

-- Checking --------------------------------------------------------------------

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function type_name(value)
  if value == vim.NIL then
    return "null"
  end
  if type(value) == "table" then
    return vim.islist(value) and "list" or "table"
  end
  return type(value)
end

--- @param strict boolean reject fields the spec does not name
--- @param problems string[] collects every violation, so one call reports all
local function check(spec, value, path, strict, problems)
  local function bad(fmt, ...)
    table.insert(problems, path .. ": " .. fmt:format(...))
  end

  if value == vim.NIL then
    if not spec.nullable then
      bad("must not be null")
    end
    return
  end

  if spec.kind == "integer" then
    if not is_integer(value) then
      bad("expected an integer, got %s", type_name(value))
    end
    return
  end
  if spec.kind == "number" or spec.kind == "string" or spec.kind == "boolean" then
    if type(value) ~= spec.kind then
      bad("expected a %s, got %s", spec.kind, type_name(value))
      return
    end
    if spec.enum and not vim.tbl_contains(spec.enum, value) then
      bad("must be one of %s, got %s", table.concat(spec.enum, ", "), tostring(value))
    end
    return
  end
  if spec.kind ~= "table" then
    return -- "any"
  end

  if type(value) ~= "table" then
    bad("expected a table, got %s", type_name(value))
    return
  end

  if spec.list then
    -- An empty table is both an empty list and an empty object; either reads
    -- as "no elements", so only a non-empty non-list is wrong here.
    if next(value) ~= nil and not vim.islist(value) then
      bad("expected a list, got a keyed table")
      return
    end
    for index, element in ipairs(value) do
      check(spec.list, element, ("%s[%d]"):format(path, index), strict, problems)
    end
    return
  end

  if not spec.fields then
    return
  end
  for name, field in pairs(spec.fields) do
    local child = value[name]
    if child == nil then
      if field.required then
        bad("missing required field %q", name)
      end
    else
      check(field, child, path .. "." .. name, strict, problems)
    end
  end
  -- Strict is only ever used on a request, so name what the caller sent.
  if strict then
    for name in pairs(value) do
      if spec.fields[name] == nil then
        bad("unknown param %q", tostring(name))
      end
    end
  end
end

local function report(problems)
  if #problems == 0 then
    return nil
  end
  table.sort(problems)
  return table.concat(problems, "; ")
end

--- @param method string
--- @return epicenter.contract.Method|nil
function M.method(method)
  return M.METHODS[method]
end

--- Checks a request's params. Strict: a param the contract does not name is
--- an error, and a method taking a Target must carry exactly one Target form.
--- @return string|nil error
function M.check_params(method, value)
  local spec = M.METHODS[method]
  if not spec then
    return ("no contract schema for %s"):format(method)
  end
  value = value or {}
  if type(value) ~= "table" then
    return ("%s params: expected a table, got %s"):format(method, type_name(value))
  end

  local problems = {}
  check({ kind = "table", fields = spec.params }, value, method .. " params", true, problems)

  if spec.target then
    local forms = {}
    if value.uri ~= nil or value.position ~= nil then
      table.insert(forms, "uri+position")
      if value.uri == nil or value.position == nil then
        table.insert(problems, method .. " params: uri and position go together")
      end
    end
    for _, key in ipairs({ "symbol", "file", "ref" }) do
      if value[key] ~= nil then
        table.insert(forms, key)
      end
    end
    if #forms == 0 then
      table.insert(problems, method .. " params: needs a Target")
    elseif #forms > 1 then
      table.insert(
        problems,
        method .. " params: one Target form only, got " .. table.concat(forms, " and ")
      )
    end
  end

  return report(problems)
end

--- Checks a response. Forward-compatible: every promised field must be there
--- and well-typed, but a field a newer server added is ignored.
--- @return string|nil error
function M.check_result(method, value)
  local spec = M.METHODS[method]
  if not spec then
    return ("no contract schema for %s"):format(method)
  end
  local problems = {}
  check(spec.result, value, method .. " result", false, problems)
  return report(problems)
end

--- @return string|nil error
function M.check_indexed(value)
  local problems = {}
  check(M.INDEXED, value, "navgraph/indexed params", false, problems)
  return report(problems)
end

return M

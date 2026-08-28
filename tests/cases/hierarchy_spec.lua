--- Call hierarchy and type hierarchy against the fake navgraph server, which
--- speaks the v1.1 addendum. Also the gate itself: against a server that does
--- not announce those methods, the panel says so rather than sending one.
local support = require("support")
local epicenter = require("epicenter")
local hierarchy = require("epicenter.features.hierarchy")

local function open_fixture(root, relative, line, column)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  vim.api.nvim_win_set_cursor(0, { line, column or 0 })
  return vim.api.nvim_get_current_buf()
end

local function body(panel)
  return table.concat(vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false), "\n")
end

local function press(panel, keys)
  vim.api.nvim_set_current_win(panel.win.win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("the hierarchy row", function()
  local function item(over)
    return vim.tbl_extend("force", {
      name = "handle",
      kind = 12,
      uri = "file:///proj/app/server.lua",
      range = { start = { line = 8, character = 0 }, ["end"] = { line = 11, character = 0 } },
      selectionRange = {
        start = { line = 8, character = 0 },
        ["end"] = { line = 8, character = 6 },
      },
      data = { id = 1, qualified = "M.handle", file = "app/server.lua" },
    }, over or {})
  end

  local function row(over)
    return vim.tbl_extend("force", {
      node = { type = "item", item = item(), name = "M.handle", sites = 0, exact = true },
      depth = 0,
      expandable = false,
      expanded = false,
      recursive = false,
    }, over or {})
  end

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("shows the name and the 1-based line the item's range starts at", function()
    expect.matches(hierarchy.render_row(row()).text, "M%.handle%s+app/server%.lua:9")
  end)

  it("counts the call sites only when there is more than one", function()
    expect.matches(
      hierarchy.render_row(row({
        node = vim.tbl_extend("force", row().node, {
          sites = 3,
        }),
      })).text,
      "3x"
    )
    expect.falsy(hierarchy.render_row(row()).text:find("1x", 1, true))
  end)

  it("marks a heuristic edge and a recursive branch", function()
    local heuristic = row({ node = vim.tbl_extend("force", row().node, { exact = false }) })
    expect.matches(hierarchy.render_row(heuristic).text, "%?")
    expect.matches(hierarchy.render_row(row({ recursive = true })).text, "recursive")
  end)

  it("renders a group heading with its own count", function()
    local group = row({
      node = { type = "group", name = "supertypes", children = { {}, {} } },
      expandable = true,
    })
    expect.matches(hierarchy.render_row(group).text, "supertypes %(2%)")
  end)

  it("keeps a definition's identity independent of the branch that reached it", function()
    expect.eq(hierarchy.identity_of(item()), "file:///proj/app/server.lua#M.handle@8")
  end)
end)

describe("call hierarchy against the fake navgraph server", function()
  local root, buf, panel

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    -- Column 12 is inside `handle_request` on its own definition line.
    buf = open_fixture(root, "app/server.lua", 9, 12)
    support.attach(root, buf)
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.events").clear()
  end)

  it("roots at the symbol under the cursor and lists who calls it", function()
    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "incoming calls")

    expect.matches(body(panel), "M%.handle_request")
    expect.matches(body(panel), "M%.start")
    expect.matches(vim.api.nvim_win_get_config(panel.win.win).title[1][1], "incoming calls")
  end)

  it("opens outgoing on request, and flips on a real d", function()
    panel = epicenter.run("hierarchy", { "outgoing" }, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "outgoing calls")
    expect.matches(body(panel), "log_request", "handle_request calls log_request")

    press(panel, "d")
    wait(function()
      return body(panel):find("M.start", 1, true) ~= nil
    end, 10000, "the flip back to incoming")
    expect.matches(vim.api.nvim_win_get_config(panel.win.win).title[1][1], "incoming calls")
  end)

  it("fetches the next level only when l asks for it", function()
    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "incoming calls")
    local before = panel.list:count()

    -- Row 1 is the root; row 2 is the first caller, which has callers of its own.
    panel.list:select(2)
    press(panel, "l")
    wait(function()
      return panel.list:count() > before
    end, 10000, "the fetched level")
  end)

  it("jumps to the definition a row names", function()
    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "incoming calls")
    panel.list:select(2)
    local target = panel:target()
    expect.truthy(target ~= nil)
    expect.matches(target.path, "server%.lua$")
  end)
end)

describe("type hierarchy against the fake navgraph server", function()
  local root, buf, panel

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    -- `class FlowCase(BaseCase):` - column 6 is on the class's own name.
    buf = open_fixture(root, "app/test_flow.py", 6, 7)
    support.attach(root, buf)
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.events").clear()
  end)

  it("shows supertypes, subtypes and implementors as three groups", function()
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("supertypes", 1, true) ~= nil
    end, 10000, "the type groups")

    local text = body(panel)
    for _, group in ipairs({ "supertypes", "subtypes", "implementors" }) do
      expect.matches(text, group)
    end
    expect.matches(text, "BaseCase", "FlowCase extends BaseCase")
  end)

  it("names the type in its title", function()
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("supertypes", 1, true) ~= nil
    end, 10000, "the type groups")
    expect.matches(vim.api.nvim_win_get_config(panel.win.win).title[1][1], "FlowCase")
  end)
end)

describe("the types panel's users group", function()
  local root, buf, panel

  -- Its own workspace: a stand-in session controls exactly what
  -- `navgraph/types` answers, since the shared fake server's `users` is
  -- always empty (it extracts no type-use edges for this fixture).
  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(root, ".navgraph"), "p")
    local path = vim.fs.joinpath(root, "shape.lua")
    vim.fn.writefile({ "local Shape = {}", "return Shape" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.client").stop(root)
    vim.fn.delete(root, "rf")
  end)

  local function register(announce_types)
    local sent = {}
    local methods = announce_types and { "navgraph/types" } or {}
    require("epicenter.client").register_session(root, {
      request = function(_, method, _params, cb)
        table.insert(sent, method)
        local answer
        if method == "textDocument/prepareTypeHierarchy" then
          answer = {
            {
              name = "Shape",
              kind = 5,
              uri = vim.uri_from_fname(vim.fs.joinpath(root, "shape.lua")),
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
              selectionRange = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 5 },
              },
              data = { id = 1, qualified = "Shape", file = "shape.lua" },
            },
          }
        elseif method == "navgraph/types" then
          answer = {
            symbol = {
              qualified = "Shape",
              file = "shape.lua",
              line = 1,
              uri = vim.uri_from_fname(vim.fs.joinpath(root, "shape.lua")),
            },
            supertypes = {},
            subtypes = {},
            implementors = {},
            users = {
              {
                symbol = {
                  qualified = "Circle.shape",
                  file = "circle.lua",
                  line = 3,
                  uri = "file:///circle.lua",
                  kind = "field",
                },
                kind = "field",
              },
            },
          }
        else
          answer = {}
        end
        vim.schedule(function()
          cb(nil, answer)
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, {
      typeHierarchyProvider = true,
      experimental = { navgraph = { protocolVersion = 1, protocolMinor = 1, methods = methods } },
    })
    return sent
  end

  it("asks navgraph/types and lists who uses it once the server announces it", function()
    register(true)
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return body(panel):find("users", 1, true) ~= nil
    end, 5000, "the users group")
    local text = body(panel)
    expect.matches(text, "users %(1%)")
    expect.matches(text, "Circle%.shape")
    expect.matches(text, "as field")
  end)

  it("never sends navgraph/types against a server that has not announced it", function()
    local sent = register(false)
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return body(panel):find("supertypes", 1, true) ~= nil
    end, 5000, "the type groups")
    expect.falsy(body(panel):find("users", 1, true), "no users group without the method")
    expect.falsy(vim.tbl_contains(sent, "navgraph/types"))
  end)
end)

describe("the protocol 1.1 gate", function()
  local root, buf, panel

  -- Its own workspace, never the shared fixture: registering a stand-in
  -- session for a root a real fake server is already serving would throw
  -- away that server's record and strand the process for the next spec file.
  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(root, ".navgraph"), "p")
    local path = vim.fs.joinpath(root, "old.lua")
    vim.fn.writefile({ "local function handle() end", "return handle" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.client").stop(root)
    vim.fn.delete(root, "rf")
  end)

  it("says what is missing instead of sending a method a v1.0 server has not got", function()
    local sent = {}
    require("epicenter.client").register_session(root, {
      request = function(_, method, _params, cb)
        table.insert(sent, method)
        vim.schedule(function()
          cb({ code = -32601, message = "method not found" }, nil)
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, { experimental = { navgraph = { protocolVersion = 1, methods = { "navgraph/blast" } } } })

    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return body(panel):find("protocol 1.1", 1, true) ~= nil
    end, 5000, "the gate's notice")
    expect.eq(sent, {}, "a v1.0 server is never sent a v1.1 method")
  end)

  it("lets the request through once the server announces the method", function()
    local sent = {}
    require("epicenter.client").register_session(root, {
      request = function(_, method, _params, cb)
        table.insert(sent, method)
        vim.schedule(function()
          cb(nil, {})
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, {
      callHierarchyProvider = true,
      experimental = { navgraph = { protocolVersion = 1, protocolMinor = 1, methods = {} } },
    })

    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return #sent > 0
    end, 5000, "the prepare request")
    expect.eq(sent[1], "textDocument/prepareCallHierarchy")
  end)
end)

describe("a direction flip while a call request is in flight", function()
  local root, buf, panel, held

  --- Its own workspace and a stand-in session whose call answers are held, so
  --- the test controls exactly when a stale one lands.
  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(root, ".navgraph"), "p")
    local path = vim.fs.joinpath(root, "a.lua")
    vim.fn.writefile({ "local function f() end", "return f" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    held = {}
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.client").stop(root)
    vim.fn.delete(root, "rf")
  end)

  local function item(name, line)
    local uri = vim.uri_from_fname(vim.fs.joinpath(root, "a.lua"))
    return {
      name = name,
      kind = 12,
      uri = uri,
      range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 9 } },
      selectionRange = {
        start = { line = line, character = 0 },
        ["end"] = { line = line, character = 9 },
      },
      data = { id = line + 1, qualified = name, file = "a.lua" },
    }
  end

  local function register()
    require("epicenter.client").register_session(root, {
      request = function(_, method, _params, cb)
        if method == "textDocument/prepareCallHierarchy" then
          vim.schedule(function()
            cb(nil, { item("f", 0) })
          end)
        else
          -- Held: released by the test, after the flip.
          table.insert(held, { method = method, cb = cb })
        end
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, {
      callHierarchyProvider = true,
      experimental = { navgraph = { protocolVersion = 1, protocolMinor = 1, methods = {} } },
    })
  end

  local function release(method, entries)
    for _, request in ipairs(held) do
      if request.method == method and not request.done then
        request.done = true
        request.cb(nil, entries)
        return true
      end
    end
    return false
  end

  it("drops the stale answer instead of indexing it under the new direction", function()
    register()
    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return #held > 0
    end, 5000, "the incoming request")
    expect.eq(held[1].method, "callHierarchy/incomingCalls")

    press(panel, "d")
    wait(function()
      return #held > 1
    end, 5000, "the outgoing request after the flip")
    expect.eq(held[2].method, "callHierarchy/outgoingCalls")

    -- The stale incoming answer carries `.from`; the outgoing reader would
    -- index it as `.to` and crash on a nil item.
    expect.truthy(release("callHierarchy/incomingCalls", { { from = item("caller", 4) } }))
    expect.falsy(body(panel):find("caller", 1, true), "the stale answer is not drawn")

    expect.truthy(release("callHierarchy/outgoingCalls", { { to = item("callee", 7) } }))
    wait(function()
      return body(panel):find("callee", 1, true) ~= nil
    end, 5000, "the outgoing rows")
    expect.matches(vim.api.nvim_win_get_config(panel.win.win).title[1][1], "outgoing calls")
    expect.falsy(body(panel):find("caller", 1, true), "the stale answer never appears")
  end)

  it("skips a malformed entry instead of crashing on it (L5)", function()
    register()
    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return #held > 0
    end, 5000, "the incoming request")

    -- A hostile/older server answers an entry with no `.from` at all.
    expect.truthy(
      release("callHierarchy/incomingCalls", { { fromRanges = {} }, { from = item("caller", 4) } })
    )
    wait(function()
      return body(panel):find("caller", 1, true) ~= nil
    end, 5000, "the well-formed row")
    expect.truthy(panel:valid(), "the malformed entry must not take the panel down")
  end)
end)

describe("the types panel's implementors group", function()
  local root, buf, panel

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(root, ".navgraph"), "p")
    local path = vim.fs.joinpath(root, "shape.lua")
    vim.fn.writefile({ "local Shape = {}", "return Shape", "", "-- pad", "-- pad" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.client").stop(root)
    vim.fn.delete(root, "rf")
  end)

  local function shape_item()
    return {
      name = "Shape",
      kind = 5,
      uri = vim.uri_from_fname(vim.fs.joinpath(root, "shape.lua")),
      range = { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 11 } },
      selectionRange = {
        start = { line = 0, character = 6 },
        ["end"] = { line = 0, character = 11 },
      },
      data = { id = 1, qualified = "Shape", file = "shape.lua" },
    }
  end

  --- @param announce_implementation boolean
  --- @param supertypes_error boolean
  local function register(announce_implementation, supertypes_error)
    local seen = {}
    require("epicenter.client").register_session(root, {
      request = function(_, method, params, cb)
        table.insert(seen, { method = method, params = params })
        vim.schedule(function()
          if method == "textDocument/prepareTypeHierarchy" then
            return cb(nil, { shape_item() })
          end
          if method == "typeHierarchy/supertypes" and supertypes_error then
            return cb({ code = -32603, message = "index is rebuilding" }, nil)
          end
          cb(nil, {})
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, {
      typeHierarchyProvider = true,
      implementationProvider = announce_implementation,
      experimental = { navgraph = { protocolVersion = 1, protocolMinor = 1, methods = {} } },
    })
    return seen
  end

  local function methods_of(seen)
    return vim.tbl_map(function(entry)
      return entry.method
    end, seen)
  end

  it("never asks for implementations against a server that declines the capability", function()
    local seen = register(false, false)
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return body(panel):find("supertypes", 1, true) ~= nil
    end, 5000, "the type groups")
    expect.falsy(
      vim.tbl_contains(methods_of(seen), "textDocument/implementation"),
      "implementationProvider=false declines the capability"
    )
    expect.falsy(body(panel):find("implementors", 1, true), "no group it could not ask for")
  end)

  it("asks at the resolved type, not wherever the cursor moved to meanwhile", function()
    local seen = register(true, false)
    local source_win = vim.api.nvim_get_current_win()
    panel = epicenter.run("types", {}, buf)
    -- The prepare answer is scheduled: move the cursor before it lands.
    vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
    wait(function()
      return body(panel):find("implementors", 1, true) ~= nil
    end, 5000, "the implementors group")
    local asked
    for _, entry in ipairs(seen) do
      if entry.method == "textDocument/implementation" then
        asked = entry.params
      end
    end
    expect.truthy(asked ~= nil, "the implementation request was sent")
    expect.eq(asked.position.line, 0, "the resolved type's own line, not the moved cursor")
  end)

  it("says a group failed instead of drawing it as empty", function()
    register(true, true)
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return body(panel):find("supertypes", 1, true) ~= nil
    end, 5000, "the type groups")
    local text = body(panel)
    expect.matches(text, "supertypes %(failed%)")
    expect.matches(text, "index is rebuilding")
    expect.matches(text, "subtypes %(0%)", "a group that really is empty still says 0")
  end)
end)

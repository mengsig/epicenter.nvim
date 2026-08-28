--- `lsp/navgraph.lua` is the definition `vim.lsp.enable("navgraph")` picks up
--- on Neovim 0.11+. It must describe the same server the plugin's own start
--- path launches, or the two routes disagree about the same project.
local client = require("epicenter.client")

local function load_definition()
  local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")
  local chunk = assert(loadfile(vim.fs.joinpath(repo, "lsp/navgraph.lua")))
  return chunk()
end

describe("the lsp/navgraph.lua server definition", function()
  local definition

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({})
    definition = load_definition()
  end)

  it("launches `navgraph lsp`, the contract-v1 subcommand", function()
    expect.eq(definition.cmd[2], "lsp", "`navgraph serve` is a different protocol")
    expect.truthy(#definition.cmd >= 2)
  end)

  it("reads the plugin's own root markers and init options", function()
    local cfg = require("epicenter.config").get()
    expect.eq(definition.root_markers, cfg.lsp.root_markers)
    expect.eq(definition.init_options, cfg.lsp.init_options)
  end)

  it("carries navgraph.args, exactly as the plugin's own start path does", function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ navgraph = { args = { "--log-level", "debug" } } })
    local with_args = load_definition()
    expect.eq(
      vim.list_slice(with_args.cmd, #with_args.cmd - 1, #with_args.cmd),
      { "--log-level", "debug" }
    )
  end)

  it("covers every extension the client treats as indexed", function()
    -- One filetype per language family the client attaches to; a new
    -- extension without a filetype here would be served by the plugin's own
    -- path but not by `vim.lsp.enable`.
    local by_filetype = {}
    for _, filetype in ipairs(definition.filetypes) do
      by_filetype[filetype] = true
    end
    local expected = {
      [".c"] = "c",
      [".cpp"] = "cpp",
      [".cs"] = "cs",
      [".go"] = "go",
      [".js"] = "javascript",
      [".lua"] = "lua",
      [".py"] = "python",
      [".rb"] = "ruby",
      [".rs"] = "rust",
      [".ts"] = "typescript",
      [".tsx"] = "typescriptreact",
      [".zig"] = "zig",
    }
    for extension, filetype in pairs(expected) do
      expect.truthy(
        client.is_supported("x" .. extension),
        extension .. " is no longer an indexed extension"
      )
      expect.truthy(by_filetype[filetype], "lsp/navgraph.lua does not list " .. filetype)
    end
  end)

  --- F7: without these two, `vim.lsp.enable("navgraph")` advertises the
  --- default `workDoneProgress = true` (navgraph's `workDoneProgress/create`
  --- handshake then crashes Neovim's own response-id bookkeeping) and never
  --- refreshes an open panel on reindex - the route worked in name only.
  it("declines workDoneProgress and installs the navgraph/indexed handler", function()
    expect.truthy(definition.capabilities, "capabilities must be present at all")
    expect.eq(
      definition.capabilities,
      client.capabilities(),
      "must be the exact table the plugin's own start path builds, not a stripped-down copy"
    )
    expect.eq(definition.capabilities.window.workDoneProgress, false)
    expect.truthy(
      definition.handlers and type(definition.handlers["navgraph/indexed"]) == "function",
      "no navgraph/indexed handler: live refresh on reindex would not work on this route"
    )
  end)
end)

--- F7: `epicenter.client` must adopt a client `vim.lsp.enable` started, not
--- just describe it correctly - the client-level fix, complementing the
--- definition-shape test above.
describe("epicenter.client.adopt (F7)", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ lsp = { auto_start = false } })
  end)

  --- A fake client object: just enough of `vim.lsp.Client` for `adopt` to
  --- read (`id`, `name`, `config.root_dir`, `config.cmd`, `server_capabilities`).
  local function fake_client(over)
    return vim.tbl_extend("force", {
      id = 4242,
      name = "navgraph",
      config = { root_dir = "/proj", cmd = { "navgraph", "lsp" } },
      server_capabilities = { experimental = { navgraph = { protocolVersion = 1 } } },
    }, over or {})
  end

  it("routes a request through the adopted client's session", function()
    local sent = {}
    local original_request = require("epicenter.compat").lsp_request
    require("epicenter.compat").lsp_request = function(_, method, params, handler)
      table.insert(sent, method)
      handler(nil, { ok = true })
      return true, 1
    end
    -- get_client_by_id must resolve for M.stop/etc; adopt itself never calls
    -- it, so a fake with a matching id is enough for M.request's own lookups.
    local original_get = vim.lsp.get_client_by_id
    local fc = fake_client()
    vim.lsp.get_client_by_id = function(id)
      return id == fc.id and fc or original_get(id)
    end

    client.adopt(fc, nil)
    local got_err, got_result
    client.request("navgraph/status", {}, function(err, result)
      got_err, got_result = err, result
    end, { root = "/proj" })

    vim.lsp.get_client_by_id = original_get
    require("epicenter.compat").lsp_request = original_request

    expect.eq(got_err, nil)
    expect.eq(got_result, { ok = true })
    expect.eq(sent, { "navgraph/status" })
  end)

  it("does not adopt a second client over one epicenter already tracks", function()
    client.register_session("/proj", {
      request = function() end,
      dropped_count = function()
        return 0
      end,
    })
    -- register_session does not set a client_id, so `adopt` sees no live
    -- client for the existing entry and must fall through to adopting -
    -- exercise the branch where a live client IS already tracked instead.
    local first = fake_client({ id = 1 })
    local original_get = vim.lsp.get_client_by_id
    vim.lsp.get_client_by_id = function(id)
      if id == 1 then
        return first
      end
      return original_get(id)
    end
    client.adopt(first, nil)

    local second = fake_client({ id = 2 })
    client.adopt(second, nil)
    vim.lsp.get_client_by_id = original_get

    expect.eq(client.info("/proj").client_id, 1, "the incumbent client must not be replaced")
  end)
end)

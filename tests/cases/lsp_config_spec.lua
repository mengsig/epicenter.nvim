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
end)

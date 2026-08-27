local registry = require("epicenter.registry")

local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")

local function read(path)
  return table.concat(vim.fn.readfile(vim.fs.joinpath(repo, path)), "\n")
end

describe("documentation stays in sync", function()
  local doc = read("doc/epicenter.txt")
  local readme = read("README.md")

  it("documents every subcommand in the vimdoc and the README", function()
    for _, name in ipairs(registry.command_names()) do
      expect.truthy(doc:find(name, 1, true) ~= nil, "doc/epicenter.txt does not mention " .. name)
      expect.truthy(readme:find(name, 1, true) ~= nil, "README.md does not mention " .. name)
    end
  end)

  it("gives every feature its own vimdoc section tag", function()
    for _, spec in ipairs(registry.specs()) do
      local tag = ("*epicenter-%s*"):format(spec.name)
      expect.truthy(doc:find(tag, 1, true) ~= nil, "doc/epicenter.txt has no " .. tag)
    end
  end)

  it("documents every keymap the registry installs", function()
    local prefix = require("epicenter.config").defaults().keymaps.prefix
    for _, map in ipairs(registry.keymaps()) do
      local lhs = prefix .. map.suffix
      expect.truthy(doc:find(lhs, 1, true) ~= nil, "doc/epicenter.txt does not document " .. lhs)
      expect.truthy(readme:find(lhs, 1, true) ~= nil, "README.md does not document " .. lhs)
    end
  end)

  it("documents every derived highlight group", function()
    for _, group in ipairs(require("epicenter.ui.theme").GROUPS) do
      expect.truthy(
        doc:find(group, 1, true) ~= nil,
        "doc/epicenter.txt does not document " .. group
      )
    end
  end)

  it("documents every top-level config key", function()
    for key in pairs(require("epicenter.config").defaults()) do
      expect.truthy(doc:find(key, 1, true) ~= nil, "doc/epicenter.txt does not document " .. key)
      expect.truthy(readme:find(key, 1, true) ~= nil, "README.md does not document " .. key)
    end
  end)

  it("builds helptags", function()
    local ok = pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(vim.fs.joinpath(repo, "doc")))
    expect.eq(ok, true)
  end)

  it("advertises the same Neovim floor the code actually requires", function()
    local plugin = read("plugin/epicenter.lua")
    local health = read("lua/epicenter/health.lua")
    expect.matches(plugin, 'has%("nvim%-0%.11"%)', "the load gate must require 0.11")
    expect.matches(health, 'has%("nvim%-0%.11"%)', "checkhealth must require 0.11")
    expect.matches(readme, "Neovim 0%.11%+", "README must not undersell the floor")
    expect.matches(doc, "Neovim 0%.11%+", "vimdoc must not undersell the floor")
  end)
end)

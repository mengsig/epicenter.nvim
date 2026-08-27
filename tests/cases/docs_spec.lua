local registry = require("epicenter.registry")

local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")

local function read(path)
  return table.concat(vim.fn.readfile(vim.fs.joinpath(repo, path)), "\n")
end

--- Line-anchored `key = ` (or `key = {`), not a bare substring: the config
--- block is the only place a top-level key legitimately opens a value this
--- way, so this cannot pass by an incidental prose mention.
local function has_assignment_line(text, key)
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:match("^%s*" .. vim.pesc(key) .. "%s*=") then
      return true
    end
  end
  return false
end

describe("documentation stays in sync", function()
  local doc = read("doc/epicenter.txt")
  local readme = read("README.md")

  it("gives every ready subcommand a vimdoc tag and a README table row", function()
    -- A substring search here would pass even with the command's whole
    -- documentation block deleted (F14) - anchor on the structure instead:
    -- the tag every ready command's section carries, and the README
    -- command table's first cell.
    for _, name in ipairs(registry.command_names()) do
      if registry.command(name).status == "ready" then
        local tag = ("*:Epicenter-%s*"):format(name)
        expect.truthy(doc:find(tag, 1, true) ~= nil, "doc/epicenter.txt has no " .. tag)
        expect.truthy(
          readme:find("| `" .. name .. "`", 1, true) ~= nil,
          "README.md command table has no row for " .. name
        )
      end
    end
  end)

  it("announces every planned subcommand by name", function()
    for _, name in ipairs(registry.command_names()) do
      if registry.command(name).status == "planned" then
        expect.truthy(doc:find(name, 1, true) ~= nil, "doc/epicenter.txt does not mention " .. name)
        expect.truthy(readme:find(name, 1, true) ~= nil, "README.md does not mention " .. name)
      end
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

  it("documents every top-level config key with a real default line", function()
    -- Every top-level key name here (ui, log, search, ...) also occurs
    -- incidentally in prose throughout both files - anchor on the one place
    -- each key legitimately opens an assignment: its own default.
    for key in pairs(require("epicenter.config").defaults()) do
      expect.truthy(
        has_assignment_line(doc, key),
        "doc/epicenter.txt has no `" .. key .. " = ` default line"
      )
      expect.truthy(
        has_assignment_line(readme, key),
        "README.md has no `" .. key .. " = ` default line"
      )
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

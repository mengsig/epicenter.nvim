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

  it("lists every highlight group - core and feature-owned - in the canonical section", function()
    -- A group mentioned only in its own feature's subsection (e.g. ripples)
    -- would still pass a whole-document substring search, so slice out just
    -- the *epicenter-highlights* section and check membership there.
    local start = doc:find("*epicenter-highlights*", 1, true)
    expect.truthy(start ~= nil, "doc/epicenter.txt has no *epicenter-highlights* tag")
    local separator = ("="):rep(78)
    local stop = doc:find(separator, start, true) or (#doc + 1)
    local section = doc:sub(start, stop)

    local groups = vim.list_extend(
      vim.deepcopy(require("epicenter.ui.theme").GROUPS),
      require("epicenter.features.blast.ripples").GROUPS
    )
    for _, group in ipairs(groups) do
      expect.truthy(
        section:find(group, 1, true) ~= nil,
        "the *epicenter-highlights* section does not list " .. group
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

  it("gives every blast keymap a collision-safe help tag, not a bare one", function()
    local prefix = require("epicenter.config").defaults().keymaps.prefix
    for _, map in ipairs(registry.keymaps()) do
      if map.feature == "blast" then
        local lhs = prefix .. map.suffix
        expect.truthy(
          doc:find(("*epicenter-%s*"):format(lhs), 1, true) ~= nil,
          "doc/epicenter.txt has no *epicenter-" .. lhs .. "*"
        )
        expect.falsy(
          doc:find(("*%s*"):format(lhs), 1, true) ~= nil,
          "doc/epicenter.txt still has a bare *" .. lhs .. "* tag"
        )
      end
    end
  end)

  it("does not register a bare *K* help tag that hijacks Vim's builtin :help K", function()
    expect.falsy(doc:find("*K*", 1, true) ~= nil, "doc/epicenter.txt still has a bare *K* tag")
    expect.truthy(
      doc:find("*epicenter-K*", 1, true) ~= nil,
      "doc/epicenter.txt has no *epicenter-K* tag"
    )
  end)

  it("builds helptags", function()
    local ok = pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(vim.fs.joinpath(repo, "doc")))
    expect.eq(ok, true)
  end)

  it("links |vim.ui.open()| with the parens the real tag carries (merge-gate F10)", function()
    expect.falsy(
      doc:find("|vim.ui.open|", 1, true),
      "doc/epicenter.txt links the dangling |vim.ui.open| (the real tag has parens)"
    )
    expect.truthy(
      doc:find("|vim.ui.open()|", 1, true),
      "doc/epicenter.txt has no |vim.ui.open()| link"
    )
  end)

  it("advertises the same Neovim floor the code actually requires", function()
    local plugin = read("plugin/epicenter.lua")
    local health = read("lua/epicenter/health.lua")
    expect.matches(plugin, 'has%("nvim%-0%.10"%)', "the load gate must require 0.10")
    expect.matches(health, 'has%("nvim%-0%.10"%)', "checkhealth must require 0.10")
    expect.matches(readme, "Neovim 0%.10%+", "README must not oversell the floor")
    expect.matches(doc, "Neovim 0%.10%+", "vimdoc must not oversell the floor")
  end)

  it("agrees with the code on when the planned commands ship", function()
    -- planned.lua says "a later release"; the notice the user actually sees
    -- said "this release", and README/vimdoc repeated that wrong wording.
    local planned = read("lua/epicenter/features/planned.lua")
    local init = read("lua/epicenter/init.lua")
    expect.matches(planned, "a later release")
    expect.matches(init, "a later release")
    -- Case-insensitive (merge-gate F5): a plain find(..., 1, true) let
    -- README's capitalized sentence-opener "This release ships..." through.
    expect.falsy(readme:lower():find("this release", 1, true), "README must not say 'this release'")
    expect.falsy(doc:lower():find("this release", 1, true), "vimdoc must not say 'this release'")
  end)

  it("keeps the changelog's newest entry on the version the code reports", function()
    local changelog = read("CHANGELOG.md")
    local newest = changelog:match("\n## ([%d%.]+)") or changelog:match("^## ([%d%.]+)")
    expect.eq(
      newest,
      require("epicenter.version"),
      "lua/epicenter/version.lua and the top CHANGELOG entry must name the same release"
    )
  end)

  it("links every committed screenshot, and links nothing that is missing", function()
    local linked = {}
    for asset in readme:gmatch("%(assets/([%w%-%.]+)%)") do
      linked[asset] = true
      expect.truthy(
        vim.uv.fs_stat(vim.fs.joinpath(repo, "assets", asset)) ~= nil,
        "README links assets/" .. asset .. ", which is not in the repo"
      )
    end
    for _, path in ipairs(vim.fn.glob(repo .. "/assets/*", false, true)) do
      local name = vim.fs.basename(path)
      expect.truthy(linked[name], "assets/" .. name .. " is committed but nothing links it")
    end
    expect.truthy(next(linked) ~= nil, "the README must show at least one screenshot")
  end)

  it("qualifies every <C-k> mention with the panel it belongs to (F11)", function()
    -- <C-k> belongs to search (cycle the kind filter) and to outline; grep
    -- and the other panels have no binding for it. Substring presence alone
    -- would have passed with the old unqualified row - require the panel's
    -- name right there in the line, on every line that mentions the key.
    local rows = {}
    for _, line in ipairs(vim.split(readme, "\n", { plain = true })) do
      if line:find("<C-k>", 1, true) then
        table.insert(rows, line)
      end
    end
    expect.truthy(#rows > 0, "README must document <C-k>")
    for _, row in ipairs(rows) do
      expect.truthy(
        row:lower():find("search", 1, true) or row:lower():find("outline", 1, true),
        "a <C-k> line must name the panel it applies to: " .. row
      )
    end
  end)
end)

--- The keymap table, the command table and the config reference are rendered
--- from the registry (`make docs-check` diffs them against README/vimdoc).
--- These are the rules that rendering has to keep, wherever it is written out.
describe("the generated doc tables", function()
  local docs = require("epicenter.docs")

  before_each(function()
    require("epicenter.config").reset()
  end)

  it("gives every installed keymap a row, with its command's description", function()
    local rows = docs.keymap_rows()
    expect.eq(#rows, #registry.keymaps())
    local prefix = require("epicenter.config").defaults().keymaps.prefix
    for index, map in ipairs(registry.keymaps()) do
      expect.eq(rows[index].lhs, prefix .. map.suffix)
      expect.eq(rows[index].desc, registry.command(map.command).desc)
    end
  end)

  it("gives every subcommand a row, in registration order", function()
    expect.eq(
      vim.tbl_map(function(row)
        return row.name
      end, docs.command_rows()),
      registry.command_names()
    )
  end)

  it("lists the options whose default is nil, which the defaults table cannot hold", function()
    local block = table.concat(docs.defaults_lines(), "\n")
    for _, path in ipairs(require("epicenter.config").OPTIONAL_PATHS) do
      local leaf = path:match("[^.]+$")
      expect.matches(block, leaf .. " = nil,", path .. " is missing from the config reference")
    end
  end)

  it("renders every top-level option exactly once", function()
    local block = docs.defaults_lines()
    for key in pairs(require("epicenter.config").defaults()) do
      local seen = 0
      for _, line in ipairs(block) do
        if line:match("^  " .. vim.pesc(key) .. " = ") then
          seen = seen + 1
        end
      end
      expect.eq(seen, 1, key .. " should appear once at the top level")
    end
  end)

  it("only comments a path some option actually owns", function()
    local config = require("epicenter.config")
    --- `and/or` would collapse a `false` default (blast.strict) to nil here.
    local function exists(defaults, path)
      local at = defaults
      for _, part in ipairs(vim.split(path, ".", { plain = true })) do
        if type(at) ~= "table" then
          return false
        end
        at = at[part]
        if at == nil then
          return false
        end
      end
      return true
    end

    local defaults = config.defaults()
    for path in pairs(config.option_docs()) do
      expect.truthy(
        exists(defaults, path) or vim.tbl_contains(config.OPTIONAL_PATHS, path),
        path .. " is documented but is not an option"
      )
    end
  end)

  it("refuses a feature that documents an option it does not own", function()
    local specs = require("epicenter.features")
    local original = vim.deepcopy(specs[1].option_docs or {})
    specs[1].option_docs = { ["ui.width"] = "not mine" }
    registry.reset()
    expect.errors(function()
      registry.option_docs()
    end, "does not own")
    specs[1].option_docs = next(original) and original or nil
    registry.reset()
  end)
end)

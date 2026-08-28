--- The search and grep palettes, end to end against the real index.
local epicenter = require("epicenter")
local support = require("support")

local function open_fixture(root, relative)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  return vim.api.nvim_get_current_buf()
end

describe("real navgraph: the search palette", function()
  local root, buf, palette

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()
    buf = open_fixture(root, "py_fastapi/app/services/user_service.py")
  end)

  after_each(function()
    if palette then
      palette:close()
      palette = nil
    end
  end)

  --- Waits for the palette to hold a result the predicate accepts.
  local function first_matching(p, pred, label)
    return wait(function()
      for _, item in ipairs(p.list:items()) do
        if pred(item) then
          return item
        end
      end
      return nil
    end, 15000, label)
  end

  it("ranks a real symbol query and carries its match offsets", function()
    palette = epicenter.run("search", {}, buf)
    palette:query("UserService.fetch")
    local item = first_matching(palette, function(entry)
      return entry.symbol and entry.symbol.qualified == "UserService.fetch"
    end, "UserService.fetch in the search results")

    expect.eq(item.symbol.file, "py_fastapi/app/services/user_service.py")
    expect.eq(item.symbol.kind, "method")
    expect.eq(item.symbol.language, "py")
    expect.truthy(#(item.matches or {}) > 0, "match offsets into `qualified`")
    expect.truthy(item.symbol.callers > 0, "the routes layer calls it")
  end)

  it("reaches a second language from the same palette", function()
    palette = epicenter.run("search", {}, buf)
    palette:query("Vec.add")
    local item = first_matching(palette, function(entry)
      return entry.symbol and entry.symbol.file:match("%.lua$") ~= nil
    end, "a Lua symbol in the search results")
    expect.eq(item.symbol.language, "lua")
  end)

  it("greps the real sources, with the enclosing definition per hit", function()
    palette = epicenter.run("grep", {}, buf)
    palette:query("normalize_email")
    local item = first_matching(palette, function(entry)
      return entry.file == "py_fastapi/app/services/user_service.py"
        and entry.text ~= nil
        and entry.text:find("clean = normalize_email", 1, true) ~= nil
    end, "the normalize_email call inside UserService.create")

    expect.eq(item.line, 24, "grep line numbers are 1-based")
    expect.eq(item.character, 16, "grep columns are 0-based")
    expect.eq(item.enclosing.qualified, "UserService.create", "the hit's enclosing definition")
  end)

  it("greps the unsaved buffer, not the copy on disk", function()
    local marker = "epicenter_real_lane_marker_" .. tostring(vim.uv.hrtime())
    local original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    support.attach(root, buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# " .. marker })

    palette = epicenter.run("grep", {}, buf)
    palette:query(marker)
    local item = first_matching(palette, function(entry)
      return entry.text ~= nil and entry.text:find(marker, 1, true) ~= nil
    end, "the unsaved marker line")
    expect.eq(item.file, "py_fastapi/app/services/user_service.py")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
    vim.bo[buf].modified = false
  end)
end)

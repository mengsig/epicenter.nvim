local core = require("epicenter.features.core")
local support = require("support")

local STATUS = {
  version = "fake-0.1.0",
  files = 3,
  symbols = 9,
  edges = 7,
  overlays = 1,
  lastIndexMs = 4,
  indexedAt = "2026-08-28T09:00:00Z",
  languages = { [".lua"] = 2, [".py"] = 1 },
}

local function render(over)
  return core.dashboard_lines(vim.tbl_extend("force", {
    root = "/proj",
    status = STATUS,
    server = { running = true, client_id = 1, protocol = 1, restarts = 0, pid = 4321 },
    log = "/state/epicenter.log",
  }, over or {}))
end

local function text(over)
  return table.concat(render(over).lines, "\n")
end

describe("status dashboard", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("reports the root, the server and what the index holds", function()
    local body = text()
    expect.matches(body, "root%s+/proj")
    expect.matches(body, "running")
    expect.matches(body, "pid 4321")
    expect.matches(body, "navgraph fake%-0%.1%.0")
    expect.matches(body, "protocol 1")
    expect.matches(body, "3 files · 9 symbols · 7 edges")
    expect.matches(body, "1 unsaved")
    expect.matches(body, "4ms  2026%-08%-28")
    expect.matches(body, "/state/epicenter%.log")
  end)

  it("draws a bar per language, scaled to the busiest one", function()
    local body = text()
    expect.matches(body, "%.lua%s+##########%s2")
    expect.matches(body, "%.py%s+#####-----%s1")
  end)

  it("names the LSP client when the server reports no pid", function()
    local body = text({ server = { running = true, client_id = 7, protocol = 1, restarts = 0 } })
    expect.matches(body, "client 7")
    expect.falsy(body:match("pid"))
  end)

  it("counts the restarts it has needed", function()
    expect.matches(
      text({ server = { running = true, client_id = 1, protocol = 1, restarts = 2 } }),
      "2 restarts"
    )
  end)

  it("says plainly when the server did not answer", function()
    local rendered = core.dashboard_lines({
      root = "/proj",
      server = { running = false, restarts = 0 },
      error = "navgraph is not running for this project",
      log = "/state/epicenter.log",
    })
    local body = table.concat(rendered.lines, "\n")
    expect.matches(body, "stopped")
    expect.matches(body, "index%s+navgraph is not running")
    expect.falsy(body:match("files"), "no invented counts")
  end)

  it("highlights the label of every row", function()
    local rendered = render()
    local labels = vim.tbl_filter(function(span)
      return span.hl == "EpicenterMuted"
    end, rendered.spans)
    expect.truthy(#labels >= 6)
    for _, span in ipairs(labels) do
      expect.matches(rendered.lines[span.row + 1]:sub(span.from + 1, span.to), "^%a")
    end
  end)

  it("sizes to the content instead of a fixed 62x14 (F14)", function()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
    local few = core.box_for({ "", "  root ~/proj", "  server running", "" })
    local many = core.box_for(vim.list_extend(
      { "" },
      (function()
        local languages = {}
        for i = 1, 8 do
          table.insert(languages, ("  lang-%d              ########## %d"):format(i, i))
        end
        return languages
      end)()
    ))
    expect.truthy(many.height > few.height, "more content rows means a taller box")
    expect.truthy(many.height >= 8, "does not clip the language list")
  end)
end)

describe("status dashboard against the fake navgraph server", function()
  local root, buf, win, log_path

  local function press(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(win.buf, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no mapping for " .. lhs)
  end

  local function body()
    return table.concat(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), "\n")
  end

  before_each(function()
    log_path = vim.fn.tempname() .. "/epicenter.log"
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      log = { file = log_path },
    })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if win and win:valid() then
      win:close()
    end
    win = nil
    require("epicenter.events").clear()
  end)

  it("shows what the running server reports", function()
    win = require("epicenter").run("status", {}, buf)
    wait(function()
      return body():match("3 files") ~= nil
    end, 10000, "status dashboard")
    expect.matches(body(), "running")
    expect.matches(body(), "protocol 1")
    expect.matches(body(), "lua%s+#")
    expect.matches(body(), vim.pesc(vim.fn.fnamemodify(log_path, ":~")))
  end)

  it("offers rescan, restart and log as actions", function()
    win = require("epicenter").run("status", {}, buf)
    local mapped = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(win.buf, "n")) do
      mapped[map.lhs] = true
    end
    for _, lhs in ipairs({ "r", "R", "l", "q" }) do
      expect.truthy(mapped[lhs], "the dashboard maps " .. lhs)
    end
  end)

  it("rescans and repaints on r", function()
    win = require("epicenter").run("status", {}, buf)
    wait(function()
      return body():match("3 files") ~= nil
    end, 10000, "status dashboard")

    local reindexed = false
    require("epicenter.events").on(require("epicenter.events").INDEXED, function(payload)
      reindexed = reindexed or payload.reason == "rescan"
    end)
    press("r")
    wait(function()
      return reindexed
    end, 10000, "the rescan reached the server")
    wait(function()
      return body():match("3 files") ~= nil
    end, 10000, "the dashboard repainted")
  end)

  it("closes and says so when there is nothing logged yet", function()
    win = require("epicenter").run("status", {}, buf)
    local toast = require("epicenter.ui.toast")
    local original, notices = toast.notify, {}
    toast.notify = function(msg)
      table.insert(notices, tostring(msg))
    end
    press("l")
    toast.notify = original
    expect.falsy(win:valid(), "the dashboard steps aside for the log")
    expect.matches(table.concat(notices, "\n"), "nothing logged yet")
  end)
end)

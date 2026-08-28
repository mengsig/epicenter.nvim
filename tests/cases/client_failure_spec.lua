--- What happens when the binary on `$PATH` cannot serve (merge-gate F7).
---
--- The likely first run is not "no navgraph at all" - it is a navgraph
--- installed before the editor server shipped. That binary answers
--- `--version` perfectly, exits 2 on every `lsp` start, and used to produce
--- one raw "Client navgraph quit with exit code 2" per restart, an 8-second
--- toast naming no cause, and a `:checkhealth` with two green ticks on the
--- broken thing and "no navgraph server running yet" underneath.
local client = require("epicenter.client")
local install = require("epicenter.install")

--- A navgraph stand-in. `--version` answers the capabilities document with
--- `commands` as given; every other argv exits 2, exactly as the real stale
--- build answers `navgraph: unknown command 'lsp'`.
--- @param commands string[]
local function shim(commands)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "navgraph")
  local document = vim.json.encode({
    schema = "navgraph.capabilities.v1",
    build = { version = "0.1.0", buildVersion = "0.1.0+src.4fa0c1cf" },
    commands = vim.tbl_map(function(name)
      return { name = name }
    end, commands),
  })
  local file = assert(io.open(path, "w"))
  file:write(
    ('#!/bin/sh\nif [ "$1" = "--version" ]; then\n  cat <<\'JSON\'\n%s\nJSON\n  exit 0\nfi\nexit 2\n'):format(
      document
    )
  )
  file:close()
  assert(vim.uv.fs_chmod(path, 493))
  return require("support").own_binary(path), dir
end

local function health_report()
  vim.cmd("silent checkhealth epicenter")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("bwipeout!")
  return text
end

describe("a navgraph that cannot serve", function()
  local root, path, dir, notices, original_notify

  before_each(function()
    require("epicenter.config").reset()
    install.forget_capabilities()
    install.forget_first_run_notice()
    path, dir = shim({ "search", "outline" })
    root = dir
    require("epicenter.config").setup({ navgraph = { path = path }, lsp = { auto_start = false } })
    notices = {}
    original_notify = require("epicenter.ui.toast").notify
    require("epicenter.ui.toast").notify = function(message, opts)
      table.insert(notices, { message = message, level = opts and opts.level })
    end
  end)

  after_each(function()
    require("epicenter.ui.toast").notify = original_notify
    client.stop(root)
    install.forget_capabilities()
    install.forget_first_run_notice()
    vim.fn.delete(dir, "rf")
  end)

  it("reads what the binary can do out of its own capabilities document", function()
    local caps = install.capabilities(path)
    expect.eq(caps.version, "0.1.0+src.4fa0c1cf")
    expect.eq(caps.documented, true)
    expect.eq(caps.commands.search, true)
    expect.eq(install.serves_lsp(caps), false)
    expect.matches(install.unservable_reason(path), "has no `lsp` command")
  end)

  it("refuses to start it at all, rather than spawning it four times", function()
    local before = #_G.EPICENTER_TEST_NAVGRAPH_SPAWNS
    local id, err = client.start({ root = root })

    expect.eq(id, nil)
    expect.matches(err, "has no `lsp` command")
    expect.matches(err, vim.pesc(path))
    expect.eq(
      #_G.EPICENTER_TEST_NAVGRAPH_SPAWNS,
      before,
      "a binary that cannot serve must never be spawned, let alone restarted"
    )
  end)

  it("keeps the root's record, so health can say what happened", function()
    client.start({ root = root })
    local info = client.info(root)
    expect.truthy(info.failed, "the failure record must outlive the failure")
    expect.matches(info.failed.reason, "has no `lsp` command")
    expect.truthy(vim.tbl_contains(client.roots(), root), "health reads roots()")
  end)

  it("does not walk back into the same failure on the next buffer", function()
    client.start({ root = root })
    local before = #_G.EPICENTER_TEST_NAVGRAPH_SPAWNS
    local id, err = client.start({ root = root })
    expect.eq(id, nil)
    expect.matches(err, "has no `lsp` command")
    expect.eq(#_G.EPICENTER_TEST_NAVGRAPH_SPAWNS, before)
  end)

  it("answers a request with the reason instead of a bare 'not running'", function()
    client.start({ root = root })
    local err
    client.request("navgraph/status", {}, function(e)
      err = e
    end, { root = root })
    expect.truthy(err, "the request must fail")
    expect.matches(err.message, "has no `lsp` command")
    expect.matches(err.message, "checkhealth epicenter")
  end)

  it("says it once, naming the cause and the remedy", function()
    install.announce("epicenter: " .. path .. " is navgraph 0.1.0, which has no `lsp` command")
    install.announce("epicenter: " .. path .. " is navgraph 0.1.0, which has no `lsp` command")
    expect.eq(#notices, 1, "one toast, however many buffers open")
    expect.matches(notices[1].message, "has no `lsp` command")
    expect.matches(notices[1].message, ":Epicenter install")
  end)

  it("reports the cause and the log path in :checkhealth, not two green ticks", function()
    client.start({ root = root })
    local report = health_report()
    expect.matches(report, "navgraph binary: " .. vim.pesc(path))
    expect.matches(report, "navgraph version: 0%.1%.0%+src%.4fa0c1cf")
    expect.matches(report, "no `lsp` command")
    expect.matches(report, ":Epicenter install")
    expect.matches(report, vim.pesc(require("epicenter.log").path()))
    expect.falsy(
      report:find("no navgraph server running yet", 1, true),
      "a server that failed to start is not a server that was never asked for"
    )
  end)

  it("clears what it learned when a restart says the binary may have changed", function()
    expect.matches(install.unservable_reason(path), "no `lsp` command")
    -- Same path, a build that now serves: only a restart (or an install)
    -- makes the session ask again.
    local file = assert(io.open(path, "w"))
    file:write(
      '#!/bin/sh\nif [ "$1" = "--version" ]; then\n  echo \'{"commands":[{"name":"lsp"}],"build":{"version":"1.0.0"}}\'\n  exit 0\nfi\nexit 2\n'
    )
    file:close()
    expect.matches(install.unservable_reason(path), "no `lsp` command", "still the cached answer")
    install.forget_capabilities()
    expect.eq(install.unservable_reason(path), nil)
  end)
end)

--- The other half of F7: a binary that passes the capability probe and then
--- dies anyway. The restart streak runs out and the root's record used to be
--- DELETED, which is what left `:checkhealth` reporting "no navgraph server
--- running yet" seconds after four crashes.
describe("a navgraph that starts and then crash-loops", function()
  local root, path, dir, notices, original_notify

  before_each(function()
    require("epicenter.config").reset()
    install.forget_capabilities()
    install.forget_first_run_notice()
    -- Advertises `lsp`, so the probe lets it through; exits 2 on every start.
    path, dir = shim({ "lsp" })
    root = dir
    require("epicenter.config").setup({
      navgraph = { path = path },
      lsp = { auto_start = false, restart = { max = 2, backoff_ms = { 10, 10 } } },
    })
    notices = {}
    original_notify = require("epicenter.ui.toast").notify
    require("epicenter.ui.toast").notify = function(message, opts)
      table.insert(notices, { message = message, level = opts and opts.level })
    end
  end)

  after_each(function()
    require("epicenter.ui.toast").notify = original_notify
    client.stop(root)
    install.forget_capabilities()
    vim.fn.delete(dir, "rf")
  end)

  it("keeps the failure on the record, and says it once with the log path", function()
    require("support").expect_exit_notice("simulating a crash-looping server")
    client.start({ root = root })

    local info = wait(function()
      local current = client.info(root)
      return current.failed and current or nil
    end, 20000, "the server to give up")

    expect.matches(info.failed.reason, "stopped after 2 restarts")
    expect.matches(info.failed.at, "^%d%d%d%d%-%d%d%-%d%d")
    expect.truthy(vim.tbl_contains(client.roots(), root), "the root must stay visible to health")

    expect.eq(#notices, 1, "one toast, not one per restart")
    expect.eq(notices[1].level, "error")
    expect.matches(notices[1].message, "stopped after 2 restarts")
    expect.matches(notices[1].message, vim.pesc(require("epicenter.log").path()))

    local report = health_report()
    expect.matches(report, "stopped after 2 restarts")
    expect.falsy(report:find("no navgraph server running yet", 1, true))
  end)
end)

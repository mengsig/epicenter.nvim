--- The tour: it runs the steps it promises, it stops when asked, and it never
--- starts on its own. No server here - the tour drives OTHER commands, each
--- covered against the fake in its own spec, and what this owes is the
--- sequence.
local epicenter = require("epicenter")
local tour = require("epicenter.features.tour")

describe("the tour", function()
  local buf, state_dir, notices

  before_each(function()
    -- Captured BEFORE anything can index: the first-run offer is raised from
    -- the first reindex, which the fake server sends the moment it is up.
    notices = {}
    epicenter.notify = function(msg)
      table.insert(notices, msg)
    end

    require("epicenter.config").reset()
    state_dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(state_dir, "p")
    require("epicenter.store").set_root(state_dir)

    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    tour.reset()
    -- A float still on screen when the next test edits a file aborts
    -- headless Neovim in grid_line_flush; a toast is one.
    require("epicenter.ui.toast").clear()
    require("epicenter.store").set_root(nil)
    require("epicenter.events").clear()
  end)

  it("every step names a subcommand that exists", function()
    local registry = require("epicenter.registry")
    for _, step in ipairs(tour.STEPS) do
      expect.truthy(step.text ~= "" and step.ms > 0, "a step says something, for a while")
      if step.command then
        expect.truthy(registry.command(step.command) ~= nil, step.command .. " is not a command")
      end
    end
  end)

  it("runs for about a minute", function()
    local total = 0
    for _, step in ipairs(tour.STEPS) do
      total = total + step.ms
    end
    expect.truthy(total >= 45000 and total <= 75000, "a minute, give or take: " .. total)
  end)

  it("runs the steps it promises, and stops when asked", function()
    -- The panels themselves are each covered by their own spec; what the
    -- tour owes is the SEQUENCE. Recording it also keeps a float off the
    -- screen: headless Neovim aborts in grid_line_flush when one is still up
    -- as the next test edits a file.
    local run, driven = epicenter.run, {}
    epicenter.run = function(name, args, bufnr)
      if name ~= "tour" then
        table.insert(driven, name)
        return nil
      end
      return run(name, args, bufnr)
    end

    epicenter.run("tour", {}, buf)
    expect.truthy(tour.running())
    wait(function()
      return #driven > 0
    end, 15000, "the first step's panel")
    expect.eq(driven[1], tour.STEPS[2].command, "step 2 is the first with a panel")

    epicenter.run("tour", {}, buf)
    expect.falsy(tour.running(), "the same command stops a running tour")
    expect.matches(table.concat(notices, "\n"), "tour stopped")
    epicenter.run = run
  end)

  it("closes the timer it stops, rather than leaking a uv handle", function()
    local timers = {}
    local original_defer = vim.defer_fn
    vim.defer_fn = function(fn, ms)
      local timer = original_defer(fn, ms)
      table.insert(timers, timer)
      return timer
    end
    local run = epicenter.run
    epicenter.run = function(name, args, bufnr)
      -- The steps' own panels are covered by their own specs; keep them off
      -- the screen here.
      return name == "tour" and run(name, args, bufnr) or nil
    end

    epicenter.run("tour", {}, buf)
    expect.truthy(#timers > 0, "the tour armed a step timer")
    epicenter.run("tour", {}, buf)
    expect.falsy(tour.running(), "the same command stops it")

    epicenter.run = run
    vim.defer_fn = original_defer
    for _, timer in ipairs(timers) do
      expect.truthy(timer:is_closing(), "an interrupted tour closes the handle it stopped")
    end
  end)

  it("says why the first-run offer could not be remembered", function()
    local store = require("epicenter.store")
    local log = require("epicenter.log")
    local original_write, original_warn = store.write, log.warn
    local warned = {}
    store.write = function()
      return false, "the state directory is read-only"
    end
    log.warn = function(fmt, ...)
      table.insert(warned, string.format(fmt, ...))
    end

    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    local ok = vim.wait(5000, function()
      return #warned > 0
    end, 10)
    store.write, log.warn = original_write, original_warn
    expect.truthy(ok, "an offer that cannot be remembered says so, or it comes back forever")
    expect.matches(warned[1], "read%-only")
  end)

  it("offers itself once, and never starts itself", function()
    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    wait(function()
      return table.concat(notices, "\n"):find(":Epicenter tour", 1, true) ~= nil
    end, 5000, "the first-run offer")
    expect.falsy(tour.running(), "an offer is not a start")

    notices = {}
    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    vim.wait(200)
    expect.eq(notices, {}, "the offer is made once, ever")
  end)
end)

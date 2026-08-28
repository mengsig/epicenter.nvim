local animate = require("epicenter.ui.animate")
local badges = require("epicenter.features.blast.badges")
local support = require("support")

local SYMBOLS = {
  { qualified = "M.route", line = 3, endLine = 6, callers = 1, callees = 0 },
  { qualified = "M.load_config", line = 7, endLine = 11, callers = 0, callees = 2 },
}

local function badge_at(bufnr, line)
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    badges.namespace,
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )
  local mark = marks[1]
  return mark and mark[4].virt_text[1][1] or nil
end

local function badge_count(bufnr)
  return #vim.api.nvim_buf_get_extmarks(bufnr, badges.namespace, 0, -1, {})
end

describe("badge placement", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, lsp = { auto_start = false } })
  end)

  it("reads as fan-in then fan-out", function()
    expect.eq(badges.text({ callers = 12, callees = 4 }), "<- 12  -> 4")
    expect.eq(badges.text({}), "<- 0  -> 0")
  end)

  it("badges the innermost definition the cursor is inside", function()
    expect.eq(badges.entries(SYMBOLS, "cursor", 4), { { line = 3, text = "<- 1  -> 0" } })
    expect.eq(badges.entries(SYMBOLS, "cursor", 8), { { line = 7, text = "<- 0  -> 2" } })
  end)

  it("badges nothing when the cursor is outside every definition", function()
    expect.eq(badges.entries(SYMBOLS, "cursor", 1), {})
  end)

  it("badges every definition in `all` mode", function()
    expect.eq(badges.entries(SYMBOLS, "all", 1), {
      { line = 3, text = "<- 1  -> 0" },
      { line = 7, text = "<- 0  -> 2" },
    })
  end)
end)

describe("badges against the fake navgraph server", function()
  local root, buf

  local function reopen(relative, line)
    local path = vim.fs.joinpath(root, relative)
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    return vim.api.nvim_get_current_buf()
  end

  -- The full `setup()`, not just config: the badge autocmds installed by an
  -- earlier spec file still hold that file's module instance, which the
  -- harness has since unloaded. Re-running setup rewires them to this one.
  local function configure(opts)
    require("epicenter.config").reset()
    require("epicenter").setup(
      vim.tbl_extend("force", { ui = { icons = "ascii" }, animate = false }, opts or {})
    )
    require("epicenter.ui.theme").apply()
  end

  before_each(function()
    configure()
    root = root or support.start_fake()
    buf = reopen("app/config.lua", 4)
  end)

  after_each(function()
    badges.clear(buf)
  end)

  local function fetched(bufnr, opts)
    badges.fetch(bufnr, opts)
    wait(function()
      return badges.outline_of(bufnr) ~= nil
    end, 10000, "outline")
  end

  it("badges the definition the cursor sits in", function()
    fetched(buf)
    expect.eq(badge_at(buf, 3), "  <- 1  -> 0", "M.route is called once, calls nothing")
    expect.eq(badge_count(buf), 1)
  end)

  it("badges every definition in `all` mode", function()
    configure({ badges = "all" })
    fetched(buf)
    expect.eq(badge_count(buf), 2)
    expect.eq(badge_at(buf, 3), "  <- 1  -> 0")
    expect.eq(badge_at(buf, 7), "  <- 0  -> 0")
  end)

  it("places nothing when badges are off", function()
    configure({ badges = false })
    badges.fetch(buf)
    vim.wait(200)
    expect.eq(badge_count(buf), 0)
  end)

  it("costs one round trip per generation, not one per trigger (#F7)", function()
    local client = require("epicenter.client")
    local original = client.outline
    local calls = 0
    client.outline = function(...)
      calls = calls + 1
      return original(...)
    end

    fetched(buf)
    -- The fake server's own indexing can push a few `navgraph/indexed`
    -- notifications right after a buffer opens; let that settle before
    -- asserting anything about round-trip counts.
    local settled = false
    vim.wait(3000, function()
      local before = calls
      vim.wait(150)
      settled = calls == before
      return settled
    end, 50)
    expect.truthy(settled, "the fake server's own indexing churn must quiet down")
    local baseline = calls

    -- A burst of fetches for the same (now settled) state - as BufEnter and
    -- BufWinEnter firing together would produce - must cost nothing more.
    badges.fetch(buf)
    badges.fetch(buf)
    badges.fetch(buf)
    vim.wait(300)
    expect.eq(calls, baseline, "an unchanged buffer state must not re-fetch")

    -- A genuine reindex with no local edit still invalidates the cache,
    -- exactly once.
    local events = require("epicenter.events")
    events.emit(events.INDEXED, {})
    wait(function()
      return calls > baseline
    end, 10000, "the reindex-triggered fetch")
    vim.wait(300)
    expect.eq(calls, baseline + 1, "a reindex must cost exactly one more round trip")

    client.outline = original
  end)

  it("cancels the reveal tween on a buffer wipe instead of leaking it (#F8)", function()
    local manual = animate.manual_driver()
    local now = 0
    badges.place(buf, { { line = 3, text = "<- 1  -> 0" } }, {
      animate = {
        motion = true,
        driver = manual.driver,
        duration = 100,
        clock = function()
          return now
        end,
      },
    })
    expect.truthy(manual.running(), "the reveal tween is running")

    vim.api.nvim_buf_delete(buf, { force = true })

    expect.falsy(manual.running(), "wiping the buffer must cancel its reveal tween")
  end)

  it("follows the cursor to another definition", function()
    fetched(buf)
    expect.eq(badge_at(buf, 3), "  <- 1  -> 0")

    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    badges.refresh(buf)
    expect.eq(badge_at(buf, 3), nil)
    expect.eq(badge_at(buf, 7), "  <- 0  -> 0")
  end)

  it("reveals the badge left to right", function()
    local manual = animate.manual_driver()
    local now = 0
    badges.place(buf, { { line = 3, text = "<- 1  -> 0" } }, {
      animate = {
        motion = true,
        driver = manual.driver,
        duration = 100,
        clock = function()
          return now
        end,
      },
    })

    now = 25
    manual.step()
    local quarter = badge_at(buf, 3)
    expect.truthy(quarter ~= nil and #quarter < #"  <- 1  -> 0", "the badge starts partial")

    now = 100
    manual.step()
    expect.eq(badge_at(buf, 3), "  <- 1  -> 0", "and lands on the full badge")
    expect.falsy(manual.running())
  end)

  it("installs its autocmds only when badges are on", function()
    badges.setup({ badges = false })
    expect.eq(#vim.api.nvim_get_autocmds({ group = "EpicenterBadges" }), 0)

    badges.setup({ badges = "cursor" })
    local events = vim.tbl_map(function(autocmd)
      return autocmd.event
    end, vim.api.nvim_get_autocmds({ group = "EpicenterBadges" }))
    for _, event in ipairs({ "BufEnter", "CursorHold", "User" }) do
      expect.truthy(vim.tbl_contains(events, event), "no autocmd for " .. event)
    end
    badges.setup({ badges = false })
  end)
end)

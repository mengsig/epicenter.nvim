--- `epicenter.setup()`'s feature-wiring seam (#F11): every feature's own
--- `setup(cfg)` is called, a failure is wrapped with the feature's name
--- rather than swallowed, and a second `setup()` re-runs it cleanly.
local function fake_features(specs)
  package.loaded["epicenter.features"] = specs
  require("epicenter.registry").reset()
end

local function restore()
  package.loaded["epicenter.features"] = nil
  require("epicenter.registry").reset()
  require("epicenter.config").reset()
end

describe("epicenter.setup wires up feature setup", function()
  after_each(restore)

  it("calls every feature's setup with the resolved config", function()
    local seen
    fake_features({
      {
        name = "probe",
        summary = "probe",
        commands = {},
        setup = function(cfg)
          seen = cfg
        end,
      },
    })
    local cfg =
      require("epicenter").setup({ ui = { icons = "ascii" }, lsp = { auto_start = false } })
    expect.truthy(seen ~= nil, "the feature's setup was never called")
    expect.eq(seen, cfg)
  end)

  it("wraps a feature's setup failure with its name, not a bare error", function()
    fake_features({
      {
        name = "broken",
        summary = "broken",
        commands = {},
        setup = function()
          error("boom")
        end,
      },
    })
    expect.errors(function()
      require("epicenter").setup({ lsp = { auto_start = false } })
    end, "broken")
  end)

  it("is idempotent: a second setup() re-runs every feature's setup cleanly", function()
    local calls = 0
    fake_features({
      {
        name = "probe",
        summary = "probe",
        commands = {},
        setup = function()
          calls = calls + 1
        end,
      },
    })
    require("epicenter").setup({ lsp = { auto_start = false } })
    require("epicenter").setup({ lsp = { auto_start = false } })
    expect.eq(calls, 2, "a second setup() must not skip or duplicate a feature's own setup")
  end)
end)

local epicenter = require("epicenter")

describe("keymap install and teardown", function()
  after_each(function()
    epicenter.reset()
  end)

  it("rejects keymaps = true instead of crashing setup() on the first keypress", function()
    expect.errors(function()
      epicenter.setup({ keymaps = true })
    end, "keymaps must be a table or `false`")
  end)

  it("removes every installed keymap on reset(), not just the config", function()
    -- F5: auto_start default true would sweep any stale buffer a prior spec
    -- left loaded and resolve a real $PATH navgraph - irrelevant to this test.
    epicenter.setup({ keymaps = { prefix = "<leader>Z" }, lsp = { auto_start = false } })
    expect.truthy(vim.fn.maparg("<leader>Zs", "n") ~= "", "setup() must have installed the keymap")

    epicenter.reset()

    expect.eq(vim.fn.maparg("<leader>Zs", "n"), "", "reset() must remove the keymaps it installed")
  end)
end)

describe("attach sweep on setup (F19)", function()
  after_each(function()
    epicenter.reset()
  end)

  it("attaches a buffer already loaded before setup(), not only future BufReadPost", function()
    -- Stub attach before editing: an earlier test's setup() may already have
    -- installed the real BufReadPost autocmd, which would otherwise fire a
    -- real client.attach() the instant the buffer is opened below.
    local client = require("epicenter.client")
    local attached = {}
    local original_attach = client.attach
    client.attach = function(bufnr)
      table.insert(attached, bufnr)
    end

    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "return {}" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    local ok = pcall(epicenter.setup, {})

    client.attach = original_attach
    vim.fn.delete(path)

    expect.eq(ok, true)
    expect.truthy(
      vim.tbl_contains(attached, buf),
      "a buffer already loaded before setup() must still be attached"
    )
  end)
end)

--- H1: a byte-identical copy of this file shipped at lua/epicenter/ui/init.lua
--- and passed every other check because nothing loads it. `did_setup` is the
--- entry point's own module-level sentinel - a second file defining it would
--- be a second, independent `setup()`/`reset()` with its own keymap state.
describe("the plugin has exactly one entry point", function()
  it("has only lua/epicenter/init.lua define the setup sentinel", function()
    local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")
    local offenders = {}
    for _, path in ipairs(vim.fn.globpath(vim.fs.joinpath(repo, "lua"), "**/*.lua", false, true)) do
      local content = table.concat(vim.fn.readfile(path), "\n")
      if content:find("local did_setup = false", 1, true) then
        table.insert(offenders, vim.fn.fnamemodify(path, ":."))
      end
    end
    expect.eq(
      offenders,
      { "lua/epicenter/init.lua" },
      "exactly one module may define the plugin setup entry point"
    )
  end)
end)

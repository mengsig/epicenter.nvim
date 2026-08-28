--- The Telescope extension: never loaded unless Telescope is, and once it
--- is, its pickers drive the same navgraph calls the palette/blast panel use.
--- `package.loaded["telescope*"]` is stubbed per-test and torn down in
--- `after_each` - those names do not match `harness.isolate()`'s cleanup
--- prefixes, so a leaked stub would otherwise reach every later spec file.
local support = require("support")

local TELESCOPE_MODULES = {
  "telescope",
  "telescope.pickers",
  "telescope.finders",
  "telescope.config",
  "telescope.actions",
  "telescope.actions.state",
  "telescope.sorters",
  "telescope._extensions.epicenter",
  "epicenter.telescope",
}

--- A fake `telescope.pickers.new(...)` picker: records what it was built
--- with, runs `attach_mappings` the way `:find()` would (against a real
--- scratch buffer, so `TextChangedI`/`BufWipeout` autocmds are real), and
--- `refresh()` just swaps in the finder like the real one does.
local function install_stub()
  local telescope_stub = { extensions = {} }
  telescope_stub.register_extension = function(mod)
    -- Real Telescope resolves the extension name from the registering
    -- file's own path (`_extensions/<name>.lua`) - mirrored here so
    -- `telescope.extensions.epicenter.*` is reachable exactly as documented.
    local info = debug.getinfo(2, "S")
    local name = info.source:match("_extensions[/\\]([%w_]+)%.lua$") or "epicenter"
    telescope_stub.extensions[name] = mod.exports
    return true
  end

  local state = { current_line = "", selected_entry = nil, pickers = {} }

  local pickers_stub = {
    new = function(_, picker_opts)
      local picker = { picker_opts = picker_opts, refreshes = {} }
      function picker:find()
        self.prompt_bufnr = vim.api.nvim_create_buf(false, true)
        state.pickers[self.prompt_bufnr] = self
        self.finder = picker_opts.finder
        self.mappings = {}
        if picker_opts.attach_mappings then
          picker_opts.attach_mappings(self.prompt_bufnr, function(mode, lhs, rhs)
            table.insert(self.mappings, { mode = mode, lhs = lhs, rhs = rhs })
          end)
        end
      end
      function picker:refresh(finder)
        self.finder = finder
        table.insert(self.refreshes, finder)
      end
      picker:find()
      return picker
    end,
  }

  -- Mirrors real Telescope closely enough for these tests: `results` ends up
  -- holding ENTRIES (entry_maker already applied), not raw items - a test
  -- reads `entry.value.symbol`, matching what `attach_mappings`/`refresh()`
  -- callers see from the real thing.
  local finders_stub = {
    new_table = function(o)
      local entries = o.results
      if o.entry_maker then
        entries = {}
        for _, item in ipairs(o.results) do
          table.insert(entries, o.entry_maker(item))
        end
      end
      return { results = entries, entry_maker = o.entry_maker }
    end,
  }

  local actions_stub = {
    close = function(bufnr)
      state.closed = bufnr
    end,
    select_default = {
      fn = nil,
      replace = function(self, fn)
        self.fn = fn
      end,
    },
  }

  local action_state_stub = {
    get_current_line = function()
      return state.current_line
    end,
    get_selected_entry = function()
      return state.selected_entry
    end,
    get_current_picker = function(bufnr)
      return state.pickers[bufnr]
    end,
  }

  local config_stub = {
    values = {
      generic_sorter = function()
        return {}
      end,
    },
  }

  package.loaded["telescope"] = telescope_stub
  package.loaded["telescope.pickers"] = pickers_stub
  package.loaded["telescope.finders"] = finders_stub
  package.loaded["telescope.config"] = config_stub
  package.loaded["telescope.actions"] = actions_stub
  package.loaded["telescope.actions.state"] = action_state_stub
  package.loaded["telescope.sorters"] = {
    empty = function()
      return {}
    end,
  }

  return telescope_stub, state
end

local function remove_stub()
  for _, name in ipairs(TELESCOPE_MODULES) do
    package.loaded[name] = nil
  end
end

--- Fires the prompt buffer's own text-changed autocmd, as Telescope's real
--- prompt window would when the user types.
local function type_query(state, prompt_bufnr, text)
  state.current_line = text
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = prompt_bufnr })
end

local function open_fixture(root, relative)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  return vim.api.nvim_get_current_buf()
end

describe("telescope extension entries", function()
  it("renders a symbol row with its file:line and highlights nothing extra", function()
    local telescope = require("epicenter.telescope")
    local entry = telescope.symbol_entry({
      symbol = {
        qualified = "M.fetch",
        kind = "fn",
        file = "app/x.lua",
        line = 9,
        uri = "file:///x.lua",
      },
    })
    expect.matches(entry.display, "M%.fetch")
    expect.matches(entry.display, "app/x%.lua:9")
    expect.eq(entry.ordinal, entry.display)
    expect.eq(entry.filename, "/x.lua")
    expect.eq(entry.lnum, 9)
  end)

  it("renders a grep row with the matched line, trimmed", function()
    local telescope = require("epicenter.telescope")
    local entry = telescope.grep_entry({
      file = "app/x.lua",
      line = 3,
      character = 2,
      text = "  return 1",
      uri = "file:///x.lua",
    })
    expect.matches(entry.display, "app/x%.lua:3")
    expect.matches(entry.display, "return 1")
    expect.eq(entry.lnum, 3)
  end)

  it("renders a blast row with its depth", function()
    local telescope = require("epicenter.telescope")
    local entry = telescope.blast_entry({
      depth = 2,
      symbol = { qualified = "M.start", file = "app/server.lua", line = 14, uri = "file:///s.lua" },
    })
    expect.matches(entry.display, "^%[2%]")
    expect.matches(entry.display, "M%.start")
    expect.eq(entry.lnum, 14)
  end)
end)

describe("telescope extension, wired against the fake navgraph server", function()
  local root, buf, stub, state

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    root = root or support.start_fake()
    buf = open_fixture(root, "app/server.lua")
    stub, state = install_stub()
  end)

  after_each(function()
    remove_stub()
  end)

  it("registers symbols/grep/blast exports under telescope.extensions.epicenter", function()
    require("telescope._extensions.epicenter")
    local epicenter_telescope = require("epicenter.telescope")
    expect.truthy(stub.extensions.epicenter ~= nil, "extension did not register")
    expect.eq(stub.extensions.epicenter.symbols, epicenter_telescope.symbols)
    expect.eq(stub.extensions.epicenter.grep, epicenter_telescope.grep)
    expect.eq(stub.extensions.epicenter.blast, epicenter_telescope.blast)
  end)

  it("lists real symbols on open and re-queries live as the prompt changes", function()
    local telescope = require("epicenter.telescope")
    telescope.symbols({ bufnr = buf })
    local picker = select(2, next(state.pickers))

    wait(function()
      return #picker.refreshes > 0
    end, 10000, "the initial (empty-query) listing")
    expect.truthy(#picker.finder.results > 0, "server has symbols for the fixture project")

    local before = #picker.refreshes
    type_query(state, picker.prompt_bufnr, "handle_request")
    wait(function()
      return #picker.refreshes > before
    end, 10000, "a re-query on typing")
    local names = vim.tbl_map(function(entry)
      return entry.value.symbol.qualified
    end, picker.finder.results)
    expect.truthy(vim.tbl_contains(names, "M.handle_request"), vim.inspect(names))
  end)

  it("jumps to the selected symbol on <CR>, via select_default", function()
    local telescope = require("epicenter.telescope")
    telescope.symbols({ bufnr = buf })
    local picker = select(2, next(state.pickers))
    wait(function()
      return #picker.finder.results > 0
    end, 10000, "results")

    local target = telescope.symbol_entry({
      symbol = {
        qualified = "M.handle_request",
        kind = "fn",
        file = "app/server.lua",
        line = 9,
        uri = vim.uri_from_fname(vim.fs.joinpath(root, "app/server.lua")),
      },
    })
    state.selected_entry = target
    -- select_default was replaced directly (not routed through `map`).
    local select_default_fn = require("telescope.actions").select_default.fn
    expect.truthy(select_default_fn ~= nil, "select_default was not replaced")
    select_default_fn()

    expect.matches(vim.api.nvim_buf_get_name(0), "app/server%.lua")
    expect.eq(vim.api.nvim_win_get_cursor(0)[1], 9)
  end)

  it("only greps once there is a query, live", function()
    local telescope = require("epicenter.telescope")
    telescope.grep({ bufnr = buf })
    local picker = select(2, next(state.pickers))
    wait(function()
      return #picker.refreshes > 0
    end, 10000, "the initial (empty-query) listing")
    expect.eq(#picker.finder.results, 0, "an empty query greps nothing")

    type_query(state, picker.prompt_bufnr, "handle_request")
    wait(function()
      return #picker.finder.results > 0
    end, 10000, "grep matches")
  end)

  it(
    "fetches the blast radius of the symbol under the cursor once, then filters locally",
    function()
      vim.api.nvim_win_set_cursor(0, { 9, 15 }) -- M.handle_request's own definition line
      local telescope = require("epicenter.telescope")
      telescope.blast({ bufnr = buf })
      local picker = select(2, next(state.pickers))

      wait(function()
        return #picker.refreshes > 0
      end, 10000, "the blast fetch")
      local names = vim.tbl_map(function(entry)
        return entry.value.symbol.qualified
      end, picker.finder.results)
      expect.truthy(
        vim.tbl_contains(names, "M.start"),
        "M.start calls handle_request: " .. vim.inspect(names)
      )
    end
  )

  it("fetches blast for an explicit symbol argument without touching the cursor", function()
    local telescope = require("epicenter.telescope")
    telescope.blast({ bufnr = buf, symbol = "log_request" })
    local picker = select(2, next(state.pickers))
    wait(function()
      return #picker.refreshes > 0
    end, 10000, "the blast fetch")
    local names = vim.tbl_map(function(entry)
      return entry.value.symbol.qualified
    end, picker.finder.results)
    expect.truthy(vim.tbl_contains(names, "M.handle_request"), vim.inspect(names))
  end)
end)

describe("telescope extension without Telescope installed", function()
  it("warns instead of erroring", function()
    for _, name in ipairs(TELESCOPE_MODULES) do
      package.loaded[name] = nil
    end
    local telescope = require("epicenter.telescope")
    local notified = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    local ok = pcall(telescope.symbols, {})
    vim.notify = original_notify
    expect.truthy(ok, "must not error when Telescope is absent")
    expect.truthy(#notified > 0 and notified[1].msg:match("Telescope"), vim.inspect(notified))
  end)
end)

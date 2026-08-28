local config = require("epicenter.config")

describe("config", function()
  before_each(function()
    config.reset()
  end)

  it("returns defaults without setup", function()
    local cfg = config.get()
    expect.eq(cfg.lsp.fallback_only, true)
    expect.eq(cfg.ui.icons, "auto")
    expect.eq(cfg.lsp.root_markers, { ".navgraph", ".git" })
  end)

  it("deep merges nested tables", function()
    local cfg = config.setup({ ui = { winblend = 10 } })
    expect.eq(cfg.ui.winblend, 10)
    expect.eq(cfg.ui.border, "rounded", "sibling defaults survive the merge")
    expect.eq(cfg.lsp.init_options.debounceMs, 120)
  end)

  it("replaces list options wholesale instead of merging by index", function()
    local cfg = config.setup({ lsp = { root_markers = { ".hg" } } })
    expect.eq(cfg.lsp.root_markers, { ".hg" })
  end)

  it("does not leak user tables into the config", function()
    local user = { ui = { winblend = 5 } }
    local cfg = config.setup(user)
    user.ui.winblend = 99
    expect.eq(cfg.ui.winblend, 5)
  end)

  it("does not let one setup bleed into the next", function()
    config.setup({ ui = { winblend = 42 } })
    config.reset()
    expect.eq(config.get().ui.winblend, 0)
  end)

  it("rejects unknown options and names the path", function()
    expect.errors(function()
      config.setup({ ui = { nope = 1 } })
    end, 'unknown option "ui%.nope"')
    expect.errors(function()
      config.setup({ typo = true })
    end, 'unknown option "typo"')
  end)

  it("rejects wrong types", function()
    expect.errors(function()
      config.setup({ ui = { winblend = "10" } })
    end, "ui%.winblend must be number")
    expect.errors(function()
      config.setup({ animate = "yes" })
    end, "animate must be boolean")
  end)

  it("accepts documented variants", function()
    expect.eq(config.setup({ keymaps = false }).keymaps, false)
    expect.eq(
      config.setup({ navgraph = { path = "/bin/navgraph" } }).navgraph.path,
      "/bin/navgraph"
    )
    expect.eq(config.setup({ ui = { border = { "1", "2" } } }).ui.border, { "1", "2" })
  end)

  it("rejects keymaps = true, the only boolean it does not mean 'no keymaps'", function()
    expect.errors(function()
      config.setup({ keymaps = true })
    end, "keymaps must be a table or `false`")
  end)

  it("enforces enums", function()
    expect.errors(function()
      config.setup({ ui = { icons = "emoji" } })
    end, "ui%.icons must be one of")
    expect.errors(function()
      config.setup({ log = { level = "loud" } })
    end, "log%.level must be one of")
    expect.errors(function()
      config.setup({ lsp = { init_options = { tests = "maybe" } } })
    end, "tests must be one of")
  end)

  it("enforces the shape of theme.accent, so setup cannot die inside nvim_get_hl", function()
    for _, accent in ipairs({ "auto", "mono", "#7aa2f7", "Function", "@lsp.type.class" }) do
      expect.eq(config.setup({ theme = { accent = accent } }).theme.accent, accent)
    end
    -- "#f00" is the obvious shorthand, and it used to take setup() and every
    -- later :colorscheme down with an "Highlight id out of bounds".
    for _, accent in ipairs({ "#f00", "#7aa2f7 ", "my accent", "" }) do
      expect.errors(function()
        config.setup({ theme = { accent = accent } })
      end, "theme%.accent must be")
    end
  end)

  it("enforces numeric ranges", function()
    expect.errors(function()
      config.setup({ animation = { open_ms = 0 } })
    end, "must be a positive number")
    expect.errors(function()
      config.setup({ ui = { width = -1 } })
    end, "ui%.width must be")
  end)

  it("catches the config gaps that used to reach runtime (F15)", function()
    expect.errors(function()
      config.setup({ lsp = { restart = { backoff_ms = {} } } })
    end, "backoff_ms must be a non%-empty list")
    expect.errors(function()
      config.setup({ lsp = { restart = { backoff_ms = { 0 } } } })
    end, "backoff_ms must be a non%-empty list of positive numbers")
    expect.errors(function()
      config.setup({ ui = { winblend = 500 } })
    end, "ui%.winblend must be between 0 and 100")
    expect.errors(function()
      config.setup({ ui = { winblend = -1 } })
    end, "ui%.winblend must be between 0 and 100")
    expect.errors(function()
      config.setup({ animation = { stagger_ms = -50 } })
    end, "must be a positive number")
    expect.errors(function()
      config.setup({ search = { debounce_ms = -1 } })
    end, "search%.debounce_ms must be")
    expect.errors(function()
      config.setup({ search = { limit = 0 } })
    end, "search%.limit must be")
    expect.errors(function()
      config.setup({ grep = { debounce_ms = 0 } })
    end, "grep%.debounce_ms must be")
    expect.errors(function()
      config.setup({ grep = { limit = -5 } })
    end, "grep%.limit must be")
    expect.errors(function()
      config.setup({ lsp = { restart = { max = 0 } } })
    end, "lsp%.restart%.max must be")
  end)

  it("keeps highlight overrides free-form", function()
    local cfg = config.setup({
      highlights = { EpicenterAccent = { fg = "#ff0000" }, Whatever = { bold = true } },
    })
    expect.eq(cfg.highlights.EpicenterAccent.fg, "#ff0000")
    expect.eq(cfg.highlights.Whatever.bold, true)
  end)

  it("honours the reduce-motion global over the animate option", function()
    config.setup({ animate = true })
    local saved = vim.g.epicenter_reduce_motion
    vim.g.epicenter_reduce_motion = nil
    expect.eq(config.motion_enabled(), true)
    vim.g.epicenter_reduce_motion = true
    expect.eq(config.motion_enabled(), false)
    vim.g.epicenter_reduce_motion = saved
  end)

  it("passes an lsp.init_options key it does not know verbatim (F6)", function()
    local cfg = config.setup({
      lsp = { init_options = { newOptionFromNewerNavgraph = 1 } },
    })
    expect.eq(cfg.lsp.init_options.newOptionFromNewerNavgraph, 1)
    -- Documented keys keep their own validation - free-form does not mean
    -- unchecked for the options this plugin actually knows about.
    expect.errors(function()
      config.setup({ lsp = { init_options = { debounceMs = -1 } } })
    end, "debounceMs must be a positive number")
    expect.errors(function()
      config.setup({ lsp = { init_options = { tests = "maybe" } } })
    end, "tests must be one of")
  end)

  it("enforces the ui.border enum for the string form only (F7)", function()
    expect.errors(function()
      config.setup({ ui = { border = "nope" } })
    end, "ui%.border must be one of")
    expect.eq(config.setup({ ui = { border = "double" } }).ui.border, "double")
    -- The table form (custom per-side border chars) stays free-form.
    expect.eq(config.setup({ ui = { border = { "1", "2" } } }).ui.border, { "1", "2" })
  end)

  it("rejects an empty keymaps.prefix (F8)", function()
    expect.errors(function()
      config.setup({ keymaps = { prefix = "" } })
    end, "keymaps%.prefix must not be empty")
  end)

  it("rejects a non-string navgraph.args element (F9)", function()
    expect.errors(function()
      config.setup({ navgraph = { args = { 1, 2 } } })
    end, "navgraph%.args must be a list of strings")
    expect.eq(config.setup({ navgraph = { args = { "--foo", "bar" } } }).navgraph.args, {
      "--foo",
      "bar",
    })
    expect.eq(config.setup({ navgraph = { args = {} } }).navgraph.args, {}, "empty stays allowed")
  end)

  it("exposes every feature's options as defaults", function()
    local registry = require("epicenter.registry")
    local defaults = config.defaults()
    for key in pairs(registry.options()) do
      expect.truthy(defaults[key] ~= nil, "feature option " .. key .. " missing from defaults")
    end
  end)
end)

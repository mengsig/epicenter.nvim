local theme = require("epicenter.ui.theme")

local SOURCES = {
  Normal = { fg = 0xc0caf5, bg = 0x1a1b26 },
  NormalFloat = { fg = 0xc0caf5, bg = 0x16161e },
  FloatBorder = { fg = 0x27a1b9 },
  Comment = { fg = 0x565f89 },
  Title = { fg = 0x9d7cd8 },
  Function = { fg = 0x7aa2f7 },
  Special = { fg = 0xff9e64 },
  DiagnosticInfo = { fg = 0x0db9d7 },
}

describe("theme", function()
  it("blends two colours toward the background", function()
    expect.eq(theme.blend(0xffffff, 0x000000, 0), 0x000000)
    expect.eq(theme.blend(0xffffff, 0x000000, 1), 0xffffff)
    expect.eq(theme.blend(0xffffff, 0x000000, 0.5), 0x808080)
    expect.eq(theme.blend(0xff0000, 0x0000ff, 0.5), 0x800080)
  end)

  it("passes a colour through when the other side is missing", function()
    expect.eq(theme.blend(0x123456, nil, 0.5), 0x123456)
    expect.eq(theme.blend(nil, 0x123456, 0.5), 0x123456)
    expect.eq(theme.blend(nil, nil, 0.5), nil)
  end)

  it("defines every declared group", function()
    local derived = theme.derive(SOURCES)
    for _, group in ipairs(theme.GROUPS) do
      expect.truthy(derived[group] ~= nil, "missing group " .. group)
    end
  end)

  it("takes the float background and one accent from the colourscheme", function()
    local derived = theme.derive(SOURCES)
    expect.eq(derived.EpicenterNormal.bg, 0x16161e)
    expect.eq(derived.EpicenterAccent.fg, 0x7aa2f7, "accent comes from Function")
    expect.eq(derived.EpicenterMatch.fg, derived.EpicenterAccent.fg, "one accent, used everywhere")
    expect.eq(derived.EpicenterBorder.fg, 0x27a1b9)
    expect.eq(derived.EpicenterMuted.fg, 0x565f89)
  end)

  it("tints selection and range from the accent over the float background", function()
    local derived = theme.derive(SOURCES)
    expect.eq(derived.EpicenterSelection.bg, theme.blend(0x7aa2f7, 0x16161e, 0.16))
    expect.eq(derived.EpicenterRange.bg, theme.blend(0x7aa2f7, 0x16161e, 0.22))
    expect.ne(derived.EpicenterSelection.bg, derived.EpicenterNormal.bg)
  end)

  it("falls back when a source group is undefined", function()
    local derived = theme.derive({ Normal = { fg = 0xffffff, bg = 0x000000 } })
    expect.eq(derived.EpicenterNormal.bg, 0x000000)
    expect.eq(derived.EpicenterAccent.fg, 0xffffff, "accent falls back to the normal foreground")
    expect.truthy(derived.EpicenterBorder ~= nil)
  end)

  it("survives a completely empty colourscheme", function()
    local derived = theme.derive({})
    for _, group in ipairs(theme.GROUPS) do
      expect.eq(type(derived[group]), "table", group)
    end
  end)

  it('"mono" drops the extra hue - accent matches muted', function()
    local derived = theme.derive(SOURCES, nil, "mono")
    expect.eq(derived.EpicenterAccent.fg, 0x565f89, "mono accent is the muted tone")
    expect.eq(derived.EpicenterMatch.fg, derived.EpicenterAccent.fg)
  end)

  it("takes a literal #rrggbb accent", function()
    local derived = theme.derive(SOURCES, nil, "#ff00aa")
    expect.eq(derived.EpicenterAccent.fg, 0xff00aa)
  end)

  it("borrows fg from a named highlight group as the accent", function()
    vim.api.nvim_set_hl(0, "EpicenterTestAccent", { fg = 0x00ff00 })
    local derived = theme.derive(SOURCES, nil, "EpicenterTestAccent")
    expect.eq(derived.EpicenterAccent.fg, 0x00ff00)
  end)

  it('"auto" (or nil) keeps deriving from Function/Title, same as before', function()
    expect.eq(theme.derive(SOURCES, nil, "auto").EpicenterAccent.fg, 0x7aa2f7)
    expect.eq(theme.derive(SOURCES, nil, nil).EpicenterAccent.fg, 0x7aa2f7)
  end)

  it("lets config override any group", function()
    local derived = theme.derive(SOURCES, { EpicenterAccent = { fg = 0xff0000, italic = true } })
    expect.eq(derived.EpicenterAccent.fg, 0xff0000)
    expect.eq(derived.EpicenterAccent.italic, true)
    expect.eq(derived.EpicenterAccent.bg, 0x16161e, "an override merges, it does not replace")
  end)

  it("applies the groups to the live session", function()
    require("epicenter.config").reset()
    theme.apply()
    local hl = vim.api.nvim_get_hl(0, { name = "EpicenterAccent" })
    expect.truthy(next(hl) ~= nil, "EpicenterAccent was not defined")
  end)

  it("survives every accent the config lets through", function()
    local config = require("epicenter.config")
    for _, accent in ipairs({ "auto", "mono", "#7aa2f7", "Function", "NoSuchGroupHere" }) do
      config.reset()
      config.setup({ theme = { accent = accent } })
      local ok, err = pcall(require("epicenter.ui.theme").apply)
      expect.truthy(ok, ("accent %q: %s"):format(accent, tostring(err)))
    end
    config.reset()
  end)

  it("reads config.theme.accent when applying live", function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ theme = { accent = "#123456" } })
    theme.apply()
    local hl = vim.api.nvim_get_hl(0, { name = "EpicenterAccent" })
    expect.eq(hl.fg, 0x123456)
    require("epicenter.config").reset()
    theme.apply()
  end)
end)

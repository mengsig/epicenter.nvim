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
end)

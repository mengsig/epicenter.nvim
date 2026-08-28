local registry = require("epicenter.registry")

describe("registry", function()
  before_each(function()
    registry.reset()
  end)

  it("indexes every declared subcommand", function()
    local names = registry.command_names()
    expect.truthy(#names > 0)
    for _, cmd in ipairs(registry.commands()) do
      expect.eq(registry.command(cmd.name), cmd)
      expect.truthy(cmd.feature ~= nil, cmd.name .. " has no owning feature")
      expect.truthy(cmd.desc ~= "", cmd.name .. " has an empty desc")
    end
  end)

  it("gives every ready command a run function and every planned one none", function()
    for _, cmd in ipairs(registry.commands()) do
      if cmd.status == "ready" then
        expect.eq(type(cmd.run), "function", cmd.name .. " is ready without run")
      else
        expect.eq(cmd.run, nil, cmd.name .. " is planned but has run")
      end
    end
  end)

  it("points every keymap at a real subcommand", function()
    for _, map in ipairs(registry.keymaps()) do
      expect.truthy(
        registry.command(map.command) ~= nil,
        map.suffix .. " maps to a missing subcommand"
      )
      expect.matches(map.suffix, "^%S+$")
    end
  end)

  it("rejects two features claiming one subcommand", function()
    package.loaded["epicenter.features"] = {
      {
        name = "a",
        summary = "a",
        commands = { { name = "dup", desc = "d", status = "planned" } },
      },
      {
        name = "b",
        summary = "b",
        commands = { { name = "dup", desc = "d", status = "planned" } },
      },
    }
    registry.reset()
    expect.errors(function()
      registry.commands()
    end, "claimed by both")
    package.loaded["epicenter.features"] = nil
    registry.reset()
  end)

  it("rejects a ready command with no run function", function()
    package.loaded["epicenter.features"] = {
      { name = "a", summary = "a", commands = { { name = "x", desc = "d" } } },
    }
    registry.reset()
    expect.errors(function()
      registry.commands()
    end, "ready but has no run")
    package.loaded["epicenter.features"] = nil
    registry.reset()
  end)

  it("merges a feature's own option_rules for an option path it owns (#F11)", function()
    package.loaded["epicenter.features"] = {
      {
        name = "a",
        summary = "a",
        commands = {},
        options = { a = { mode = "x" } },
        option_rules = { enums = { ["a.mode"] = { "x", "y" } } },
      },
    }
    registry.reset()
    expect.eq(registry.option_rules().enums["a.mode"], { "x", "y" })
    package.loaded["epicenter.features"] = nil
    registry.reset()
  end)

  it("rejects a feature's rule on an option path it does not own (#F11)", function()
    package.loaded["epicenter.features"] = {
      {
        name = "a",
        summary = "a",
        commands = {},
        -- Declares no `options`, so it owns nothing - yet rules on `b.mode`.
        option_rules = { enums = { ["b.mode"] = { "x" } } },
      },
    }
    registry.reset()
    expect.errors(function()
      registry.option_rules()
    end, "which it does not own")
    package.loaded["epicenter.features"] = nil
    registry.reset()
  end)

  it("does not pull config in - config builds its defaults from the registry", function()
    for name in pairs(package.loaded) do
      if name:match("^epicenter") then
        package.loaded[name] = nil
      end
    end
    require("epicenter.registry").commands()
    expect.eq(
      package.loaded["epicenter.config"],
      nil,
      "a feature module required config at file scope"
    )
  end)
end)

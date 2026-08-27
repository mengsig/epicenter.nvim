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
    epicenter.setup({ keymaps = { prefix = "<leader>Z" } })
    expect.truthy(vim.fn.maparg("<leader>Zs", "n") ~= "", "setup() must have installed the keymap")

    epicenter.reset()

    expect.eq(vim.fn.maparg("<leader>Zs", "n"), "", "reset() must remove the keymaps it installed")
  end)
end)

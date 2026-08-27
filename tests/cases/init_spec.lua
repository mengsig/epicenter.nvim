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

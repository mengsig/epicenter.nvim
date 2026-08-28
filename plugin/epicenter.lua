if vim.g.loaded_epicenter then
  return
end
vim.g.loaded_epicenter = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("epicenter.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Epicenter", function(cmd)
  local args = cmd.fargs
  local name = table.remove(args, 1)
  if not name then
    name = "status"
  end
  require("epicenter").run(name, args)
end, {
  nargs = "*",
  desc = "epicenter.nvim",
  complete = function(lead, line, col)
    return require("epicenter").complete(lead, line, col)
  end,
})

-- Defaults apply without an explicit setup() call; a later setup() replaces them.
local function bootstrap()
  require("epicenter").ensure_setup()
end

if vim.v.vim_did_enter == 1 then
  bootstrap()
else
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("EpicenterBootstrap", { clear = true }),
    once = true,
    callback = bootstrap,
  })
end

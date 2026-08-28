--- Neovim 0.11+ reads `lsp/<name>.lua` off the runtimepath, so
--- `vim.lsp.enable("navgraph")` starts the server with no epicenter call at
--- all. This is for people who run their servers that way; the plugin's own
--- `vim.lsp.start` path stays the default, and on 0.10 it is the only one.
---
--- Running both attaches two navgraph clients to the same buffer, so pair
--- `vim.lsp.enable("navgraph")` with `require("epicenter").setup({ lsp = {
--- auto_start = false } })`.
---
--- Derived from the same places the plugin's own start path reads, so the two
--- cannot drift; `tests/cases/lsp_config_spec.lua` pins that.
local config = require("epicenter.config").get()
local binary = require("epicenter.install").resolve() or "navgraph"

return {
  cmd = vim.list_extend({ binary, "lsp" }, config.navgraph.args),
  filetypes = require("epicenter.client").FILETYPES,
  root_markers = config.lsp.root_markers,
  init_options = config.lsp.init_options,
}

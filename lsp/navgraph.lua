--- Neovim 0.11+ reads `lsp/<name>.lua` off the runtimepath, so
--- `vim.lsp.enable("navgraph")` starts the server with no epicenter call at
--- all. This is for people who run their servers that way; the plugin's own
--- `vim.lsp.start` path stays the default, and on 0.10 it is the only one.
---
--- Running both attaches two navgraph clients to the same buffer, so pair
--- `vim.lsp.enable("navgraph")` with `require("epicenter").setup({ lsp = {
--- auto_start = false } })`. `epicenter.client` then adopts the client this
--- route starts on `LspAttach` (F7), so every panel works exactly as if the
--- plugin's own path had started it.
---
--- `capabilities`/`handlers` are the same `epicenter.client` builds for its
--- own start path - the `workDoneProgress` decline (`client.lua` explains
--- why) and the `navgraph/indexed` live-refresh handler both apply here too,
--- so this route is not a stripped-down, silently-broken one.
---
--- Derived from the same places the plugin's own start path reads, so the two
--- cannot drift; `tests/cases/lsp_config_spec.lua` pins that.
local config = require("epicenter.config").get()
local binary = require("epicenter.install").resolve() or "navgraph"
local client = require("epicenter.client")

return {
  cmd = vim.list_extend({ binary, "lsp" }, config.navgraph.args),
  filetypes = client.FILETYPES,
  root_markers = config.lsp.root_markers,
  init_options = config.lsp.init_options,
  capabilities = client.capabilities(),
  handlers = client.handlers(),
}

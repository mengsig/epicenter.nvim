--- Blast radius: what breaks if this symbol changes, in depth rings, live.
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

M.name = "blast"
M.summary = "Blast radius of a symbol, in depth rings, live"

M.options = {
  blast = {
    depth = 2,
    --- Upper bound for `+` in the panel.
    max_depth = 6,
    direction = "callers",
    tests = "with",
    strict = false,
    layout = "float",
    follow_debounce_ms = 80,
    realtime_debounce_ms = 150,
  },
  --- Ring-graded marks on the impacted lines while a panel is open.
  ripples = true,
  hover = {
    --- Top callers listed on the card.
    callers = 5,
    max_width = 80,
  },
  --- "cursor" badges the definition the cursor is inside, "all" badges every
  --- definition in the buffer, `false` badges nothing.
  badges = "cursor",
}

M.option_docs = {
  ["badges"] = '"cursor" | "all" | false',
  ["blast.depth"] = "rings requested",
  ["blast.direction"] = '"callers" | "callees"',
  ["blast.layout"] = '"float" | "vsplit"',
  ["blast.max_depth"] = "upper bound for `+` in the panel",
  ["blast.strict"] = "drop name-resolved (heuristic) edges",
  ["blast.tests"] = '"with" | "without" | "only"',
  ["ripples"] = "mark the impacted lines while a panel is open",
}

M.option_rules = {
  variants = {
    ["badges"] = { "string", "boolean" },
  },
  enums = {
    ["badges"] = { "cursor", "all", false },
    ["blast.direction"] = { "callers", "callees" },
    ["blast.tests"] = { "with", "without", "only" },
    ["blast.layout"] = { "float", "vsplit" },
  },
  positive = {
    ["blast.depth"] = true,
    ["blast.max_depth"] = true,
    ["blast.follow_debounce_ms"] = true,
    ["blast.realtime_debounce_ms"] = true,
    ["hover.callers"] = true,
    ["hover.max_width"] = true,
  },
}

--- @param bufnr integer
--- @return { uri: string, position: { line: integer, character: integer } }
function M.cursor_target(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
  return {
    uri = vim.uri_from_bufnr(bufnr),
    position = { line = cursor[1] - 1, character = cursor[2] },
  }
end

--- True when navgraph is the buffer's hover provider - which, under
--- `lsp.fallback_only`, means no other language server offers one.
local function navgraph_owns_hover(bufnr)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "navgraph" })) do
    if client:supports_method("textDocument/hover", bufnr) then
      return true
    end
  end
  return false
end

--- `K` shows the card only where navgraph answers hover; anywhere else it
--- stays the language server's key. Decided at press time, because clients
--- attach in any order.
local function install_hover_key(bufnr)
  vim.keymap.set("n", "K", function()
    if navgraph_owns_hover(bufnr) then
      require("epicenter").run("hover", {}, bufnr)
    else
      vim.lsp.buf.hover()
    end
  end, { buffer = bufnr, desc = "Epicenter: hover card", silent = true })
end

--- @param cfg table resolved config
function M.setup(cfg)
  require("epicenter.features.blast.badges").setup(cfg)

  local group = vim.api.nvim_create_augroup("EpicenterBlastFeature", { clear = true })
  if cfg.keymaps == false then
    return
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client.name == "navgraph" then
        install_hover_key(event.buf)
      end
    end,
  })
end

M.commands = {
  {
    name = "blast",
    desc = "Blast radius of the symbol at the cursor",
    run = function(ctx)
      local name = ctx.args[1]
      return require("epicenter.features.blast.panel").open({
        kind = "blast",
        target = name and { symbol = name } or M.cursor_target(ctx.bufnr),
        bufnr = ctx.bufnr,
      })
    end,
  },
  {
    name = "hover",
    desc = "What this symbol is, and who calls it",
    run = function(ctx)
      return require("epicenter.features.blast.hover").open(ctx.bufnr)
    end,
  },
  {
    name = "diff",
    desc = "Impact of the changes since a git ref",
    run = function(ctx)
      return require("epicenter.features.blast.panel").open({
        kind = "diff",
        target = { ref = ctx.args[1] or "HEAD" },
        bufnr = ctx.bufnr,
      })
    end,
  },
}

M.keymaps = {
  { suffix = "e", command = "blast", desc = "Epicenter: blast radius" },
  { suffix = "k", command = "hover", desc = "Epicenter: hover card" },
  { suffix = "d", command = "diff", desc = "Epicenter: diff impact" },
}

return M

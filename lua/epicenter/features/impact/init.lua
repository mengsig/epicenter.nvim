--- The working change's blast radius, always on.
---
--- On every reindex this asks `navgraph/impact` - but only while there IS a
--- working change: with nothing modified there is nothing to ask about, so
--- no request is sent and every mark comes down. The answer drives three
--- surfaces: inline markers in the code, a statusline fragment, and the
--- review panel where each impacted definition gets ticked off.
---
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

local approvals = require("epicenter.features.impact.approvals")
local marks = require("epicenter.features.impact.marks")
local review = require("epicenter.features.impact.review")

--- The one answer the whole feature reads, plus what was approved under it.
--- nil means "no working change", which is a different thing from "an empty
--- impact" - only the second one is a server answer. The table is MUTATED in
--- place on a fresh answer, so an open review panel holding it sees the new
--- one instead of the panel and the marks disagreeing.
--- @type { root: string, result: table, groups: table[], state: table }|nil
local current = nil

local unsubscribe = nil
local debounced = nil
local group = nil
--- The open review panel, so a fresh answer repaints it in place.
local panel = nil

-- The gate -------------------------------------------------------------------------

--- Whether anything in `root` is actually unsaved. The working change IS the
--- overlays the server holds, so with none there is nothing to ask about -
--- and asking anyway would be a request per reindex, forever, for an answer
--- that is known to be empty.
--- @return boolean
function M.has_working_change(root)
  local root_mod = require("epicenter.root")
  local cfg = require("epicenter.config").get()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].modified
      and vim.bo[bufnr].buftype == ""
      and vim.api.nvim_buf_get_name(bufnr) ~= ""
      and root_mod.find(bufnr, cfg.lsp.root_markers) == root
    then
      return true
    end
  end
  return false
end

-- The ambient query ------------------------------------------------------------------

local function marker_entries()
  local entries = {}
  for _, group_entry in ipairs(current.groups) do
    for _, impacted in ipairs(group_entry.nodes) do
      table.insert(entries, {
        path = vim.uri_to_fname(impacted.symbol.uri),
        line = impacted.symbol.line,
        depth = impacted.depth,
        label = group_entry.label,
        approved = approvals.approved(current.state, impacted.symbol),
      })
    end
  end
  return entries
end

--- Repaints the surfaces that only read the CURRENT answer: the inline
--- marks and the statusline. Approving a row lands here - reloading the
--- panel from under the cursor would move it.
local function refresh_marks()
  if not current then
    marks.clear()
  else
    marks.apply(marker_entries())
  end
  vim.cmd("redrawstatus")
end

--- The above, plus an open review panel: a NEW answer replaces its rows.
local function refresh()
  refresh_marks()
  if panel and panel:valid() then
    review.reload(panel, current)
  end
end

M.refresh = refresh

local function forget()
  if current == nil then
    return
  end
  current = nil
  refresh()
end

local function fetch(bufnr)
  local client = require("epicenter.client")
  local cfg = require("epicenter.config").get()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local root = require("epicenter.root").find(bufnr, cfg.lsp.root_markers)
  if not client.supports("navgraph/impact", { root = root }) then
    return forget()
  end
  if not M.has_working_change(root) then
    return forget()
  end

  local direction = cfg.blast.direction
  client.impact({ depth = cfg.impact.depth, direction = direction }, function(err, result)
    if err then
      -- Ambient work never interrupts: the log is where a repeated failure
      -- shows up, and `:Epicenter impact` says it out loud when asked.
      require("epicenter.log").warn("impact: %s", err.message or "no answer")
      return
    end
    current = current or { root = root }
    current.root = root
    current.result = result
    current.groups = review.group_by_hunk(result, direction)
    current.state = approvals.load(root)
    refresh()
  end, { root = root, channel = "impact:ambient" })
end

-- Surfaces ---------------------------------------------------------------------------

--- The statusline fragment, e.g. `⌁ impact 3/12 reviewed`. Empty while there
--- is no working change, or before the first answer. Zero cost: it reads the
--- cached answer and nothing else.
--- @return string
function M.statusline()
  if not current then
    return ""
  end
  local reviewed, total = review.counts(current.groups, current.state)
  if total == 0 then
    return ""
  end
  return ("%s impact %d/%d reviewed"):format(
    require("epicenter.ui.icons").ui("impact"),
    reviewed,
    total
  )
end

--- The blast panel, rooted at the working change's hunks.
local function open_impact(ctx)
  local reason =
    require("epicenter.client").unsupported_reason(ctx.bufnr, "navgraph/impact", "impact")
  if reason then
    require("epicenter").notify(reason, "warn")
    return nil
  end
  return require("epicenter.features.blast.panel").open({
    kind = "impact",
    target = {},
    bufnr = ctx.bufnr,
  })
end

--- @param session table the live `current` table, mutated by a fresh answer
local function open_review(session)
  session.on_change = refresh_marks
  panel = review.open(session)
  return panel
end

local function run_review(ctx)
  local epicenter = require("epicenter")
  local reason =
    require("epicenter.client").unsupported_reason(ctx.bufnr, "navgraph/impact", "impact review")
  if reason then
    return epicenter.notify(reason, "warn")
  end
  if not current then
    return epicenter.notify("no working change to review", "info")
  end
  if ctx.args[1] == "export" then
    return review.export(current)
  end
  return open_review(current)
end

-- Wiring -----------------------------------------------------------------------------

--- @param cfg table resolved config
function M.setup(cfg)
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
  if debounced then
    debounced.close()
    debounced = nil
  end
  group = group or vim.api.nvim_create_augroup("EpicenterImpact", { clear = true })
  vim.api.nvim_clear_autocmds({ group = group })
  forget()

  if not cfg.impact.enabled then
    return
  end

  debounced = require("epicenter.ui.prompt").debounce(cfg.impact.debounce_ms, fetch)
  unsubscribe = require("epicenter.events").on(require("epicenter.events").INDEXED, function()
    debounced.call(vim.api.nvim_get_current_buf())
  end)
  -- A save removes the working change without necessarily changing the
  -- index, so the marks have to come down on their own account.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      debounced.call(event.buf)
    end,
  })
end

M.name = "impact"
M.summary = "The working change's blast radius, live, and the review that ticks it off"

M.options = {
  impact = {
    --- The whole ambient surface; false sends no request and marks nothing.
    enabled = true,
    --- End-of-line markers on the impacted definitions.
    inline = true,
    --- The word those markers carry.
    marker = "affected",
    depth = 2,
    debounce_ms = 400,
  },
}

M.option_docs = {
  ["impact.enabled"] = "the whole ambient surface, marks and all",
  ["impact.inline"] = "end-of-line markers on impacted definitions",
  ["impact.marker"] = "the word those markers carry",
}

M.option_rules = {
  positive = { ["impact.depth"] = true, ["impact.debounce_ms"] = true },
}

M.commands = {
  {
    name = "impact",
    desc = "Blast radius of the working change",
    rows = true,
    run = open_impact,
  },
  {
    name = "review",
    desc = "Review the working change's impact",
    rows = true,
    run = run_review,
    complete = function(lead)
      return vim.startswith("export", lead) and { "export" } or {}
    end,
  },
}

M.keymaps = {
  { suffix = "i", command = "impact", desc = "Epicenter: impact of the working change" },
  { suffix = "a", command = "review", desc = "Epicenter: review the impact" },
}

--- Test seam: drops the cached answer and every mark.
function M.reset()
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
  if debounced then
    debounced.close()
    debounced = nil
  end
  panel = nil
  forget()
end

--- The cached answer, for tests and the statusline's own spec.
function M.current()
  return current
end

return M

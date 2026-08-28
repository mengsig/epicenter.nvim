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
--- `answered` false means "no working change", which is a different thing
--- from "an empty impact" - only the second one is a server answer.
---
--- The table's IDENTITY is stable for the whole session: an open review panel
--- captures it, so it is refilled and cleared in place. Replacing it - which
--- a save-then-edit cycle used to do - left the panel approving into a
--- session neither the marks nor the statusline read.
--- @type { answered: boolean, root: string|nil, result: table|nil,
---   groups: table[]|nil, state: table|nil, reviewed: integer, total: integer }
local current = { answered = false, reviewed = 0, total = 0 }

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
  if not current.answered then
    marks.clear()
  else
    marks.apply(marker_entries())
  end
  vim.cmd("redrawstatus")
end

--- `review.counts` walks every impacted node and builds an approval key per
--- node. The statusline is evaluated per window per redraw, so the numbers
--- are computed where they CHANGE - a fresh answer, or an approval.
local function recount()
  if not current.answered then
    current.reviewed, current.total = 0, 0
    return
  end
  current.reviewed, current.total = review.counts(current.groups, current.state)
end

--- An approval changed: the numbers and the inline marks move, the panel's
--- own rows do not (reloading would move the cursor out from under the reader).
local function approval_changed()
  recount()
  refresh_marks()
end

--- The above, plus an open review panel: a NEW answer replaces its rows.
local function refresh()
  recount()
  refresh_marks()
  if panel and panel:valid() then
    review.reload(panel, M.current())
  end
end

M.refresh = refresh

local function forget()
  if not current.answered then
    return
  end
  -- Cleared in place: an open review panel holds this exact table.
  current.answered = false
  current.result, current.groups, current.state = nil, nil, nil
  refresh()
end

--- A reindex asks about whatever buffer is current, which may be a plugin
--- float (the review panel itself) with no project of its own. Fall back to
--- the project the last answer came from rather than dropping that answer.
--- @return string|nil
local function ambient_root(bufnr, markers)
  if vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    return require("epicenter.root").find(bufnr, markers)
  end
  return current.root
end

local function fetch(bufnr)
  local client = require("epicenter.client")
  local cfg = require("epicenter.config").get()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local root = ambient_root(bufnr, cfg.lsp.root_markers)
  if not root or not client.supports("navgraph/impact", { root = root }) then
    return forget()
  end
  if not M.has_working_change(root) then
    return forget()
  end

  local direction = cfg.blast.direction
  client.impact({ depth = cfg.impact.depth, direction = direction }, function(err, result)
    if err then
      -- Ambient work never interrupts: the log is where a repeated failure
      -- shows up, and `:Epicenter impact` says it out loud when asked. But
      -- holding the PREVIOUS change's approvals is not "not interrupting"
      -- (L2) - the working change has already moved on, so forget it too.
      require("epicenter.log").warn("impact: %s", err.message or "no answer")
      return forget()
    end
    -- The contract makes changeId required, and every approval is scoped to
    -- it: without one there is no honest way to say what has been reviewed.
    if type(result.changeId) ~= "string" or result.changeId == "" then
      require("epicenter.log").warn("impact: answer carried no changeId")
      return forget()
    end
    current.answered = true
    current.root = root
    current.result = result
    current.groups = review.group_by_hunk(result, direction)
    current.state = approvals.load(root, result.changeId)
    refresh()
  end, { root = root, channel = "impact:ambient" })
end

-- Surfaces ---------------------------------------------------------------------------

--- The statusline fragment, e.g. `⌁ impact 3/12 reviewed`. Empty while there
--- is no working change, or before the first answer. Reads the counts cached
--- by `recount` and nothing else - this runs per window, per redraw.
--- @return string
function M.statusline()
  if not current.answered or current.total == 0 then
    return ""
  end
  return ("%s impact %d/%d reviewed"):format(
    require("epicenter.ui.icons").ui("impact"),
    current.reviewed,
    current.total
  )
end

--- The blast panel, rooted at the working change's hunks. A gated buffer
--- still opens the panel - it just shows the gate line where the rows would
--- be, rather than a request the server would only refuse.
local function open_impact(ctx)
  local reason = require("epicenter.client").gate_notice(ctx.bufnr, "navgraph/impact", "impact")
  return require("epicenter.features.blast.panel").open({
    kind = "impact",
    target = {},
    bufnr = ctx.bufnr,
    gate_reason = reason,
  })
end

--- @param session table the live `current` table, mutated by a fresh answer
--- @param gate_reason? string a `client.gate_notice` result, forwarded to
---   `review.open` - see there
local function open_review(session, gate_reason)
  session.on_change = approval_changed
  panel = review.open(session, gate_reason)
  return panel
end

local function run_review(ctx)
  local epicenter = require("epicenter")
  local client = require("epicenter.client")
  local reason = client.unsupported_reason(ctx.bufnr, "navgraph/impact", "impact review")
  if reason then
    -- `export` reports why rather than opening a panel to say it - the same
    -- toast-not-panel choice `client.gate` makes with no panel to write into.
    if ctx.args[1] == "export" then
      return epicenter.notify(reason, "warn")
    end
    return open_review(current, client.gate_notice(ctx.bufnr, "navgraph/impact", "impact review"))
  end
  if not current.answered then
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

--- The cached answer, or nil while there is no working change.
--- @return table|nil
function M.current()
  return current.answered and current or nil
end

return M

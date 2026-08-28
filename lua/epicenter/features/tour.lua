--- A minute with the whole plugin: a handful of toasts, each with the panel
--- it is talking about open beside it.
---
--- Never runs on its own. The most a first run does is say the tour exists,
--- once; starting it is always a command. No config requires at file scope -
--- see `epicenter.registry`.
local M = {}

--- The walkthrough, in order. A step with a `command` opens that panel on the
--- buffer the tour started from and closes it when the step ends.
M.STEPS = {
  { text = "epicenter · your code graph, live in the editor", ms = 4000 },
  { text = "search — jump to any symbol, or grep across files", command = "search", ms = 9000 },
  { text = "blast radius — what breaks if this changes", command = "blast", ms = 9000 },
  {
    text = "who calls it, as a tree · l fetches the next level",
    command = "hierarchy",
    ms = 9000,
  },
  { text = "the tests that reach it · r runs one", command = "tests", ms = 9000 },
  { text = "this file's shape, live", command = "outline", ms = 9000 },
  { text = "what the whole project leans on", command = "hot", ms = 9000 },
  { text = "that's the tour · :Epicenter <Tab> for the rest", ms = 5000 },
}

--- The running tour: nil when none is. One at a time, on purpose - two would
--- fight over the same screen.
--- @type { bufnr: integer, index: integer, panel: table|nil, timer: table|nil }|nil
local running = nil

local STORE_KIND = "tour"
--- The tour offer is a property of the person, not of a project.
local STORE_SCOPE = "global"

local function close_panel()
  if not running then
    return
  end
  local panel = running.panel
  running.panel = nil
  if type(panel) == "table" and type(panel.close) == "function" then
    pcall(function()
      panel:close()
    end)
  end
end

--- Ends the tour, whether it finished or was interrupted.
--- @param message string|nil said on the way out
function M.stop(message)
  if not running then
    return
  end
  if running.timer then
    -- `vim.defer_fn` closes its handle only from inside its own fired
    -- callback: an interrupted tour would leak one uv handle each time.
    running.timer:stop()
    if not running.timer:is_closing() then
      running.timer:close()
    end
  end
  close_panel()
  running = nil
  if message then
    require("epicenter").notify(message)
  end
end

local function advance()
  if not running then
    return
  end
  close_panel()
  running.index = running.index + 1
  local step = M.STEPS[running.index]
  if not step then
    return M.stop(nil)
  end

  require("epicenter.ui.toast").notify(step.text, { timeout = step.ms })
  if step.command and vim.api.nvim_buf_is_valid(running.bufnr) then
    running.panel = require("epicenter").run(step.command, {}, running.bufnr)
  end
  running.timer = vim.defer_fn(advance, step.ms)
end

--- Starts the tour on `bufnr`. Starting it while one runs stops that one -
--- the same key that began it is the one a reader reaches for to escape.
function M.start(bufnr)
  if running then
    return M.stop("tour stopped")
  end
  running = { bufnr = bufnr, index = 0 }
  advance()
end

--- Whether a tour is running. For tests.
function M.running()
  return running ~= nil
end

-- The first-run offer ------------------------------------------------------------

--- Says the tour exists, once ever, and remembers that it did. Never starts
--- anything: an editor that takes over the screen uninvited is the opposite
--- of what this plugin is for.
local function offer_once()
  local store = require("epicenter.store")
  local seen = store.read(STORE_KIND, STORE_SCOPE)
  if seen.offered then
    return
  end
  local ok, err = store.write(STORE_KIND, STORE_SCOPE, { offered = true })
  if not ok then
    -- Without this the offer comes back on every start-up and nothing says why.
    require("epicenter.log").warn("could not remember the tour offer: %s", err)
  end
  require("epicenter").notify("new here? `:Epicenter tour` is a minute long", "info")
end

local group = nil
local unsubscribe = nil

--- @param cfg table resolved config
function M.setup(cfg)
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
  group = group or vim.api.nvim_create_augroup("EpicenterTour", { clear = true })
  vim.api.nvim_clear_autocmds({ group = group })
  if not cfg.tour.offer then
    return
  end
  local events = require("epicenter.events")
  -- The first index is the first moment the plugin has anything to show.
  local stop = nil
  stop = events.on(events.INDEXED, function()
    if stop then
      stop()
      stop, unsubscribe = nil, nil
    end
    vim.schedule(offer_once)
  end)
  unsubscribe = stop
end

M.name = "tour"
M.summary = "A minute with the whole plugin, panels and all"

M.options = {
  tour = {
    --- Mention the tour once, the first time a project is indexed.
    offer = true,
  },
}

M.option_docs = {
  ["tour.offer"] = "mention the tour once, on a first run",
}

M.commands = {
  {
    name = "tour",
    desc = "A minute with the whole plugin",
    run = function(ctx)
      M.start(ctx.bufnr)
    end,
  },
}

--- Test seam: stops any running tour and drops the offer subscription.
function M.reset()
  M.stop(nil)
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

return M

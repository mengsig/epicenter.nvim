--- Telescope pickers over the same navgraph client calls the built-in
--- palette and blast panel use - symbols/grep live as you type, blast is one
--- fetch then Telescope's own fuzzy filter. Only ever required by
--- `lua/telescope/_extensions/epicenter.lua`, which Telescope itself loads on
--- `load_extension("epicenter")` - a session without Telescope never touches
--- this file, and this file never requires `telescope.*` at file scope.
local M = {}

local OPEN_COMMAND = { edit = "edit", tab = "tabedit", vsplit = "vsplit", split = "split" }

local function has_telescope()
  return (pcall(require, "telescope.pickers"))
end

local function warn(message)
  vim.notify("epicenter: " .. message, vim.log.levels.ERROR)
end

--- Same jump semantics as the search palette (`search.lua`'s `jump`), against
--- Telescope's own entry coordinates (1-based `lnum`/`col`).
local function open_target(action, filename, lnum, col)
  vim.cmd("normal! m'")
  vim.cmd(("%s %s"):format(OPEN_COMMAND[action] or "edit", vim.fn.fnameescape(filename)))
  local line = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(0)))
  local line_len = #(vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or "")
  local column = math.max(0, math.min((col or 1) - 1, line_len))
  vim.api.nvim_win_set_cursor(0, { line, column })
  vim.cmd("normal! zz")
end

-- Entry makers ---------------------------------------------------------------
-- Pure: a `navgraph/search` | `navgraph/grep` item | blast node in, a
-- Telescope entry out. `ordinal` mirrors `display` - the server, not
-- Telescope's sorter, already ranked symbols/grep rows.

--- @param item { symbol: table } a `navgraph/search` item
function M.symbol_entry(item)
  local symbol = item.symbol
  local icons = require("epicenter.ui.icons")
  local display = ("%s %s  %s:%d"):format(
    icons.kind(symbol.kind),
    symbol.qualified,
    symbol.file,
    symbol.line
  )
  return {
    value = item,
    display = display,
    ordinal = display,
    filename = vim.uri_to_fname(symbol.uri),
    lnum = symbol.line,
    col = (symbol.character or 0) + 1,
  }
end

--- @param item table a `navgraph/grep` item
function M.grep_entry(item)
  local display = ("%s:%d: %s"):format(item.file, item.line, vim.trim(item.text))
  return {
    value = item,
    display = display,
    ordinal = display,
    filename = vim.uri_to_fname(item.uri),
    lnum = item.line,
    col = (item.character or 0) + 1,
  }
end

--- @param node { symbol: table, depth: integer } a `blast.model.nodes()` row
function M.blast_entry(node)
  local symbol = node.symbol
  local display = ("[%d] %s  %s:%d"):format(node.depth, symbol.qualified, symbol.file, symbol.line)
  return {
    value = node,
    display = display,
    ordinal = display,
    filename = vim.uri_to_fname(symbol.uri),
    lnum = symbol.line,
    col = 1,
  }
end

-- Pickers ----------------------------------------------------------------------

--- Wires a Telescope picker whose rows come from an async RPC instead of a
--- static list: `spec.request(query, bufnr, cb)` runs (debounced) on every
--- prompt change and `cb(items)` swaps them into the picker via `refresh()` -
--- Telescope's own dynamic finder expects a synchronous return, which an RPC
--- cannot give it. The sorter is a no-op: the server already ranked the rows.
--- @param opts table telescope opts (bufnr, layout, ...)
--- @param spec { title: string, entry_maker: fun(item): table,
---   request: fun(query: string, bufnr: integer, cb: fun(items: table[])),
---   debounce_ms?: integer }
function M.live_picker(opts, spec)
  if not has_telescope() then
    return warn("Telescope is not installed")
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local sorters = require("telescope.sorters")
  local debounce = require("epicenter.ui.prompt").debounce
  -- Telescope loads its extensions eagerly, so this picker may be the FIRST
  -- thing to touch epicenter: without this no server is ever started and
  -- every keystroke comes back "navgraph is not running".
  require("epicenter").ensure_setup()

  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  pickers
    .new(opts, {
      prompt_title = spec.title,
      finder = finders.new_table({ results = {} }),
      sorter = sorters.empty(),
      attach_mappings = function(prompt_bufnr, map)
        local function accept(action)
          return function()
            local entry = action_state.get_selected_entry()
            if not entry then
              return
            end
            actions.close(prompt_bufnr)
            open_target(action, entry.filename, entry.lnum, entry.col)
          end
        end
        actions.select_default:replace(accept("edit"))
        map({ "i", "n" }, "<C-t>", accept("tab"))
        map({ "i", "n" }, "<C-v>", accept("vsplit"))
        map({ "i", "n" }, "<C-x>", accept("split"))

        -- One notice per distinct failure: a live picker asks again on every
        -- keystroke, and the same message each time buries everything else.
        local reported = nil
        local debounced = debounce(spec.debounce_ms or 150, function(text)
          if not vim.api.nvim_buf_is_valid(prompt_bufnr) then
            return
          end
          spec.request(text, bufnr, function(items, failure)
            if not vim.api.nvim_buf_is_valid(prompt_bufnr) then
              return
            end
            if failure ~= reported then
              reported = failure
              if failure then
                warn(failure)
              end
            end
            local picker = action_state.get_current_picker(prompt_bufnr)
            if not picker then
              return
            end
            picker:refresh(
              finders.new_table({ results = items, entry_maker = spec.entry_maker }),
              { reset_prompt = false }
            )
          end)
        end)

        vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
          buffer = prompt_bufnr,
          callback = function()
            debounced.call(action_state.get_current_line())
          end,
        })
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = prompt_bufnr,
          once = true,
          callback = debounced.close,
        })
        debounced.call("")

        return true
      end,
    })
    :find()
end

--- @param opts? table telescope opts, `bufnr` to scope the query
function M.symbols(opts)
  M.live_picker(opts, {
    title = "Epicenter Symbols",
    entry_maker = M.symbol_entry,
    request = function(query, bufnr, cb)
      local cfg = require("epicenter.config").get()
      require("epicenter.client").search(
        { query = query, limit = cfg.search.limit },
        function(err, result)
          if err then
            return cb({}, err.message or "navgraph did not answer")
          end
          cb(result.items or {})
        end,
        { bufnr = bufnr, channel = "telescope-symbols" }
      )
    end,
  })
end

--- @param opts? table telescope opts, `bufnr` to scope the query
function M.grep(opts)
  M.live_picker(opts, {
    title = "Epicenter Grep",
    entry_maker = M.grep_entry,
    request = function(query, bufnr, cb)
      if query == "" then
        return cb({})
      end
      local cfg = require("epicenter.config").get()
      require("epicenter.client").grep(
        { pattern = query, limit = cfg.grep.limit },
        function(err, result)
          if err then
            return cb({}, err.message or "navgraph did not answer")
          end
          cb(result.items or {})
        end,
        { bufnr = bufnr, channel = "telescope-grep" }
      )
    end,
  })
end

--- Blast radius of `opts.symbol`, or the symbol under the cursor - one fetch,
--- then Telescope's own fuzzy filter over the returned rows (no live typing:
--- the target is fixed once the picker opens).
--- @param opts? table telescope opts; `symbol` names a qualified/`name@file`
---   target directly, else the cursor in `opts.bufnr` (current buffer default)
function M.blast(opts)
  if not has_telescope() then
    return warn("Telescope is not installed")
  end
  opts = opts or {}
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local blast = require("epicenter.features.blast")
  local model = require("epicenter.features.blast.model")
  local client = require("epicenter.client")
  require("epicenter").ensure_setup()
  local cfg = require("epicenter.config").get()

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local state = {
    depth = model.clamp_depth(cfg.blast.depth, cfg.blast.max_depth),
    direction = cfg.blast.direction,
    tests = cfg.blast.tests,
    strict = cfg.blast.strict,
  }

  local prompt_buf = nil
  local picker = pickers.new(opts, {
    prompt_title = "Epicenter Blast",
    finder = finders.new_table({ results = {} }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, _map)
      prompt_buf = prompt_bufnr
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        if not entry then
          return
        end
        actions.close(prompt_bufnr)
        open_target("edit", entry.filename, entry.lnum, entry.col)
      end)
      return true
    end,
  })
  picker:find()

  local function fill(target)
    client.blast(model.params(state, target), function(err, result)
      if err then
        return warn(err.message)
      end
      -- Closed while the fetch was in flight: the same guard the live picker
      -- already has, for the same reason.
      if not (prompt_buf and vim.api.nvim_buf_is_valid(prompt_buf)) then
        return
      end
      if not action_state.get_current_picker(prompt_buf) then
        return
      end
      picker:refresh(
        finders.new_table({ results = model.nodes(result), entry_maker = M.blast_entry }),
        { reset_prompt = false }
      )
    end, { bufnr = bufnr, channel = "telescope-blast" })
  end

  if opts.symbol then
    return fill({ symbol = opts.symbol })
  end
  blast.resolve_target(blast.cursor_target(bufnr), function(err, resolved)
    if err then
      return warn(err.message)
    end
    if not resolved then
      return warn("nothing under the cursor")
    end
    fill(resolved)
  end, { bufnr = bufnr })
end

return M

--- Single-line input line with a debounced `on_change`.
local M = {}

local uv = vim.uv or vim.loop
local unpack_args = table.unpack or unpack

--- Coalesces rapid calls: `fn` runs once, `ms` after the last `call()`.
--- @param ms integer
--- @param fn fun(...)
--- @return { call: fun(...), flush: fun(), cancel: fun(), pending: fun(): boolean }
function M.debounce(ms, fn)
  local timer = uv.new_timer()
  local args = nil

  local function run()
    if args == nil then
      return
    end
    local pending = args
    args = nil
    fn(unpack_args(pending, 1, pending.n))
  end

  return {
    call = function(...)
      args = { n = select("#", ...), ... }
      timer:stop()
      timer:start(ms, 0, vim.schedule_wrap(run))
    end,
    flush = function()
      timer:stop()
      run()
    end,
    cancel = function()
      args = nil
      timer:stop()
    end,
    pending = function()
      return args ~= nil
    end,
    close = function()
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end,
  }
end

--- @class epicenter.Prompt
local Prompt = {}
Prompt.__index = Prompt

--- Turns `buf` into a prompt line. The caller owns the window.
--- @param opts { buf: integer, prefix?: string, debounce_ms?: integer,
---   on_change?: fun(text: string), on_submit?: fun(text: string), on_cancel?: fun() }
function M.new(opts)
  local buf = opts.buf
  vim.bo[buf].buftype = "prompt"
  vim.fn.prompt_setprompt(buf, opts.prefix or "")

  local self = setmetatable({
    buf = buf,
    prefix = opts.prefix or "",
    on_change = opts.on_change,
    on_submit = opts.on_submit,
    debouncer = nil,
  }, Prompt)

  if opts.on_change then
    self.debouncer = M.debounce(opts.debounce_ms or 40, function(text)
      if vim.api.nvim_buf_is_valid(buf) then
        opts.on_change(text)
      end
    end)
  end

  vim.fn.prompt_setcallback(buf, function(text)
    if opts.on_submit then
      opts.on_submit(text)
    end
  end)
  vim.fn.prompt_setinterrupt(buf, function()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end)

  self.augroup = vim.api.nvim_create_augroup("EpicenterPrompt" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "TextChangedP" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      if self.debouncer then
        self.debouncer.call(self:text())
      end
    end,
  })

  return self
end

--- Current query, prompt prefix stripped.
function Prompt:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  local line = vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or ""
  return line:sub(#self.prefix + 1)
end

function Prompt:set_text(text)
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { self.prefix .. text })
end

--- Puts the cursor at the end of the prompt, ready to type.
--- Without a UI there is no keyboard to read from and entering insert mode
--- would park the event loop, so headless sessions stay in normal mode.
function Prompt:start_insert()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  vim.cmd("startinsert!")
end

function Prompt:close()
  if self.debouncer then
    self.debouncer.close()
    self.debouncer = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
end

M.Prompt = Prompt

return M

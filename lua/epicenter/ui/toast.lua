--- Bottom-right notice stack: auto-dismissing messages and progress bars.
--- Toasts never steal focus and never block.
local M = {}

local window = require("epicenter.ui.window")
local animate = require("epicenter.ui.animate")

local uv = vim.uv or vim.loop

local WIDTH = 46
local DEFAULT_TIMEOUT = 3000

local LEVEL_HL = {
  info = "EpicenterInfo",
  warn = "WarningMsg",
  error = "ErrorMsg",
  progress = "EpicenterAccent",
}

--- Live toasts, newest last. The single source of truth for stack layout.
local stack = {}

local function icon_for(level)
  local icons = require("epicenter.ui.icons")
  if level == "warn" then
    return icons.ui("warn")
  elseif level == "error" then
    return icons.ui("err")
  elseif level == "progress" then
    return icons.ui("dot")
  end
  return icons.ui("ok")
end

--- Progress bar as text. Pure, so the maths is testable.
--- @param fraction number 0..1
--- @param width integer
function M.bar(fraction, width, full_char, empty_char)
  fraction = math.max(0, math.min(1, fraction or 0))
  local filled = math.floor(fraction * width + 0.5)
  return string.rep(full_char or "#", filled) .. string.rep(empty_char or "-", width - filled)
end

--- Stack geometry, bottom-up. Pure.
--- @param heights integer[] newest last
--- @return epicenter.Box[]
function M.layout(heights, columns, lines, width)
  local boxes = {}
  local bottom = lines - 1
  for i = #heights, 1, -1 do
    local height = heights[i]
    bottom = bottom - height - 2
    boxes[i] = {
      row = math.max(0, bottom + 1),
      col = math.max(0, columns - width - 2),
      width = width,
      height = height,
    }
  end
  return boxes
end

local function relayout()
  local heights = vim.tbl_map(function(toast)
    return toast.height
  end, stack)
  local boxes = M.layout(heights, vim.o.columns, vim.o.lines - vim.o.cmdheight, WIDTH)
  for i, toast in ipairs(stack) do
    if toast.win:valid() then
      toast.win:set_geometry(boxes[i])
    end
  end
end

local function remove(toast)
  for i, entry in ipairs(stack) do
    if entry == toast then
      table.remove(stack, i)
      break
    end
  end
  relayout()
end

local function dismiss(toast)
  if toast.dismissed then
    return
  end
  toast.dismissed = true
  if toast.timer then
    toast.timer:stop()
    if not toast.timer:is_closing() then
      toast.timer:close()
    end
    toast.timer = nil
  end
  remove(toast)
  toast.win:close()
end

local function wrap(text, width)
  local out = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line == "" then
        line = word
      elseif #line + #word + 1 <= width then
        line = line .. " " .. word
      else
        table.insert(out, line)
        line = word
      end
    end
    table.insert(out, line)
  end
  return out
end

local function create(level, lines, opts)
  local body = {}
  for i, line in ipairs(lines) do
    table.insert(body, (i == 1 and (icon_for(level) .. " ") or "  ") .. line)
  end

  local toast = { height = #body, dismissed = false }
  local boxes = M.layout(
    vim.list_extend(
      vim.tbl_map(function(t)
        return t.height
      end, stack),
      { toast.height }
    ),
    vim.o.columns,
    vim.o.lines - vim.o.cmdheight,
    WIDTH
  )

  toast.win = window.open({
    box = boxes[#boxes],
    title = opts.title,
    focusable = false,
    zindex = 200,
    enter = false,
    filetype = "epicenter-toast",
  })
  toast.win:set_lines(body)
  vim.api.nvim_buf_set_extmark(
    toast.win.buf,
    vim.api.nvim_create_namespace("epicenter.toast"),
    0,
    0,
    {
      end_col = #body[1],
      hl_group = LEVEL_HL[level] or "EpicenterInfo",
      strict = false,
    }
  )

  table.insert(stack, toast)
  relayout()

  -- Badge fade-in: winblend from transparent down to the configured value.
  local target_blend = vim.wo[toast.win.win].winblend
  animate.tween({
    duration = require("epicenter.config").get().animation.close_ms,
    on_frame = function(eased)
      if toast.win:valid() then
        vim.wo[toast.win.win].winblend = math.floor(100 - (100 - target_blend) * eased)
      end
    end,
  })

  return toast
end

--- An error toast is the summary; the log has the cause. Naming the file on
--- every one of them is the difference between a bug report that says "it
--- failed" and one that carries the reason.
local function with_log_path(msg)
  local path = require("epicenter.log").path()
  if msg:find(path, 1, true) then
    return msg
  end
  return msg .. "\n" .. path
end

--- @param msg string
--- @param opts? { level?: "info"|"warn"|"error", timeout?: integer, title?: string }
function M.notify(msg, opts)
  opts = opts or {}
  local level = opts.level or "info"
  if vim.in_fast_event() then
    vim.schedule(function()
      M.notify(msg, opts)
    end)
    return
  end

  msg = tostring(msg)
  if level == "error" then
    msg = with_log_path(msg)
  end
  local toast = create(level, wrap(msg, WIDTH - 2), opts)
  toast.timer = uv.new_timer()
  toast.timer:start(
    opts.timeout or DEFAULT_TIMEOUT,
    0,
    vim.schedule_wrap(function()
      dismiss(toast)
    end)
  )
  return {
    dismiss = function()
      dismiss(toast)
    end,
  }
end

--- A toast that stays up until `finish()`, showing a progress bar.
--- @param title string
--- @return { update: fun(fraction?: number, message?: string), finish: fun(message?: string, level?: string) }
function M.progress(title)
  local icons = require("epicenter.ui.icons")
  local toast = create("progress", { title }, { title = nil })
  local width = WIDTH - 4

  local function render(fraction, message)
    local body = { icon_for("progress") .. " " .. title }
    if message then
      vim.list_extend(
        body,
        vim.tbl_map(function(l)
          return "  " .. l
        end, wrap(message, width))
      )
    end
    if fraction then
      table.insert(
        body,
        "  " .. M.bar(fraction, width, icons.ui("progress_full"), icons.ui("progress_empty"))
      )
    end
    toast.height = #body
    if toast.win:valid() then
      toast.win:set_lines(body)
      relayout()
    end
  end

  return {
    update = function(fraction, message)
      if not toast.dismissed then
        render(fraction, message)
      end
    end,
    finish = function(message, level)
      dismiss(toast)
      if message then
        M.notify(message, { level = level or "info" })
      end
    end,
  }
end

--- Test seam and panic button: takes every toast down.
function M.clear()
  for _, toast in ipairs(vim.list_slice(stack, 1, #stack)) do
    dismiss(toast)
  end
  stack = {}
end

--- Live toast count, for tests.
function M.count()
  return #stack
end

return M

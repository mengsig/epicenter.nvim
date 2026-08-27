-- Minimal runtimepath for headless tests: this repo only, no user config.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.resolve(this), ":p:h:h")

vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. root .. "/tests/?/init.lua;" .. package.path

vim.g.epicenter_reduce_motion = true
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
vim.opt.termguicolors = true

_G.EPICENTER_ROOT = root

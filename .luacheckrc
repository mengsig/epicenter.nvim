std = "luajit"
globals = { "vim" }
read_globals = { "describe", "it", "before_each", "after_each", "expect", "wait" }
max_line_length = 120
ignore = {
  "212", -- unused argument
  "631", -- line too long (handled by max_line_length)
}
exclude_files = { "tests/fixtures/**" }

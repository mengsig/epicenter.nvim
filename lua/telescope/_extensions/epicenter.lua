--- `require("telescope").load_extension("epicenter")` - Telescope's own
--- extension mechanism is what pulls this file in, so epicenter's core
--- plugin never requires it and a session without Telescope never touches
--- `epicenter.telescope`.
local telescope = require("telescope")
local epicenter_telescope = require("epicenter.telescope")

return telescope.register_extension({
  exports = {
    symbols = epicenter_telescope.symbols,
    grep = epicenter_telescope.grep,
    blast = epicenter_telescope.blast,
  },
})

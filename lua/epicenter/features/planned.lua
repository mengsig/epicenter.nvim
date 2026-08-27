--- Subcommands whose feature ships in a later release. They complete and print
--- a friendly notice instead of erroring. A feature that lands removes its line
--- here and adds its own module to `epicenter.features`.
--- @type epicenter.FeatureSpec
return {
  name = "planned",
  summary = "Subcommands announced but not yet implemented",
  commands = {
    { name = "outline", desc = "Symbol outline of the current file", status = "planned" },
    { name = "hot", desc = "Hot spots ranked by fan-in", status = "planned" },
    { name = "path", desc = "Call path between two symbols", status = "planned" },
  },
}

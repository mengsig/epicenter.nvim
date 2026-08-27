--- Subcommands whose feature ships in a later release. They complete and print
--- a friendly notice instead of erroring. A feature that lands removes its line
--- here and adds its own module to `epicenter.features`.
--- @type epicenter.FeatureSpec
return {
  name = "planned",
  summary = "Subcommands announced but not yet implemented",
  commands = {},
}

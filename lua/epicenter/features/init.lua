--- The feature list. Adding a feature is one `require` line here plus its
--- module under `lua/epicenter/features/`. Order drives `:Epicenter`
--- completion order and the vimdoc section order.
--- @type epicenter.FeatureSpec[]
return {
  require("epicenter.features.search"),
  require("epicenter.features.planned"),
  require("epicenter.features.blast"),
  require("epicenter.features.explore"),
  require("epicenter.features.core"),
}

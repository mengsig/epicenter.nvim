--- The feature list. Adding a feature is one `require` line here plus its
--- module under `lua/epicenter/features/`. Order drives `:Epicenter`
--- completion order and the vimdoc section order.
--- @type epicenter.FeatureSpec[]
return {
  require("epicenter.features.search"),
  -- `planned` stays right after `search`, its base-branch slot: blast/diff
  -- keep the same neighbours regardless of which planned command a later
  -- wave promotes, so promoting one never reshuffles this list (F15).
  require("epicenter.features.planned"),
  require("epicenter.features.blast"),
  require("epicenter.features.explore"),
  require("epicenter.features.peek"),
  require("epicenter.features.crumbs"),
  require("epicenter.features.hierarchy"),
  require("epicenter.features.path"),
  require("epicenter.features.outline"),
  require("epicenter.features.hot"),
  require("epicenter.features.core"),
}

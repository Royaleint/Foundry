-- Synthetic fixture: empty-but-initialized SavedVariables, post-logout-strip,
-- in the profile-was-read variant (spec §4.3 step 3 — the Homestead path:
-- the empty named profile survives the strip on a main DB; AceDB-3.0.lua:367
-- behavior).
SyntheticDB = {
	profileKeys = {
		["FxChar01 - FxRealm01"] = "Default",
	},
	profiles = {
		Default = {},
	},
}

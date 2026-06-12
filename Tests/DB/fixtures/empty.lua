-- Synthetic fixture: empty-but-initialized SavedVariables, post-logout-strip,
-- in the never-materialized-profile variant (spec §4.3 step 3 — the BawrSpam
-- path: db.profile never read, so no `profiles` section exists on disk).
SyntheticDB = {
	profileKeys = {
		["FxChar01 - FxRealm01"] = "Default",
	},
}

-- Synthetic fixture: structurally malformed — a profile entry is not a table
-- (spec §8.4: clearly fail, refuse construction, the corrupt value is never
-- overwritten).
SyntheticDB = {
	profileKeys = {
		["FxChar01 - FxRealm01"] = "Default",
	},
	profiles = {
		Default = "corrupt",
	},
}

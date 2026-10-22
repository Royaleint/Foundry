-- Synthetic fixture: structurally malformed, a `profileKeys` entry is not a
-- string (clearly fail, refuse construction, SV untouched).
SyntheticDB = {
	profileKeys = {
		["FxChar01 - FxRealm01"] = 7,
	},
}

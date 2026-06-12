-- Synthetic fixture: structurally malformed — a `profileKeys` entry is not a
-- string (spec §8.4: clearly fail, refuse construction, SV untouched).
SyntheticDB = {
	profileKeys = {
		["FxChar01 - FxRealm01"] = 7,
	},
}

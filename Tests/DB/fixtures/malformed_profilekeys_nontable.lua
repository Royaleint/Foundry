-- Synthetic fixture: structurally malformed — `profileKeys` is not a table
-- (spec §8.4: clearly fail, refuse construction, SV untouched).
SyntheticDB = {
	profileKeys = 42,
	global = {
		someSetting = true,
	},
}

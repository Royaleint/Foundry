-- Synthetic fixture: structurally malformed, `profileKeys` is not a table
-- (clearly fail, refuse construction, SV untouched).
SyntheticDB = {
	profileKeys = 42,
	global = {
		someSetting = true,
	},
}

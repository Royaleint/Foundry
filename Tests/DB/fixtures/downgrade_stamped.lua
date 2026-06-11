-- Synthetic fixture: populated save stamped with a NEWER schema version than
-- the build under test declares (spec §8.3: downgrade protection — refuse
-- construction, SV byte-for-byte untouched, no profileKeys write-back).
-- Tests declare schema.version lower than 99 against this file.
SyntheticDB = {
	profileKeys = {
		["FxChar01 - FxRealm01"] = "Default",
	},
	char = {
		["FxChar01 - FxRealm01"] = {
			history = {
				[1] = {
					id = 1,
					outcome = "blocked",
					surface = "chat",
				},
			},
			historyCursor = 1,
		},
	},
	global = {
		schemaVersion = 99,
		someSetting = false,
	},
}

-- Content digests for the pinned release copies under Tests/OldCopies.
--
-- The copies of v1.0.4 have their comments blanked, so the tests cannot compare
-- them with the release source directly. They compare compiled output instead:
-- the bytes of string.dump over the release source, loaded under a fixed chunk
-- name, are summarised here and the summaries are committed in digests.lua.
--
-- The digest is two polynomial checksums over the bytes plus the byte length.
-- It is meant to catch an accidental edit, not a deliberate collision.
--
-- Used from a test:   local digest = dofile(path)   -- digest(bytes) -> string
-- Used to author a row (run from the Foundry repo root, Lua 5.1):
--   git show v1.0.4:Foundry.lua > /tmp/pinned.lua
--   lua5.1 Tests/OldCopies/digest.lua dump   /tmp/pinned.lua   -- compiled form
--   lua5.1 Tests/OldCopies/digest.lua source /tmp/pinned.lua   -- raw bytes

local MOD1, MUL1 = 4294967291, 131
local MOD2, MUL2 = 4294967279, 257

local function digest(bytes)
    local h1, h2 = 7, 11
    for i = 1, #bytes do
        local b = bytes:byte(i)
        h1 = (h1 * MUL1 + b) % MOD1
        h2 = (h2 * MUL2 + b) % MOD2
    end
    return string.format("%d:%08x:%08x", #bytes, h1, h2)
end

-- The chunk name every compiled-form comparison uses on both sides.
local CHUNKNAME = "=pinned"

local function compiledForm(source)
    local fn, err = loadstring(source, CHUNKNAME)
    if not fn then error(err, 0) end
    return string.dump(fn)
end

if arg and arg[0] and arg[0]:find("digest%.lua$") then
    local mode, path = arg[1], arg[2]
    local f = assert(io.open(path, "rb"))
    local source = f:read("*a")
    f:close()
    if mode == "dump" then
        print(digest(compiledForm(source)))
    elseif mode == "source" then
        print(digest(source))
    else
        error("usage: digest.lua dump|source <file>", 0)
    end
    return
end

return { digest = digest, compiledForm = compiledForm, CHUNKNAME = CHUNKNAME }

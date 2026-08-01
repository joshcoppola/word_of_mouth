-- tests/test_wom_utils.lua
-- Standalone Lua 5.1 tests for the two object-shape helpers in wom_utils:
-- get_object_position and get_object_id.
--
-- Run from the repository root:  lua tests/test_wom_utils.lua
-- Run from tests/:               lua test_wom_utils.lua
--
-- Server and client game objects expose the same concepts through different shapes
-- (`.id`/`.position` fields vs `:id()`/`:position()` methods), and this repo has now
-- been bitten by that three times: squad:id() in wom_outpost, npc.position in
-- wom_territory's proximity step, and npc.position in wom_combat's death callbacks
-- (the Miracle Machine crash). The failure mode that makes it expensive is that
-- reading a client object's method as a field yields the FUNCTION, which is truthy —
-- so it slips past every `if not pos` guard and detonates far from the mistake.

-- ============================================================
-- Fake engine globals touched by the wom_utils module body
-- ============================================================

db     = { storage = {} }
level  = { object_by_id = function() return nil end }
alife  = function() return nil end
game   = { translate_string = function(key) return key end }
printf = function() end
xlevel = nil

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."

-- Loaded into its own environment (falling through to _G for the engine stubs) so
-- its functions land on a `wom_utils` table the way the game loads a module, rather
-- than leaking into _G.
local function load_script_as_module(path)
    local env = setmetatable({}, { __index = _G })
    local chunk
    if setfenv then                      -- Lua 5.1
        chunk = assert(loadfile(path))
        setfenv(chunk, env)
    else                                 -- Lua 5.2+
        chunk = assert(loadfile(path, "t", env))
    end
    chunk()
    return env
end

wom_utils = load_script_as_module(script_dir .. "/../gamedata/scripts/wom_utils.script")

-- ============================================================
-- Test harness
-- ============================================================

local pass_count, fail_count = 0, 0

local function check(label, got, expected)
    if got == expected then
        io.write(string.format("    PASS  %s\n", label))
        pass_count = pass_count + 1
    else
        io.write(string.format("    FAIL  %s\n", label))
        io.write(string.format("          got:      %s\n", tostring(got)))
        io.write(string.format("          expected: %s\n", tostring(expected)))
        fail_count = fail_count + 1
    end
end

local function group(name, fn)
    io.write(name .. "\n")
    fn()
end

-- ============================================================
-- Object stubs
-- ============================================================

local VECTOR = { x = 10, y = 0, z = 20 }

-- A server object: id and position are plain fields.
local function make_server_object()
    return { id = 42, position = VECTOR }
end

-- A client object: id and position are methods. Reading `.position` without
-- calling it returns the function, which is exactly the trap under test.
local function make_client_object()
    return {
        id       = function(self) return 42 end,
        position = function(self) return VECTOR end,
    }
end

-- ============================================================
-- Tests
-- ============================================================

group("get_object_position: shapes", function()
    check("server object → the vector field", wom_utils.get_object_position(make_server_object()), VECTOR)
    check("client object → the method's result", wom_utils.get_object_position(make_client_object()), VECTOR)
    check("nil object → nil", wom_utils.get_object_position(nil), nil)
    check("object with no position → nil", wom_utils.get_object_position({}), nil)
end)

group("get_object_position: never returns a function", function()
    -- The whole point: whatever comes back must be safe to index as a vector.
    local got = wom_utils.get_object_position(make_client_object())
    check("client object result is not a function", type(got) == "function", false)
    check("client object result is indexable as a vector", got and got.x, 10)
end)

group("get_object_position: a throwing accessor degrades to nil", function()
    -- Calling position() on a destroyed client object raises; a death callback must
    -- lose the location, not the frame.
    local destroyed = { position = function() error("you are trying to use a destroyed object") end }
    check("raising accessor → nil", wom_utils.get_object_position(destroyed), nil)
end)

group("get_object_id: shapes", function()
    check("server object → the id field", wom_utils.get_object_id(make_server_object()), 42)
    check("client object → the method's result", wom_utils.get_object_id(make_client_object()), 42)
    check("nil object → nil", wom_utils.get_object_id(nil), nil)
    check("object with no id → nil", wom_utils.get_object_id({}), nil)
end)

group("get_object_id: a throwing accessor degrades to nil", function()
    -- modxml_wom_dialog.npc_speaker calls this inside a dialog precondition, where a
    -- raise takes down the whole "I want to ask you something." menu rather than one
    -- lookup. Losing the id is the acceptable outcome; raising is not.
    local destroyed = { id = function() error("you are trying to use a destroyed object") end }
    check("raising accessor → nil", wom_utils.get_object_id(destroyed), nil)

    -- A method that returns something other than a number is equally unusable.
    local bogus = { id = function() return "42" end }
    check("non-numeric result → nil", wom_utils.get_object_id(bogus), nil)
end)

group("get_live_online_npc: rejects what it cannot verify", function()
    check("nil id → nil", wom_utils.get_live_online_npc(nil), nil)
    check("INVALID_ENTITY_ID → nil", wom_utils.get_live_online_npc(65535), nil)
    check("id not in the level object map → nil", wom_utils.get_live_online_npc(7), nil)

    -- Mapped by the level but released from the simulation: still not usable.
    local orphan = { alive = function() return true end }
    level.object_by_id = function(id) return orphan end
    alife = function() return nil end
    check("no server object → nil", wom_utils.get_live_online_npc(7), nil)

    -- Mapped and simulated, but the object is destroyed: :alive() raises.
    local destroyed = { alive = function() error("you are trying to use a destroyed object") end }
    level.object_by_id = function(id) return destroyed end
    alife = function() return { object = function(self, id) return {} end } end
    check("destroyed object → nil, no error", wom_utils.get_live_online_npc(7), nil)

    -- The happy path.
    local live = { alive = function() return true end }
    level.object_by_id = function(id) return live end
    check("live online npc → the object", wom_utils.get_live_online_npc(7), live)

    -- Alive-but-dead is filtered too.
    local corpse = { alive = function() return false end }
    level.object_by_id = function(id) return corpse end
    check("dead npc → nil", wom_utils.get_live_online_npc(7), nil)
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

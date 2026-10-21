-- tests/test_wom_debug.lua
-- Standalone Lua 5.1 tests for wom_debug's module load.
--
-- Run from the repository root:  lua tests/test_wom_debug.lua
-- Run from tests/:               lua test_wom_debug.lua
--
-- wom_debug builds its xlog logger at file scope. When that raised (xlibs absent, or
-- xlog unable to build a logger), the engine kept the half-built namespace: `wom_debug`
-- resolved, but every function in it was nil. wom_combat calls into it from unguarded
-- death callbacks, so the game crashed on the first duplicate death with
--   wom_combat.script:237: attempt to call field 'log_dedup' (a nil value)
-- These tests load the real script under each of those conditions and require every
-- public function to exist and be callable.

printf = function() end
level  = nil
getFS  = nil

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."

-- Loads wom_debug into its own environment the way the game loads a module.
-- Returns the environment and whether the chunk ran without raising.
-- @return table, boolean, string|nil
local function load_wom_debug()
    local path = script_dir .. "/../gamedata/scripts/wom_debug.script"
    local env = setmetatable({}, { __index = _G })
    local chunk
    if setfenv then                      -- Lua 5.1
        chunk = assert(loadfile(path))
        setfenv(chunk, env)
    else                                 -- Lua 5.2+
        chunk = assert(loadfile(path, "t", env))
    end
    local ok, err = pcall(chunk)
    return env, ok, err
end

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

local PUBLIC_FUNCTIONS = {
    "get_log_dir", "enabled", "init_log_level", "on_game_start",
    "log_kill", "log_response", "log_trace", "log_dedup", "log_collect_combat",
}

-- Asserts the module loaded whole and that its log calls are safe no-ops.
-- @param env table  the loaded module environment
-- @param ok  boolean
local function check_loaded_inert(env, ok)
    check("module body ran without raising", ok, true)
    for _, name in ipairs(PUBLIC_FUNCTIONS) do
        check(name .. " is defined", type(env[name]), "function")
    end
    check("logging reads as disabled", env.enabled and env.enabled(), false)
    check("log_dedup is a safe no-op",
          pcall(env.log_dedup or error, 42, 1.5), true)
    check("log_trace is a safe no-op",
          pcall(env.log_trace or error, "tag", "message"), true)
end

-- ============================================================
-- Tests
-- ============================================================

group("load: xlibs absent", function()
    xlog = nil
    local env, ok = load_wom_debug()
    check_loaded_inert(env, ok)
end)

group("load: xlog present but get_logger missing", function()
    xlog = {}
    local env, ok = load_wom_debug()
    check_loaded_inert(env, ok)
end)

group("load: xlog.get_logger raises", function()
    xlog = { get_logger = function() error("xlog exploded") end }
    local env, ok = load_wom_debug()
    check_loaded_inert(env, ok)
end)

group("load: a working xlog is used", function()
    local level_now = 3
    local debug_lines = {}
    xlog = {
        get_logger = function(name, cfg)
            return {
                get_level = function() return level_now end,
                set_level = function(lvl) level_now = (lvl == "DEBUG") and 5 or 3 end,
                debug     = function(msg) debug_lines[#debug_lines + 1] = msg end,
            }
        end,
    }
    wom_mcm = { enable_logging = function() return true end }
    local env, ok = load_wom_debug()
    check("module body ran without raising", ok, true)
    check("disabled at the WARN default", env.enabled(), false)
    env.init_log_level()
    check("enabled once MCM turns logging on", env.enabled(), true)
    env.log_dedup(42, 1.5)
    check("log_dedup reached the real logger", #debug_lines, 1)
    wom_mcm = nil
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

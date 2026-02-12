-- ProjectSpeed_Governor.lua
-- FlyWithLua UDP bridge for Project Speed Governor Mode.
-- Listens on localhost UDP and applies LOD bias safely.

local UDP_HOST = "127.0.0.1"
local UDP_PORT = 49006

local CLAMP_MIN = 0.75
local CLAMP_MAX = 1.80

local socket_ok, socket = pcall(require, "socket")
if not socket_ok then
    logMsg("[ProjectSpeed_Governor] LuaSocket not available; governor bridge disabled.")
    return
end

dataref("project_speed_lod_bias_rat", "sim/private/controls/reno/LOD_bias_rat", "writable")

local udp = socket.udp()
local original_lod = project_speed_lod_bias_rat
local governor_active = false

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function restore_lod()
    if original_lod ~= nil then
        project_speed_lod_bias_rat = original_lod
        governor_active = false
        logMsg("[ProjectSpeed_Governor] Restored original LOD_bias_rat=" .. string.format("%.3f", original_lod))
    end
end

local function apply_lod(value)
    local clamped = clamp(value, CLAMP_MIN, CLAMP_MAX)
    project_speed_lod_bias_rat = clamped
    governor_active = true
    logMsg("[ProjectSpeed_Governor] Applied LOD_bias_rat=" .. string.format("%.3f", clamped))
end

local function handle_message(message)
    if message == nil then return end

    if string.sub(message, 1, 18) == "PROJECT_SPEED|DISABLE" then
        restore_lod()
        return
    end

    local prefix = "PROJECT_SPEED|SET_LOD|"
    if string.sub(message, 1, string.len(prefix)) ~= prefix then
        return
    end

    local payload = string.sub(message, string.len(prefix) + 1)
    local lod_value = tonumber(string.match(payload, "^[^|]+"))

    if lod_value == nil then
        logMsg("[ProjectSpeed_Governor] Invalid LOD command payload: " .. tostring(message))
        return
    end

    apply_lod(lod_value)
end

local function poll_udp()
    local data, _ = udp:receivefrom()
    while data ~= nil do
        handle_message(data)
        data, _ = udp:receivefrom()
    end
end

udp:setsockname(UDP_HOST, UDP_PORT)
udp:settimeout(0)

logMsg("[ProjectSpeed_Governor] Listening on " .. UDP_HOST .. ":" .. UDP_PORT)

function project_speed_governor_update()
    poll_udp()
end

do_every_frame("project_speed_governor_update()")
do_on_exit("restore_lod()")

-- ProjectSpeed_Governor.lua
-- FlyWithLua companion for Project Speed LOD Governor.
-- Listens for UDP commands and applies:
--   set("sim/private/controls/reno/LOD_bias_rat", value)

local UDP_HOST = "127.0.0.1"
local UDP_PORT = 49006

-- User-adjustable script-side safety bounds.
local CLAMP_MIN = 0.20
local CLAMP_MAX = 3.00

local socket_ok, socket = pcall(require, "socket")
if not socket_ok then
    logMsg("[ProjectSpeed_Governor] LuaSocket not available; governor disabled.")
    return
end

dataref("project_speed_lod_bias_rat", "sim/private/controls/reno/LOD_bias_rat", "writable")

local udp = socket.udp()
local original_lod = project_speed_lod_bias_rat
local governor_enabled = false
local last_applied_lod = project_speed_lod_bias_rat

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function restore_original_lod()
    if original_lod ~= nil then
        project_speed_lod_bias_rat = original_lod
        last_applied_lod = original_lod
    end
    governor_enabled = false
    logMsg("[ProjectSpeed_Governor] Restored original LOD_bias_rat=" .. string.format("%.3f", last_applied_lod))
end

local function apply_lod(value)
    local clamped = clamp(value, CLAMP_MIN, CLAMP_MAX)
    project_speed_lod_bias_rat = clamped

    if last_applied_lod == nil or math.abs(last_applied_lod - clamped) >= 0.01 then
        logMsg("[ProjectSpeed_Governor] Applied LOD_bias_rat=" .. string.format("%.3f", clamped))
    end

    last_applied_lod = clamped
    governor_enabled = true
end

local function parse_set_lod(message)
    if message == nil then return nil end

    local prefix = "SET_LOD "
    if string.sub(message, 1, string.len(prefix)) == prefix then
        return tonumber(string.sub(message, string.len(prefix) + 1))
    end

    local legacy_prefix = "PROJECT_SPEED|SET_LOD|"
    if string.sub(message, 1, string.len(legacy_prefix)) == legacy_prefix then
        local payload = string.sub(message, string.len(legacy_prefix) + 1)
        local first_field = string.match(payload, "^[^|]+")
        return tonumber(first_field)
    end

    return nil
end

local function handle_message(raw_message)
    if raw_message == nil then return end

    local message = string.gsub(raw_message, "[%c%s]+$", "")
    if message == "" then return end

    if message == "ENABLE" or message == "PROJECT_SPEED|ENABLE" then
        governor_enabled = true
        return
    end

    if message == "DISABLE" or message == "PROJECT_SPEED|DISABLE" then
        restore_original_lod()
        return
    end

    local lod_value = parse_set_lod(message)
    if lod_value == nil then
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

local bind_ok, bind_error = udp:setsockname(UDP_HOST, UDP_PORT)
if bind_ok == nil then
    logMsg("[ProjectSpeed_Governor] UDP bind failed on " .. UDP_HOST .. ":" .. UDP_PORT .. " error=" .. tostring(bind_error))
    return
end

udp:settimeout(0)
logMsg("[ProjectSpeed_Governor] Listening on " .. UDP_HOST .. ":" .. UDP_PORT .. " clamp=" .. CLAMP_MIN .. "-" .. CLAMP_MAX)

function project_speed_governor_update()
    poll_udp()
end

do_every_frame("project_speed_governor_update()")
do_on_exit("restore_original_lod()")

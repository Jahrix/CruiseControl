-- ProjectSpeed_Governor.lua
-- FlyWithLua companion for Project Speed LOD Governor.
-- Applies private XP12 LOD dataref inside X-Plane:
--   set("sim/private/controls/reno/LOD_bias_rat", value)

local LOD_DATAREF = "sim/private/controls/reno/LOD_bias_rat"
local UDP_HOST = "127.0.0.1"
local UDP_PORT = 49006
local COMMAND_FILE_PATH = "/tmp/ProjectSpeed_lod_target.txt"

-- User-adjustable script-side safety bounds.
local CLAMP_MIN = 0.20
local CLAMP_MAX = 3.00

local socket_ok, socket = pcall(require, "socket")
local udp = nil
local udp_enabled = false
local file_sequence = nil

local function read_lod()
    local ok, value = pcall(get, LOD_DATAREF)
    if not ok then
        return nil
    end
    return tonumber(value)
end

local function write_lod(value)
    local ok, err = pcall(set, LOD_DATAREF, value)
    if not ok then
        logMsg("[ProjectSpeed_Governor] Failed to set LOD dataref: " .. tostring(err))
        return false
    end
    return true
end

local original_lod = read_lod()
if original_lod == nil then
    logMsg("[ProjectSpeed_Governor] Could not read " .. LOD_DATAREF .. "; governor disabled.")
    return
end

local governor_enabled = false
local last_applied_lod = original_lod

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function restore_original_lod()
    if original_lod ~= nil then
        if write_lod(original_lod) then
            last_applied_lod = original_lod
        end
    end
    governor_enabled = false
    logMsg("[ProjectSpeed_Governor] Restored original LOD_bias_rat=" .. string.format("%.3f", last_applied_lod))
end

local function apply_lod(value)
    local clamped = clamp(value, CLAMP_MIN, CLAMP_MAX)
    if not write_lod(clamped) then
        return
    end

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
    if not udp_enabled or udp == nil then
        return
    end

    local data, _ = udp:receivefrom()
    while data ~= nil do
        handle_message(data)
        data, _ = udp:receivefrom()
    end
end

local function initialize_file_sequence()
    local file = io.open(COMMAND_FILE_PATH, "r")
    if file == nil then
        return
    end

    local line = file:read("*l")
    file:close()
    if line == nil then
        return
    end

    local seq = string.match(line, "^(%d+)|")
    if seq ~= nil then
        file_sequence = seq
    end
end

local function poll_file_commands()
    local file = io.open(COMMAND_FILE_PATH, "r")
    if file == nil then
        return
    end

    local line = file:read("*l")
    file:close()
    if line == nil or line == "" then
        return
    end

    local seq, message = string.match(line, "^(%d+)|(.+)$")
    if seq ~= nil then
        if seq == file_sequence then
            return
        end
        file_sequence = seq
        handle_message(message)
        return
    end

    -- Legacy/plain command without sequence.
    handle_message(line)
end

if socket_ok then
    udp = socket.udp()
    local bind_ok, bind_error = udp:setsockname(UDP_HOST, UDP_PORT)
    if bind_ok ~= nil then
        udp:settimeout(0)
        udp_enabled = true
        logMsg("[ProjectSpeed_Governor] UDP listening on " .. UDP_HOST .. ":" .. UDP_PORT .. " clamp=" .. CLAMP_MIN .. "-" .. CLAMP_MAX)
    else
        logMsg("[ProjectSpeed_Governor] UDP bind failed on " .. UDP_HOST .. ":" .. UDP_PORT .. " error=" .. tostring(bind_error) .. " | using file fallback")
    end
else
    logMsg("[ProjectSpeed_Governor] LuaSocket not available; using file fallback")
end

initialize_file_sequence()
logMsg("[ProjectSpeed_Governor] File command path: " .. COMMAND_FILE_PATH)

function project_speed_governor_update()
    poll_udp()
    poll_file_commands()
end

do_every_frame("project_speed_governor_update()")
do_on_exit("restore_original_lod()")

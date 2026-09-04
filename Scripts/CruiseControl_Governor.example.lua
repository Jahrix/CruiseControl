-- CruiseControl_Governor.example.lua
--
-- Install as CruiseControl_Governor.lua in:
-- X-Plane 11/12/Resources/plugins/FlyWithLua/Scripts/
--
-- The script receives CruiseControl governor commands and publishes a
-- read-only status file. Flight-context fields are sourced only from public
-- X-Plane datarefs; it does not change X-Plane settings to collect them.

local LOD_DATAREF = "sim/private/controls/reno/LOD_bias_rat"
local UDP_HOST = "127.0.0.1"
local UDP_PORT = 49006
local STATUS_INTERVAL_SECONDS = 1

local home = os.getenv("HOME") or ""
-- CruiseControl is sandboxed, so its supported bridge folder is inside its
-- application container rather than the shared Application Support directory.
local bridge_folder = home .. "/Library/Containers/jahrix.CruiseControl/Data/Library/Application Support/CruiseControl"
local MODE_FILE_PATH = bridge_folder .. "/lod_mode.txt"
local STATUS_FILE_PATH = bridge_folder .. "/lod_status.txt"

local CLAMP_MIN = 0.20
local CLAMP_MAX = 3.00

local socket_ok, socket = pcall(require, "socket")
local udp = nil
local udp_enabled = false
local governor_enabled = false
local last_applied_lod = nil
local last_requested_lod = nil
local last_lod_write_id = nil
local last_status_epoch = 0
local last_mode_file_value = nil

local function safely_get(dataref)
    local ok, value = pcall(get, dataref)
    if ok then return value end
    return nil
end

local function read_lod()
    return tonumber(safely_get(LOD_DATAREF))
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function write_lod(value)
    local ok, err = pcall(set, LOD_DATAREF, value)
    if not ok then
        logMsg("[CruiseControl_Governor] Failed to set LOD dataref: " .. tostring(err))
        return false
    end
    -- FlyWithLua's set() returning normally is not a write guarantee. Read
    -- the exact dataref again before reporting a successful bridge write.
    local observed = read_lod()
    if observed == nil or math.abs(observed - value) > 0.01 then
        logMsg("[CruiseControl_Governor] LOD write did not produce a matching readback.")
        return nil
    end
    return observed
end

local original_lod = read_lod()
if original_lod == nil then
    logMsg("[CruiseControl_Governor] Could not read " .. LOD_DATAREF .. "; governor commands are disabled.")
end
last_applied_lod = original_lod

local function apply_lod(value, request_id)
    if original_lod == nil then return nil end

    local clamped = clamp(value, CLAMP_MIN, CLAMP_MAX)
    local observed = write_lod(clamped)
    if observed == nil then return nil end

    last_applied_lod = observed
    last_requested_lod = clamped
    last_lod_write_id = request_id
    governor_enabled = true
    return observed
end

local function restore_original_lod()
    if original_lod ~= nil then
        local observed = write_lod(original_lod)
        if observed ~= nil then
            last_applied_lod = observed
        else
            logMsg("[CruiseControl_Governor] Could not verify original LOD restoration.")
        end
    end
    governor_enabled = false
end

local function trim(value)
    if value == nil then return nil end
    return string.gsub(tostring(value), "^%s*(.-)%s*$", "%1")
end

local function write_optional(handle, key, value)
    local normalized = trim(value)
    if normalized ~= nil and normalized ~= "" then
        handle:write(key .. "=" .. normalized .. "\n")
    end
end

local function simulator_version()
    local version = tonumber(safely_get("sim/version/xplane_internal_version"))
    if version == nil then return nil end
    if version >= 100000 then
        if version >= 120000 then return "XP12" end
        if version >= 110000 then return "XP11" end
    else
        if version >= 1200 then return "XP12" end
        if version >= 1100 then return "XP11" end
    end
    return nil
end

local function on_ground()
    local value = tonumber(safely_get("sim/flightmodel/failures/onground_any"))
    if value == nil then return nil end
    return value >= 0.5 and "true" or "false"
end

local function nearest_airport_icao()
    if type(XPLMFindNavAid) ~= "function" or
       type(XPLMGetNavAidInfo) ~= "function" or
       xplm_Nav_Airport == nil then
        return nil
    end

    local latitude = tonumber(safely_get("sim/flightmodel/position/latitude"))
    local longitude = tonumber(safely_get("sim/flightmodel/position/longitude"))
    if latitude == nil or longitude == nil then return nil end

    local ok, reference = pcall(
        XPLMFindNavAid,
        nil,
        nil,
        latitude,
        longitude,
        nil,
        xplm_Nav_Airport
    )
    if not ok or reference == nil or reference == XPLM_NAV_NOT_FOUND then return nil end

    local info_ok, _, _, _, _, _, _, identifier = pcall(XPLMGetNavAidInfo, reference)
    if not info_ok then return nil end
    return identifier
end

local function write_status()
    local file = io.open(STATUS_FILE_PATH, "w")
    if file == nil then return end

    file:write("enabled=" .. (governor_enabled and "1" or "0") .. "\n")
    -- Status is an observation, never a restatement of the requested value.
    local observed_lod = read_lod()
    if observed_lod ~= nil then file:write(string.format("current_lod=%.3f\n", observed_lod)) end
    if last_requested_lod ~= nil then file:write(string.format("target_lod=%.3f\n", last_requested_lod)) end
    if last_lod_write_id ~= nil then file:write("last_lod_write_id=" .. last_lod_write_id .. "\n") end
    -- Reading a dataref is not proof that it is writable. The current
    -- companion deliberately does not probe by changing a simulator setting,
    -- so a future verified bridge must explicitly publish true before
    -- CruiseControl can authorize a write.
    file:write("lod_write_supported=unknown\n")
    file:write("tier=MANUAL\n")
    file:write("last_update_epoch=" .. tostring(os.time()) .. "\n")

    -- Read-only FlightContext keys consumed by CruiseControl.
    write_optional(file, "simulator_version", simulator_version())
    write_optional(file, "aircraft_identifier", safely_get("sim/aircraft/view/acf_ICAO"))
    write_optional(file, "aircraft_name", safely_get("sim/aircraft/view/acf_descrip"))
    write_optional(file, "nearest_airport_icao", nearest_airport_icao())
    write_optional(file, "on_ground", on_ground())

    file:close()
end

local function send_response(message, ip, port)
    if not udp_enabled or udp == nil or ip == nil or port == nil then return end
    udp:sendto(tostring(message) .. "\n", tostring(ip), tonumber(port))
end

local function handle_command(raw)
    local message = trim(raw)
    if message == nil or message == "" then return "ERR empty command" end

    if message == "PING" then return "PONG" end
    if message == "ENABLE" then
        governor_enabled = true
        return "ACK ENABLE"
    end
    if message == "DISABLE" then
        restore_original_lod()
        return "ACK DISABLE"
    end

    -- SET_LOD must carry a caller nonce. The nonce is emitted to status only
    -- after a matching dataref readback, so CruiseControl can reject stale
    -- status from a prior write.
    local requested, request_id = string.match(message, "^SET_LOD%s+([^%s]+)%s+([^%s]+)$")
    local value = requested and tonumber(requested) or nil
    if value ~= nil and request_id ~= nil then
        local applied = apply_lod(value, request_id)
        if applied == nil then return "ERR failed to apply LOD" end
        write_status()
        return string.format("ACK SET_LOD %.3f %s", applied, request_id)
    end

    return "ERR unknown command"
end

local function poll_udp()
    if not udp_enabled or udp == nil then return end

    local data, ip, port = udp:receivefrom()
    while data ~= nil do
        send_response(handle_command(data), ip, port)
        data, ip, port = udp:receivefrom()
    end
end

local function read_first_line(path)
    local file = io.open(path, "r")
    if file == nil then return nil end
    local line = file:read("*l")
    file:close()
    return trim(line)
end

local function poll_file_bridge()
    local mode = read_first_line(MODE_FILE_PATH)
    if mode ~= nil and mode ~= last_mode_file_value then
        last_mode_file_value = mode
        if mode == "ENABLED=1" then handle_command("ENABLE") end
    end

    -- File commands cannot provide a value-bearing ACK and fresh correlated
    -- readback. They remain intentionally unable to change LOD.
end

if socket_ok then
    udp = socket.udp()
    local bind_ok, bind_error = udp:setsockname(UDP_HOST, UDP_PORT)
    if bind_ok ~= nil then
        udp:settimeout(0)
        udp_enabled = true
        logMsg("[CruiseControl_Governor] UDP listening on " .. UDP_HOST .. ":" .. UDP_PORT)
    else
        logMsg("[CruiseControl_Governor] UDP unavailable: " .. tostring(bind_error) .. " | using file bridge")
    end
else
    logMsg("[CruiseControl_Governor] LuaSocket unavailable; using file bridge")
end

function cruisecontrol_governor_update()
    poll_udp()
    poll_file_bridge()

    local now = os.time()
    if now - last_status_epoch >= STATUS_INTERVAL_SECONDS then
        last_status_epoch = now
        write_status()
    end
end

function cruisecontrol_governor_exit()
    restore_original_lod()
    write_status()
end

do_every_frame("cruisecontrol_governor_update()")
do_on_exit("cruisecontrol_governor_exit()")

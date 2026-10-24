-- The companion's optimistic write against the handoffs the account sends after
-- it: a read the cloud has not caught up with must not put the proxy back on the
-- old setpoint, and the write keeps being re-sent until a read confirms it.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_companion_write.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.timer")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/nuheat_thermostat/driver.lua"

local PROXY_BINDING = 5001
local ACCOUNT_BINDING = 5002

local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  table.insert(sends, { idBinding = idBinding, command = command, params = tParams })
end

local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end

dofile(DRIVER)

local function device(overrides)
  local d = {
    SerialNumber = "1",
    Online = true,
    Temperature = 2150,
    SetPointTemp = 2200,
    Heating = false,
    ScheduleMode = 1,
    OperatingMode = 1,
  }
  for k, v in pairs(overrides or {}) do
    d[k] = v
  end
  return d
end

local function handOver(d)
  RFP.updateThermostat(ACCOUNT_BINDING, "updateThermostat", { JSON = JSON:encode(d) })
end

local function lastSetpoint()
  for i = #sends, 1, -1 do
    if sends[i].command == "HEAT_SETPOINT_CHANGED" then
      return tonumber(sends[i].params.SETPOINT)
    end
  end
end

local function writesToAccount()
  local n = 0
  for _, send in ipairs(sends) do
    if send.idBinding == ACCOUNT_BINDING and send.command == "setThermostat" then
      n = n + 1
    end
  end
  return n
end

T.section("a stale read after a setpoint change")
handOver(device())
T.eq("starts at 22 C", lastSetpoint(), 22)
RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", { CELSIUS = "25" })
T.eq("shows 25 C at once", lastSetpoint(), 25)
T.eq("and sends the write up", writesToAccount(), 1)
handOver(device())
T.eq("a read still at 22 C does not put it back", lastSetpoint(), 25)
timers.NuheatConfirm.callback()
T.eq("the write is sent again", writesToAccount(), 2)

T.section("the read that carries the change ends the wait")
handOver(device({ SetPointTemp = 2500, ScheduleMode = 2 }))
T.eq("25 C", lastSetpoint(), 25)
sends = {}
timers.NuheatConfirm.callback()
T.eq("and nothing more is sent", writesToAccount(), 0)

T.section("a Fahrenheit project's setpoint is read in Fahrenheit")
-- Captured from the thermostatV2 proxy on a 4.3 controller in a Fahrenheit
-- project, setting 24.5 C: CELSIUS arrives rounded to a whole degree.
RFP.goOffline(ACCOUNT_BINDING, "goOffline")
handOver(device())
RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = "FAHRENHEIT" })
sends = {}
RFP.SET_SETPOINT_HEAT(
  PROXY_BINDING,
  "SET_SETPOINT_HEAT",
  { CELSIUS = "25", FAHRENHEIT = "76", KELVIN = "2976", SETPOINT = "76" }
)
local written
for _, send in ipairs(sends) do
  if send.command == "setThermostat" then
    written = JSON:decode(send.params.JSON)
  end
end
T.eq("76 F is written as 24.5 C, not 25", written and written.SetPointTemp, 2450)
RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = "CELSIUS" })
sends = {}
RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", { CELSIUS = "24.5", FAHRENHEIT = "76" })
for _, send in ipairs(sends) do
  if send.command == "setThermostat" then
    written = JSON:decode(send.params.JSON)
  end
end
T.eq("a Celsius project reads CELSIUS", written and written.SetPointTemp, 2450)

T.section("Heat/Off arrives as SET_MODE_HVAC")
local function lastWrite()
  local written
  for _, send in ipairs(sends) do
    if send.command == "setThermostat" then
      written = JSON:decode(send.params.JSON)
    end
  end
  return written
end
RFP.goOffline(ACCOUNT_BINDING, "goOffline")
handOver(device())
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Off" })
T.eq("Off holds permanently", lastWrite() and lastWrite().ScheduleMode, 3)
T.eq("at 5 C", lastWrite() and lastWrite().SetPointTemp, 500)
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Heat" })
T.eq("Heat resumes the schedule", lastWrite() and lastWrite().ScheduleMode, 1)
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Cool" })
T.eq("a mode it does not have writes nothing", lastWrite(), nil)
RFP.goOffline(ACCOUNT_BINDING, "goOffline")
handOver(device({ OperatingMode = 2 }))
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Off" })
T.eq("Off in Manual operating mode writes nothing", lastWrite(), nil)
sends = {}
RFP.SET_MODE_OFF(PROXY_BINDING, "SET_MODE_OFF", {})
T.eq("nor does SET_MODE_OFF", lastWrite(), nil)

T.finish()

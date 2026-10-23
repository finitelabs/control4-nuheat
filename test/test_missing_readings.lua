-- What the driver does with a handoff that omits a numeric field.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_missing_readings.lua
--
-- Every number this driver reads comes from cloud JSON or from the proxy, so it
-- can be absent, JSON-null or non-numeric: the OpenAPI marks setPointTemp
-- nullable, and a stale-handoff merge copies Temperature across
-- unconditionally. `tonumber` also yields infinity for "1e999", which passes every
-- `== nil` test downstream.
--
-- Regression test for DRV-122.

local T = require("testlib")

require("c4_shim")

local Thermostat = require("nuheat.thermostat")
local constants = require("constants")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/nuheat_thermostat/driver.lua"

local PROXY_BINDING = 5001
local ACCOUNT_BINDING = 5002
local TEMP_OUTPUT_BINDING = 5010

local NAN = 0 / 0
--- Marks a field to delete from the device object, since a nil in an overrides
--- table is indistinguishable from an absent key.
local ABSENT = {}

--- Captured at C4.SendToProxy rather than the global SendToProxy of the same
--- name: the global is a wrapper in lib/utils.lua that forwards through C4Call,
--- so stubbing it would measure the argument the driver passed instead of what
--- came out the far end of the path it actually takes.
local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams })
end

dofile(DRIVER)

--- A Nuheat thermostat object as the account driver hands it over. Nuheat
--- reports centidegrees, so 2150 is 21.5 °C.
local function device(overrides)
  local d = {
    SerialNumber = "SN-1",
    Online = true,
    Temperature = 2150,
    SetPointTemp = 2200,
    Heating = true,
    ScheduleMode = 1,
    OperatingMode = 1,
  }
  for k, v in pairs(overrides or {}) do
    d[k] = v ~= ABSENT and v or nil
  end
  return d
end

--- Hand a device over and return everything the driver sent in response. The
--- handoff is driven through RFP.updateThermostat, not by calling pushState, so
--- what is measured is the path a poll actually takes.
---
--- goOffline first because an optimistic write from an earlier section leaves a
--- pending mode behind, and a handoff arriving under one is merged field by
--- field instead of adopted.
local function handOver(overrides)
  RFP.goOffline(ACCOUNT_BINDING, "goOffline")
  sends = {}
  RFP.updateThermostat(ACCOUNT_BINDING, "updateThermostat", { JSON = JSON:encode(device(overrides)) })
  return sends
end

local function findSend(list, idBinding, command)
  for _, send in ipairs(list) do
    if send.idBinding == idBinding and send.command == command then
      return send
    end
  end
  return nil
end

local function countSends(list, command)
  local n = 0
  for _, send in ipairs(list) do
    if send.command == command then
      n = n + 1
    end
  end
  return n
end

--- Set the display scale the way Navigator does, and clear the capture.
local function useScale(scale)
  RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = scale })
  sends = {}
end

--------------------------------------------------------------------------------
T.section("a handoff carrying every reading is unaffected")
--------------------------------------------------------------------------------

-- The positive control for everything below: a guard that withheld too much
-- would pass every absence assertion in this file and fail here.
local complete = handOver()

T.eq(
  "TEMPERATURE_CHANGED carries the reading",
  findSend(complete, PROXY_BINDING, "TEMPERATURE_CHANGED").params.TEMPERATURE,
  "21.5"
)
T.eq(
  "HEAT_SETPOINT_CHANGED carries the setpoint",
  findSend(complete, PROXY_BINDING, "HEAT_SETPOINT_CHANGED").params.SETPOINT,
  "22"
)
T.eq(
  "the sensor binding carries CELSIUS",
  findSend(complete, TEMP_OUTPUT_BINDING, "VALUE_CHANGED").params.CELSIUS,
  21.5
)

--------------------------------------------------------------------------------
T.section("a handoff with no temperature withholds the reading")
--------------------------------------------------------------------------------

-- Pushing tostring(nil) put the literal string "nil" on the thermostat proxy and
-- a VALUE_CHANGED with no value at all on the sensor binding.
local noTemperature = handOver({ Temperature = ABSENT })

T.eq("no TEMPERATURE_CHANGED is sent", findSend(noTemperature, PROXY_BINDING, "TEMPERATURE_CHANGED"), nil)
T.eq(
  "no VALUE_CHANGED is sent to the sensor binding",
  findSend(noTemperature, TEMP_OUTPUT_BINDING, "VALUE_CHANGED"),
  nil
)

-- The rest of the push is what makes this a withheld reading rather than an
-- aborted handoff: pushState used to raise here on some inputs, and everything
-- after it went unsent.
T.truthy("ONLINE_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "ONLINE_CHANGED"))
T.truthy("HEAT_SETPOINT_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "HEAT_SETPOINT_CHANGED"))
T.truthy("HVAC_MODE_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "HVAC_MODE_CHANGED"))
T.truthy("HOLD_MODE_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "HOLD_MODE_CHANGED"))

-- A JSON null and a non-numeric string reach the driver as the same thing a
-- missing key does, and "1e999" parses to infinity rather than to nil.
T.eq(
  "a non-numeric temperature is withheld too",
  findSend(handOver({ Temperature = "warm" }), PROXY_BINDING, "TEMPERATURE_CHANGED"),
  nil
)
T.eq(
  "an infinite temperature is withheld too",
  findSend(handOver({ Temperature = "1e999" }), PROXY_BINDING, "TEMPERATURE_CHANGED"),
  nil
)

--------------------------------------------------------------------------------
T.section("a handoff with no setpoint withholds the setpoint")
--------------------------------------------------------------------------------

local noSetpoint = handOver({ SetPointTemp = ABSENT })

T.eq("no HEAT_SETPOINT_CHANGED is sent", findSend(noSetpoint, PROXY_BINDING, "HEAT_SETPOINT_CHANGED"), nil)
T.truthy("the temperature is still sent", findSend(noSetpoint, PROXY_BINDING, "TEMPERATURE_CHANGED"))
T.truthy("the sensor binding is still sent", findSend(noSetpoint, TEMP_OUTPUT_BINDING, "VALUE_CHANGED"))

--------------------------------------------------------------------------------
T.section("no payload carries a stringified nil")
--------------------------------------------------------------------------------

-- Asserted over every param of every send rather than over the two known keys,
-- so a new tostring() on a nullable field is caught by this file too.
local function stringifiedNils(list)
  local hits = {}
  for _, send in ipairs(list) do
    for key, value in pairs(send.params or {}) do
      if value == "nil" then
        table.insert(hits, send.command .. "." .. tostring(key))
      end
    end
  end
  return hits
end

T.eq("none with the temperature missing", stringifiedNils(handOver({ Temperature = ABSENT })), {})
T.eq("none with the setpoint missing", stringifiedNils(handOver({ SetPointTemp = ABSENT })), {})
T.eq("none with both missing", stringifiedNils(handOver({ Temperature = ABSENT, SetPointTemp = ABSENT })), {})

--------------------------------------------------------------------------------
T.section("stepping a setpoint the device never reported")
--------------------------------------------------------------------------------

-- INC/DEC_SETPOINT_HEAT is a touchscreen button. Both scales are driven because
-- the Celsius branch does its own arithmetic and the Fahrenheit branch converts.
for _, scale in ipairs({ "C", "F" }) do
  handOver({ SetPointTemp = ABSENT })
  useScale(scale)
  local ok = pcall(RFP.INC_SETPOINT_HEAT, PROXY_BINDING)
  T.truthy("stepping up in " .. scale .. " does not raise", ok)
  T.eq("and writes nothing back to the account", countSends(sends, "SET_THERMOSTAT"), 0)

  sends = {}
  ok = pcall(RFP.DEC_SETPOINT_HEAT, PROXY_BINDING)
  T.truthy("stepping down in " .. scale .. " does not raise", ok)
  T.eq("and writes nothing back to the account either", countSends(sends, "SET_THERMOSTAT"), 0)
end

-- The control: with a setpoint present the button still moves it.
handOver()
useScale("C")
RFP.INC_SETPOINT_HEAT(PROXY_BINDING)
T.eq(
  "a reported setpoint still steps half a degree C",
  findSend(sends, PROXY_BINDING, "HEAT_SETPOINT_CHANGED").params.SETPOINT,
  "22.5"
)

--------------------------------------------------------------------------------
T.section("a setpoint command that is not a finite number is dropped")
--------------------------------------------------------------------------------

-- An infinite setpoint would reach the device as a JSON null.
local function adoptedSetpoint(tParams)
  handOver()
  sends = {}
  RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", tParams)
  local send = findSend(sends, PROXY_BINDING, "HEAT_SETPOINT_CHANGED")
  return send and send.params.SETPOINT or nil
end

T.eq("an infinite CELSIUS is dropped", adoptedSetpoint({ CELSIUS = "1e999" }), nil)
T.eq("an infinite FAHRENHEIT is dropped", adoptedSetpoint({ FAHRENHEIT = "1e999" }), nil)
T.eq("a finite setpoint is still adopted", adoptedSetpoint({ CELSIUS = "23.5" }), "23.5")

--------------------------------------------------------------------------------
T.section("the conversion helpers answer nil instead of raising")
--------------------------------------------------------------------------------

-- These are the raise sites themselves. The driver guards above are what keeps
-- the nil from travelling, but the helpers are typed number|nil and several
-- callers test the result, so returning nil is the contract.
for _, case in ipairs({
  { "nil", nil },
  { "a non-numeric string", "warm" },
  { "infinity", math.huge },
  { "a NaN", NAN },
  { "an overflowing literal", "1e999" },
}) do
  local label, value = case[1], case[2]
  T.eq("nuheatToC(" .. label .. ")", Thermostat.nuheatToC(value), nil)
  T.eq("cToF(" .. label .. ")", Thermostat.cToF(value), nil)
  T.eq("fToC(" .. label .. ")", Thermostat.fToC(value), nil)
  T.eq("normalize(" .. label .. ")", Thermostat.normalize(value), nil)
  T.eq(
    "stepSetpointC(" .. label .. ")",
    Thermostat.stepSetpointC({ setpointC = value, minC = 5, maxC = 70 }, 1, "C"),
    nil
  )
end

-- Values chosen to be exact in binary floating point, so this fails on a changed
-- conversion rather than on a rounding difference. The guards must not have
-- turned these helpers into the template's rounding c2f/f2c.
T.eq("cToF still converts", Thermostat.cToF(20), 68)
T.eq("cToF is unrounded", Thermostat.cToF(21.25), 70.25)
T.eq("fToC still converts", Thermostat.fToC(68), 20)
T.eq("nuheatToC still scales", Thermostat.nuheatToC(2150), 21.5)
T.eq("nuheatToC reads a numeric string", Thermostat.nuheatToC("2150"), 21.5)
T.eq("normalize still snaps down", Thermostat.normalize(21.25), 21)
T.eq("normalize still snaps up", Thermostat.normalize(21.75), 21.5)
T.eq("stepSetpointC still steps", Thermostat.stepSetpointC({ setpointC = 20, minC = 5, maxC = 70 }, 1, "C"), 20.5)

T.finish()

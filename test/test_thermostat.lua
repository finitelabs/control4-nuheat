-- nuheat.thermostat's mapping between the device object and the thermostat
-- proxy: holds, HVAC mode, setpoints, and Manual operating mode, in which the
-- thermostat ignores its schedule and only the setpoint changes.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_thermostat.lua

local T = require("testlib")

require("c4_shim")
local Thermostat = require("nuheat.thermostat")

local function device(overrides)
  local d = { SerialNumber = "1", Temperature = 2378, SetPointTemp = 2333, ScheduleMode = 1, OperatingMode = 1 }
  for k, v in pairs(overrides or {}) do
    d[k] = v
  end
  return d
end

T.section("state from a device")
local s = Thermostat.fromDevice(device())
T.eq("temperature in C", s.temperatureC, 23.78)
T.eq("setpoint in C", s.setpointC, 23.33)
T.eq("Auto is no hold", Thermostat.holdMode(s), "Off")
T.eq("and Heat", Thermostat.hvacMode(s), "Heat")
T.eq("Until Next", Thermostat.holdMode(Thermostat.fromDevice(device({ ScheduleMode = 2 }))), "Until Next")
T.eq("Permanent", Thermostat.holdMode(Thermostat.fromDevice(device({ ScheduleMode = 3 }))), "Permanent")
local off = Thermostat.fromDevice(device({ ScheduleMode = 3, SetPointTemp = 500 }))
T.eq("a permanent hold at 5 C is Off", Thermostat.hvacMode(off), "Off")
T.eq("and not a Permanent hold", Thermostat.holdMode(off), "Off")
local manual = Thermostat.fromDevice(device({ OperatingMode = 2, ScheduleMode = 3 }))
T.truthy("Manual operating mode", manual.manual)
T.eq("has no hold, whatever ScheduleMode says", Thermostat.holdMode(manual), "Off")
T.eq("and offers only Heat", Thermostat.capabilities(manual).allowedHvacModes, "Heat")
T.eq("Auto offers Off and Heat", Thermostat.capabilities(s).allowedHvacModes, "Off,Heat")

T.section("a setpoint change")
local d = Thermostat.applySetpoint(device(), 25.2)
T.eq("snaps to 0.5 C in hundredths", d.SetPointTemp, 2500)
T.eq("holds until the next schedule event", d.ScheduleMode, Thermostat.MODE.UNTIL)
T.eq("with no end time", d.HoldSetPointDateTime, nil)
T.eq("keeps a permanent hold", Thermostat.applySetpoint(device({ ScheduleMode = 3 }), 25).ScheduleMode, 3)
local m = Thermostat.applySetpoint(device({ OperatingMode = 2, ScheduleMode = 1 }), 25)
T.eq("in Manual only the setpoint changes", m.ScheduleMode, 1)
T.eq("to the new value", m.SetPointTemp, 2500)

T.section("hold and HVAC mode")
T.eq("Off resumes the schedule", Thermostat.applyHold(device({ ScheduleMode = 2 }), "Off").ScheduleMode, 1)
T.eq("Permanent", Thermostat.applyHold(device(), "Permanent").ScheduleMode, 3)
T.eq("an unknown hold changes nothing", Thermostat.applyHold(device(), "Vacation").ScheduleMode, 1)
local o = Thermostat.applyHvacMode(device(), "Off")
T.eq("Off holds permanently", o.ScheduleMode, 3)
T.eq("at 5 C", o.SetPointTemp, Thermostat.OFF_SENTINEL)
T.eq("Heat resumes the schedule", Thermostat.applyHvacMode(o, "Heat").ScheduleMode, 1)

T.section("setpoint steps stay in range")
T.eq("up 1 F", Thermostat.round(Thermostat.cToF(Thermostat.stepSetpointC(s, 1, "F"))), 75)
T.eq("capped at 40 C", Thermostat.stepSetpointC(Thermostat.fromDevice(device({ SetPointTemp = 4000 })), 1, "C"), 40)
T.eq("floored at 5 C", Thermostat.stepSetpointC(Thermostat.fromDevice(device({ SetPointTemp = 500 })), -1, "C"), 5)

T.finish()

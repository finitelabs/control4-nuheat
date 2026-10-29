-- nuheat.thermostat's mapping between the v2 device object and the thermostat
-- proxy: holds, HVAC mode (Off is Standby, Manual at 5 C) and setpoints.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_thermostat.lua

local T = require("testlib")

require("c4_shim")
local Thermostat = require("nuheat.thermostat")

local MODE = Thermostat.MODE

local function device(overrides)
  local d = { SerialNumber = "1", Temperature = 2378, SetPointTemp = 2333, Mode = MODE.AUTO }
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
T.eq("Hold is Until Next", Thermostat.holdMode(Thermostat.fromDevice(device({ Mode = MODE.HOLD }))), "Until Next")
T.eq("Manual is Permanent", Thermostat.holdMode(Thermostat.fromDevice(device({ Mode = MODE.MANUAL }))), "Permanent")
local standby = Thermostat.fromDevice(device({ Mode = MODE.MANUAL, SetPointTemp = 500 }))
T.eq("Manual at 5 C is Standby, shown as Off", Thermostat.hvacMode(standby), "Off")
T.eq("and not a Permanent hold", Thermostat.holdMode(standby), "Off")
T.eq(
  "a hold at 5 C is not Standby",
  Thermostat.hvacMode(Thermostat.fromDevice(device({ Mode = MODE.HOLD, SetPointTemp = 500 }))),
  "Heat"
)
T.eq("Off and Heat are offered", Thermostat.capabilities(s).allowedHvacModes, "Off,Heat")

T.section("a setpoint change")
local d = Thermostat.applySetpoint(device(), 25.2)
T.eq("snaps to 0.5 C in hundredths", d.SetPointTemp, 2500)
T.eq("holds until the next schedule event", d.Mode, MODE.HOLD)
T.eq("with no end time", d.HoldUntil, nil)
T.eq("keeps a permanent hold", Thermostat.applySetpoint(device({ Mode = MODE.MANUAL }), 25).Mode, MODE.MANUAL)
T.eq(
  "from Standby it holds, turning heat back on",
  Thermostat.applySetpoint(device({ Mode = MODE.MANUAL, SetPointTemp = 500 }), 25).Mode,
  MODE.HOLD
)

T.section("hold and HVAC mode")
T.eq("Off resumes the schedule", Thermostat.applyHold(device({ Mode = MODE.HOLD }), "Off").Mode, MODE.AUTO)
T.eq("Until Next is Hold", Thermostat.applyHold(device(), "Until Next").Mode, MODE.HOLD)
T.eq("Permanent is Manual", Thermostat.applyHold(device(), "Permanent").Mode, MODE.MANUAL)
T.eq("an unknown hold changes nothing", Thermostat.applyHold(device(), "Vacation").Mode, MODE.AUTO)
local o = Thermostat.applyHvacMode(device(), "Off")
T.eq("Off is Manual", o.Mode, MODE.MANUAL)
T.eq("at 5 C", o.SetPointTemp, Thermostat.OFF_SENTINEL)
T.eq("Heat resumes the schedule", Thermostat.applyHvacMode(o, "Heat").Mode, MODE.AUTO)

T.section("setpoint steps stay in range")
T.eq("up 1 F", Thermostat.round(Thermostat.cToF(Thermostat.stepSetpointC(s, 1, "F"))), 75)
T.eq("capped at 40 C", Thermostat.stepSetpointC(Thermostat.fromDevice(device({ SetPointTemp = 4000 })), 1, "C"), 40)
T.eq("floored at 5 C", Thermostat.stepSetpointC(Thermostat.fromDevice(device({ SetPointTemp = 500 })), -1, "C"), 5)

T.section("displayName")
T.eq("the Nuheat name", Thermostat.displayName({ Room = "Kitchen", SerialNumber = 111 }), "Kitchen")
T.eq("the serial when unnamed", Thermostat.displayName({ Room = "", SerialNumber = 111 }), "Nuheat 111")
T.eq("the serial when missing", Thermostat.displayName({ SerialNumber = 111 }), "Nuheat 111")

T.finish()

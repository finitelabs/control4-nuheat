--- Nuheat thermostat state model + Control4 translation helpers.
---
--- Pure logic (no C4/HTTP side effects) so it is unit-testable: temperature
--- scaling between Nuheat's wire format and Celsius/Fahrenheit, mode ↔
--- HVAC/hold mapping, capability derivation from a device object, and building
--- the settings the account writes back. The device object is the one
--- nuheat.client builds from the OpenAPI's ThermostatModel.

require("lib.utils") -- tofinite

local M = {}

--- Nuheat wire temperatures are Celsius × 100 (hundredths of a degree C).
local NUHEAT_SCALE = 100
--- OpenAPI v2 thermostat mode: follow the schedule, hold until the next
--- schedule event (or a holdUntil within 24 hours), or Manual, which holds
--- indefinitely and is the API's permanent hold.
M.MODE = { AUTO = 1, HOLD = 2, MANUAL = 3 }
--- Standby (Off) is Manual at the 5.00 °C minimum (== 500), as Chemelex
--- documents it; the Nuheat app shows that as Standby.
M.OFF_SENTINEL = 500
--- Setpoint bounds. The OpenAPI reports none, so these are Nuheat's floor
--- range: 5–40 °C / 41–104 °F.
M.MIN_C, M.MAX_C = 5, 40

-- ─── Temperature conversion ────────────────────────────────────────────────

--- Converts a Nuheat wire value to Celsius.
--- @param n number Nuheat wire value (°C × 100)
--- @return number|nil celsius
function M.nuheatToC(n)
  local v = tofinite(n)
  if v == nil then
    return nil
  end
  return v / NUHEAT_SCALE
end

--- Converts Celsius to a Nuheat wire value.
--- @param c number Celsius
--- @return number nuheat Wire value (°C × 100, rounded)
function M.cToNuheat(c)
  return M.round(tonumber(c) * NUHEAT_SCALE)
end

--- Converts Celsius to Fahrenheit.
--- @param c number Celsius
--- @return number|nil fahrenheit
function M.cToF(c)
  local v = tofinite(c)
  if v == nil then
    return nil
  end
  return v * 9 / 5 + 32
end

--- Converts Fahrenheit to Celsius.
--- @param f number Fahrenheit
--- @return number|nil celsius
function M.fToC(f)
  local v = tofinite(f)
  if v == nil then
    return nil
  end
  return (v - 32) * 5 / 9
end

--- Round half-up to `idp` decimal places (default 0).
--- @param num number
--- @param idp? integer Decimal places (default 0).
--- @return number rounded
function M.round(num, idp)
  local mult = 10 ^ (idp or 0)
  return math.floor(tonumber(num) * mult + 0.5) / mult
end

--- Snap a temperature to the nearest 0.5° (the setpoint resolution).
--- @param temp number
--- @return number|nil normalized
function M.normalize(temp)
  local t = tofinite(temp)
  if t == nil then
    return nil
  end
  local r = t % 0.5
  if r > 0.25 then
    return t + (0.5 - r)
  end
  return t - r
end

-- ─── Device object → normalized state ──────────────────────────────────────

--- @class NuheatState
--- @field serialNumber string
--- @field online boolean
--- @field room string
--- @field temperatureC number|nil Current floor temperature, °C
--- @field setpointC number|nil Active setpoint, °C
--- @field heating boolean HVAC actively heating
--- @field mode integer|nil Nuheat v2 mode (1/2/3)
--- @field minC number
--- @field maxC number
--- @field isOff boolean Away/Off (permanent hold at minimum)

--- Normalize a device object.
--- @param v table
--- @return NuheatState state
function M.fromDevice(v)
  local mode = tonumber(v.Mode)
  local setpoint = tonumber(v.SetPointTemp)
  return {
    serialNumber = tostring(v.SerialNumber),
    online = v.Online == true,
    room = v.Room or "",
    temperatureC = M.nuheatToC(v.Temperature),
    setpointC = M.nuheatToC(setpoint),
    heating = v.Heating == true,
    mode = mode,
    minC = M.MIN_C,
    maxC = M.MAX_C,
    isOff = mode == M.MODE.MANUAL and setpoint == M.OFF_SENTINEL,
  }
end

-- ─── Capability derivation (for the thermostat proxy) ───────────────────────

--- Derive the Control4 thermostat-proxy capabilities from device state. Nuheat
--- is heat-only, so it uses the heat-setpoint model: HAS_SINGLE_SETPOINT false
--- and CAN_HEAT true, which the schedule editor and heat setpoint UI need, with
--- CAN_COOL and CAN_AUTO false.
--- @param state NuheatState
--- @return table capabilities
function M.capabilities(state)
  return {
    allowedHvacModes = "Off,Heat",
    hasSingleSetpoint = false,
    canHeat = true,
    canCool = false,
    canAuto = false,
    minSetpointC = state.minC,
    maxSetpointC = state.maxC,
  }
end

--- HVAC state string for the C4 proxy: "Heat" while heating, else "Off".
--- @param state NuheatState
--- @return string hvacState
function M.hvacState(state)
  return state.heating and "Heat" or "Off"
end

--- HVAC mode for the C4 proxy: "Off" when in Away/Off, otherwise "Heat".
--- @param state NuheatState
--- @return string hvacMode
function M.hvacMode(state)
  return state.isOff and "Off" or "Heat"
end

--- The C4 hold modes this driver advertises. "Until Next" is a temporary hold
--- until the next schedule event; "Permanent" holds indefinitely.
M.HOLD_MODES = "Off,Until Next,Permanent"

--- C4 hold mode from device state.
--- @param state NuheatState
--- @return string holdMode
function M.holdMode(state)
  if state.mode == M.MODE.HOLD then
    return "Until Next"
  elseif state.mode == M.MODE.MANUAL and not state.isOff then
    return "Permanent"
  end
  return "Off"
end

--- Nudge the heat setpoint by one resolution step in the given display scale
--- (0.5 °C / 1 °F, matching driver.xml), clamped to the device's bounds. Under
--- Fahrenheit the step is taken on the rounded °F value, so repeated presses
--- walk whole degrees instead of drifting on the °C round trip.
--- @param state NuheatState
--- @param delta integer +1 or -1
--- @param scale string "C" or "F"
--- @return number|nil celsius Nil when the device has reported no setpoint to step from.
function M.stepSetpointC(state, delta, scale)
  local current = tofinite(state.setpointC)
  if current == nil then
    return nil
  end
  local celsius
  if scale == "C" then
    celsius = current + delta * 0.5
  else
    celsius = M.fToC(M.round(M.cToF(current)) + delta)
  end
  return math.max(state.minC, math.min(state.maxC, celsius))
end

-- ─── Settings builders (Control4 → the account's write) ─────────────────────

--- The device's current schedule mode.
--- @param settings table
--- @return integer|nil mode
function M.currentMode(settings)
  return tonumber(settings.Mode)
end

--- Set the heat setpoint (°C). Holds it until the next schedule event, unless
--- the thermostat already holds permanently (Manual), which keeps holding at the
--- new temperature. A setpoint from Standby is a hold, which turns heating back on.
--- @param settings table Current device object (mutated + returned).
--- @param celsius number
--- @return table settings
function M.applySetpoint(settings, celsius)
  local permanent = M.currentMode(settings) == M.MODE.MANUAL and tonumber(settings.SetPointTemp) ~= M.OFF_SENTINEL
  settings.SetPointTemp = M.cToNuheat(M.normalize(celsius))
  settings.HoldUntil = nil
  settings.Mode = permanent and M.MODE.MANUAL or M.MODE.HOLD
  return settings
end

--- C4 hold-mode string -> schedule mode. "Off" resumes the schedule (Auto).
M.HOLD_TO_MODE = {
  ["Off"] = M.MODE.AUTO,
  ["Until Next"] = M.MODE.HOLD,
  ["Permanent"] = M.MODE.MANUAL,
}

--- Apply a C4 hold-mode change, holding the current setpoint.
--- @param settings table
--- @param c4HoldMode string
--- @return table settings
function M.applyHold(settings, c4HoldMode)
  local mode = M.HOLD_TO_MODE[c4HoldMode]
  if mode then
    settings.Mode = mode
    settings.HoldUntil = nil
  end
  return settings
end

--- Set HVAC mode. "Heat" resumes the schedule (Auto); "Off" is Standby, Manual
--- at the minimum.
--- @param settings table
--- @param mode string "Heat" | "Off"
--- @return table settings
function M.applyHvacMode(settings, mode)
  settings.HoldUntil = nil
  if mode == "Off" then
    settings.SetPointTemp = M.OFF_SENTINEL
    settings.Mode = M.MODE.MANUAL
  else
    settings.Mode = M.MODE.AUTO
  end
  return settings
end

return M

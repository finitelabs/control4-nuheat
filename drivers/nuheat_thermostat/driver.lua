-- Nuheat thermostat companion driver.
--
-- Presents one Nuheat Signature or Conductor floor-heating thermostat as a C4
-- thermostatV2 proxy. It owns no cloud session: the account driver polls the
-- Nuheat OpenAPI and hands the device object down over the account binding
-- (RFP.updateThermostat / RFP.goOffline); writes go back up as SET_THERMOSTAT
-- commands for the account to send.
--
-- Writes are optimistic: proxy commands mutate the handed-over object, push the
-- new state to the proxy immediately, and arm a confirm/retry loop that re-sends
-- until the cloud reflects the change or a timeout accepts reality.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "nuheat_thermostat.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local Thermostat = require("nuheat.thermostat")
local displayScale = require("nuheat.display_scale")
local constants = require("constants")

--- thermostatV2 proxy (this driver's primary proxy).
local PROXY_BINDING = 5001
--- Consumer connection bound up to the Nuheat account driver.
local ACCOUNT_BINDING = 5002
--- Temperature value output connection.
local TEMP_OUTPUT_BINDING = 5010

--- Set true at the end of OnDriverLateInit, after the boot-time property replay;
--- OPC.Driver_Status re-pins "Initializing" until then.
local gInitialized = false
--- Device object handed over by the account (mutated in place to build the
--- settings sent back). `nil` until the first handoff.
local gDevice = nil
--- Normalized state derived from gDevice (see nuheat.thermostat).
local gState = nil
--- The display scale ("C"/"F") we last reported to the proxy, resolved from
--- Director in OnDriverLateInit and re-resolved whenever it changes.
local gReportedScale = nil

--- Pending optimistic write. The OJ Electronics cloud behind Nuheat (shared with
--- Schluter, where this was measured) is slow to reflect changes, especially
--- leaving a hold, and occasionally drops a write. After a mode change the
--- intended schedule mode is remembered so that (1) handoffs still showing the
--- old mode don't snap the UI back, and (2) a retry loop re-sends until the cloud
--- confirms or the timeout accepts reality.
--- @type { mode: integer, setpoint: number|nil, ts: integer }|nil
local gPending = nil
--- Stop trusting the optimistic state after this long (cloud won: accept reality).
local CONFIRM_TIMEOUT_S = 60
--- Re-send an unconfirmed write on this cadence to survive dropped writes.
local RETRY_INTERVAL_S = 12

-- ─── Push state / capabilities to the thermostat proxy ─────────────────────

--- Advertise the capabilities of the handed device (heat-only, the heat-setpoint
--- model, per-device bounds). Only what the device supports is advertised. Sent
--- on every handoff without a change check: the thermostatV2 proxy takes repeats
--- without effect, and a reinitialized proxy needs them again.
local function pushCapabilities()
  if not gState then
    return
  end
  local caps = Thermostat.capabilities(gState)
  SendToProxy(PROXY_BINDING, "ALLOWED_HVAC_MODES_CHANGED", { MODES = caps.allowedHvacModes }, "NOTIFY")
  -- Populate the hold-modes list; without this the proxy only accepts "Off" and
  -- silently drops "Until Next"/"Permanent" (the static hold_modes cap alone
  -- leaves HOLD_MODES_LIST empty).
  SendToProxy(PROXY_BINDING, "ALLOWED_HOLD_MODES_CHANGED", { MODES = Thermostat.HOLD_MODES }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    HAS_SINGLE_SETPOINT = caps.hasSingleSetpoint,
    CAN_HEAT = caps.canHeat,
    CAN_COOL = caps.canCool,
    CAN_AUTO = caps.canAuto,
  }, "NOTIFY")
  -- Heat setpoint bounds (heat-setpoint model). Static bounds also come from
  -- driver.xml; send the device's actual range so it tracks the thermostat.
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    SETPOINT_HEAT_MIN_C = caps.minSetpointC,
    SETPOINT_HEAT_MAX_C = caps.maxSetpointC,
    SETPOINT_HEAT_MIN_F = Thermostat.round(Thermostat.cToF(caps.minSetpointC)),
    SETPOINT_HEAT_MAX_F = Thermostat.round(Thermostat.cToF(caps.maxSetpointC)),
  }, "NOTIFY")
end

--- Push current temperature / setpoint / mode / state to the proxy (values in
--- Celsius; the proxy converts for the user's display scale). Sent on every
--- handoff without a change check, for the same reason as pushCapabilities.
local function pushState()
  if not gState then
    return
  end
  C4:UpdateProperty("Driver Status", gState.online and "Online" or "Offline")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = gState.online }, "NOTIFY")
  -- Withheld rather than pushed as "nil", so the proxy keeps the last reading.
  if gState.temperatureC ~= nil then
    SendToProxy(PROXY_BINDING, "TEMPERATURE_CHANGED", {
      TEMPERATURE = tostring(gState.temperatureC),
      SCALE = "C",
    }, "NOTIFY")
  else
    log:warn("Handoff carried no usable temperature; keeping the last one reported")
  end
  if gState.setpointC ~= nil then
    SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
      SETPOINT = tostring(gState.setpointC),
      SCALE = "C",
    }, "NOTIFY")
  else
    log:warn("Handoff carried no usable setpoint; keeping the last one reported")
  end
  SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = Thermostat.hvacMode(gState) }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HVAC_STATE_CHANGED", { STATE = Thermostat.hvacState(gState) }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HOLD_MODE_CHANGED", { MODE = Thermostat.holdMode(gState) }, "NOTIFY")
  if gState.temperatureC ~= nil then
    SendToProxy(TEMP_OUTPUT_BINDING, "VALUE_CHANGED", SensorValueParams(gState.temperatureC, "CELSIUS"))
  end
end

--- Send the mutated Nuheat settings object back to the account to write.
local function pushToAccount()
  if gDevice then
    SendToProxy(ACCOUNT_BINDING, constants.CMD.SET_THERMOSTAT, { JSON = JSON:encode(gDevice) })
  end
end

--- Re-send the intended settings on a timer until the cloud confirms the pending
--- mode change (handled in updateThermostat) or we time out. This is what makes a
--- change actually stick when Nuheat drops or is slow to apply the first write.
local function scheduleConfirm()
  SetTimer("NuheatConfirm", RETRY_INTERVAL_S * ONE_SECOND, function()
    if not gPending then
      return
    end
    if (os.time() - gPending.ts) >= CONFIRM_TIMEOUT_S then
      gPending = nil
      return
    end
    pushToAccount()
    scheduleConfirm()
  end)
end

--- Mark the schedule mode just written as pending and arm the confirm/retry
--- loop. Called right after a command is sent, so the optimistic state survives
--- stale handoffs and dropped writes.
local function markPending()
  if not gDevice then
    return
  end
  local mode = Thermostat.currentMode(gDevice)
  gPending = {
    mode = mode,
    -- Auto follows the schedule's setpoint, not the one written, so only a hold's
    -- setpoint has to read back too.
    setpoint = mode ~= Thermostat.MODE.AUTO and tonumber(gDevice.SetPointTemp) or nil,
    ts = os.time(),
  }
  scheduleConfirm()
end

--- Adopt a display scale. The proxy defaults to Fahrenheit and never consults
--- the project setting, so it has to be told. SCALE_CHANGED rewrites the proxy
--- variable the watcher listens on, so the unchanged-scale return is what keeps
--- a report from feeding itself back in a loop.
--- @param scale string "C" or "F"
local function applyDisplayScale(scale)
  if scale == gReportedScale then
    return
  end
  gReportedScale = scale
  log:debug("Setting thermostat display scale to %s", scale)
  SendToProxy(PROXY_BINDING, "SCALE_CHANGED", { SCALE = scale }, "NOTIFY")
end

-- ─── Proxy command handlers (thermostatV2 → Nuheat) ────────────────────────

local function applyAndSend(idBinding, mutate)
  if idBinding ~= PROXY_BINDING or not gDevice then
    return
  end
  mutate()
  -- Reflect the change on the proxy immediately (optimistic). Nuheat can take
  -- tens of seconds to apply a change and there may be no handoff until it does,
  -- so without this the UI would sit on the old state (and look like it "didn't
  -- stick"). markPending + the confirm loop keep it from reverting and re-send.
  gState = Thermostat.fromDevice(gDevice)
  pushToAccount()
  markPending()
  pushState()
end

--- The setpoint a proxy command carries, in °C. In a Fahrenheit project the
--- proxy rounds CELSIUS to a whole degree (76 °F arrives as CELSIUS 25), so the
--- value in the scale it displays is the exact one.
--- @param tParams table
--- @return number|nil
local function setpointCelsius(tParams)
  if gReportedScale == "F" then
    local fahrenheit = tofinite(tonumber_expect_period(Select(tParams, "FAHRENHEIT")))
    if fahrenheit ~= nil then
      return Thermostat.fToC(fahrenheit)
    end
  end
  return CelsiusFromParams(tParams)
end

--- @param idBinding integer
--- @param tParams table
local function handleSetpoint(idBinding, tParams)
  local celsius = setpointCelsius(tParams)
  if celsius == nil then
    return
  end
  applyAndSend(idBinding, function()
    Thermostat.applySetpoint(gDevice, celsius)
  end)
end

function RFP.SET_SETPOINT_HEAT(idBinding, _strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_HEAT(%s)", idBinding)
  handleSetpoint(idBinding, tParams)
end

--- Nudge the heat setpoint by one resolution step in the project's display scale
--- (0.5 °C / 1 °F, matching driver.xml), clamped to the device's bounds.
--- @param idBinding integer
--- @param delta integer +1 or -1
local function adjustSetpoint(idBinding, delta)
  if not gState then
    return
  end
  local celsius = Thermostat.stepSetpointC(gState, delta, gReportedScale)
  if celsius == nil then
    log:warn("Ignoring a setpoint step: the device has reported no setpoint to step from")
    return
  end
  applyAndSend(idBinding, function()
    Thermostat.applySetpoint(gDevice, celsius)
  end)
end

function RFP.INC_SETPOINT_HEAT(idBinding)
  log:trace("RFP.INC_SETPOINT_HEAT(%s)", idBinding)
  adjustSetpoint(idBinding, 1)
end

function RFP.DEC_SETPOINT_HEAT(idBinding)
  log:trace("RFP.DEC_SETPOINT_HEAT(%s)", idBinding)
  adjustSetpoint(idBinding, -1)
end

--- Set Heat or Off (Standby).
--- @param idBinding integer
--- @param mode string
local function setHvacMode(idBinding, mode)
  if mode ~= "Off" and mode ~= "Heat" then
    log:warn("Ignoring an HVAC mode this thermostat does not have: %s", tostring(mode))
    return
  end
  applyAndSend(idBinding, function()
    Thermostat.applyHvacMode(gDevice, mode)
  end)
end

function RFP.SET_MODE_HEAT(idBinding)
  log:trace("RFP.SET_MODE_HEAT(%s)", idBinding)
  setHvacMode(idBinding, "Heat")
end

function RFP.SET_MODE_OFF(idBinding)
  log:trace("RFP.SET_MODE_OFF(%s)", idBinding)
  setHvacMode(idBinding, "Off")
end

--- The thermostatV2 proxy forwards an HVAC mode change as SET_MODE_HVAC with
--- MODE (measured on a 4.3 controller), not as SET_MODE_OFF / SET_MODE_HEAT.
function RFP.SET_MODE_HVAC(idBinding, _strCommand, tParams)
  local mode = (tParams or {}).MODE
  log:trace("RFP.SET_MODE_HVAC(%s)", tostring(mode))
  setHvacMode(idBinding, mode)
end

function RFP.SET_MODE_HOLD(idBinding, _strCommand, tParams)
  log:trace("RFP.SET_MODE_HOLD(%s)", tostring((tParams or {}).MODE))
  applyAndSend(idBinding, function()
    Thermostat.applyHold(gDevice, (tParams or {}).MODE)
  end)
end

--- The Navigator-initiated scale change. Director also writes the proxy's SCALE
--- variable, which the watcher picks up, but this command carries the chosen
--- scale directly and may arrive before the variable is written.
function RFP.SET_SCALE(idBinding, _strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local scale = TemperatureScaleLetter((tParams or {}).SCALE)
  if scale == nil then
    log:warn("Ignoring SET_SCALE with unrecognized scale: %s", tostring((tParams or {}).SCALE))
    return
  end
  log:trace("RFP.SET_SCALE(%s)", scale)
  applyDisplayScale(scale)
end

-- ─── Account linking in the app (thermostatV2 extras) ──────────────────────

--- The thermostat screen's banner while the account is not linked.
local NOT_LINKED_MESSAGE = "Sign in to Nuheat from Extras"
--- The banner last sent, nil before the first.
--- @type string|nil
local gMessage = nil

--- The objects in the Nuheat Account extras section, in display order, with the
--- attributes only the setup carries.
local EXTRAS_OBJECTS = {
  { id = "NuheatAccountStatus", static = 'type="text" label="Nuheat Account"' },
  {
    id = "LinkNuheatAccount",
    static = 'type="button" label="Link Nuheat Account" buttontext="Get Link" command="LinkNuheatAccount"',
  },
  { id = "NuheatAuthLink", static = 'type="text" label="Open this link to sign in"' },
}

--- Each object's value and visibility for a link state: the account status
--- always, Get Link while unlinked, and the link while one waits to be opened.
--- @param auth table { linked: boolean, status: string, link: string }
--- @return table<string, { value: string|nil, hidden: boolean }>
local function extrasState(auth)
  local linked = auth.linked == true
  local link = auth.link or ""
  return {
    NuheatAccountStatus = { value = auth.status or "", hidden = false },
    -- Hidden while a link waits. The link and the state behind it expire together,
    -- and the account then clears the link, so the button comes back with it.
    LinkNuheatAccount = { hidden = linked or link ~= "" },
    NuheatAuthLink = { value = link, hidden = linked or link == "" },
  }
end

--- The section's objects as XML, with the setup-only attributes when asked.
--- @param auth table
--- @param withStatic boolean
--- @return string
local function extrasObjectsXml(auth, withStatic)
  local state = extrasState(auth)
  local objects = {}
  for _, object in ipairs(EXTRAS_OBJECTS) do
    local attrs = {}
    if withStatic then
      attrs[#attrs + 1] = object.static
    end
    attrs[#attrs + 1] = 'id="' .. object.id .. '"'
    local entry = state[object.id]
    if entry.value ~= nil then
      attrs[#attrs + 1] = 'value="' .. XMLEncode(entry.value) .. '"'
    end
    attrs[#attrs + 1] = 'hidden="' .. (entry.hidden and "True" or "False") .. '"'
    objects[#objects + 1] = "<object " .. table.concat(attrs, " ") .. "/>"
  end
  return table.concat(objects)
end

--- Describe the extras section to the proxy, in its current state.
--- @param auth table
local function pushExtrasSetup(auth)
  SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", {
    XML = '<extras_setup><extra><section label="Nuheat Account">'
      .. extrasObjectsXml(auth, true)
      .. "</section></extra></extras_setup>",
  }, "NOTIFY")
end

--- The account's link state for the extras.
function RFP.authStatus(idBinding, _strCommand, tParams)
  log:trace("RFP.authStatus(%s)", idBinding)
  tParams = tParams or {}
  local auth = { linked = toboolean(tParams.LINKED), status = tParams.STATUS or "", link = tParams.LINK or "" }
  SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", {
    XML = "<extras_state><extra>" .. extrasObjectsXml(auth, false) .. "</extra></extras_state>",
  }, "NOTIFY")
  local message = auth.linked and "" or NOT_LINKED_MESSAGE
  if message ~= gMessage then
    gMessage = message
    SendToProxy(PROXY_BINDING, "MESSAGE_CHANGED", { MESSAGE = message }, "NOTIFY")
  end
end

--- Get Link pressed in the app: the account owns the sign-in.
function RFP.LinkNuheatAccount(idBinding)
  log:trace("RFP.LinkNuheatAccount(%s)", idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  SendToProxy(ACCOUNT_BINDING, constants.CMD.LINK_ACCOUNT, {})
end

-- ─── Account handoff handlers (account → this companion) ────────────────────

--- With Auto Rename Driver on, name this driver after its thermostat in the
--- Nuheat app. Only while the account is handing it over, so a companion the
--- account marked as removed keeps that name.
local function applyThermostatName()
  local name = Properties["Thermostat Name"]
  if not gDevice or Properties["Auto Rename Driver"] ~= "On" or IsEmpty(name) then
    return
  end
  local proxyId = tonumber((tostring(C4:GetProxyDevicesById(C4:GetDeviceID()) or "")):match("^(%d+)"))
  RenameDevice(proxyId or C4:GetDeviceID(), name)
end

--- The account hands over the current Nuheat thermostat object.
function RFP.updateThermostat(idBinding, _strCommand, tParams)
  log:trace("RFP.updateThermostat(%s)", idBinding)
  local ok, device = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
  if not ok or type(device) ~= "table" then
    return
  end
  if gPending and (os.time() - gPending.ts) < CONFIRM_TIMEOUT_S then
    local confirmed = Thermostat.currentMode(device) == gPending.mode
      and (gPending.setpoint == nil or tonumber(device.SetPointTemp) == gPending.setpoint)
    if confirmed then
      -- Cloud caught up to our write; trust reality from here on.
      gPending = nil
      gDevice = device
    elseif gDevice then
      -- Stale handoff (cloud hasn't applied the write yet, or dropped it). Keep
      -- our intended state so the UI doesn't snap back; only refresh the live
      -- sensor fields. The confirm loop keeps re-sending until it takes.
      gDevice.Temperature = device.Temperature
      gDevice.Heating = device.Heating
      gDevice.Online = device.Online
    else
      gDevice = device
    end
  else
    gPending = nil
    gDevice = device
  end
  gState = Thermostat.fromDevice(gDevice)
  C4:UpdateProperty("Serial ID", gState.serialNumber)
  C4:UpdateProperty("Thermostat Name", Thermostat.displayName(gDevice))
  applyThermostatName()
  pushCapabilities()
  pushState()
end

--- The thermostat is gone / account logged out.
function RFP.goOffline(idBinding, _strCommand)
  log:trace("RFP.goOffline(%s)", idBinding)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  C4:UpdateProperty("Serial ID", "")
  C4:UpdateProperty("Thermostat Name", "")
  C4:UpdateProperty("Driver Status", "Offline")
  gDevice, gState, gPending = nil, nil, nil
end

-- ─── Property + lifecycle ──────────────────────────────────────────────────

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
  local ultra = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL, DEBUG_WEBSOCKET = ultra, ultra, ultra, ultra, ultra
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Auto_Rename_Driver(_v)
  applyThermostatName()
end

function OPC.Driver_Version()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for p, _ in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok then
      log:error("OnPropertyChanged('%s') failed: %s", p, tostring(err))
    end
  end
  gInitialized = true
  applyDisplayScale(displayScale.resolve(PROXY_BINDING))
  -- A Navigator scale change reaches the proxy's variable even when SET_SCALE
  -- does not reach the driver.
  displayScale.watch(PROXY_BINDING, function()
    applyDisplayScale(displayScale.resolve(PROXY_BINDING))
  end)
  -- Settle Driver Status now that init is done; the replay above left it at
  -- "Initializing" via the OPC.Driver_Status guard.
  C4:UpdateProperty("Driver Status", "Waiting for thermostat")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  -- The account sends the real state when this binds and on every change.
  pushExtrasSetup({ linked = false, status = "Waiting for the Nuheat account driver", link = "" })
end

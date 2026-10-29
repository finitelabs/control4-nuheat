-- Nuheat account coordinator.
--
-- Owns the account's sign-in to the Nuheat OpenAPI (OAuth2 through Control4's
-- redirect service), polls the account's thermostats, and exposes a dynamic
-- PROXY binding per thermostat that the nuheat_thermostat companion drivers bind
-- to. Companions receive the device object over the binding (UPDATE_THERMOSTAT)
-- and push mutated settings back (setThermostat), which this driver writes.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "nuheat.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-nuheat"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local updateSettings = require("lib.update-settings")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

local Client = require("nuheat.client")
local Thermostat = require("nuheat.thermostat")
local constants = require("constants")

local NS = constants.BINDING_NAMESPACE
local CMD = constants.CMD

--- Poll interval when the property holds nothing usable.
local DEFAULT_POLL_S = 60
--- After a write, read back once the cloud has had time to apply it.
local WRITE_READBACK_S = 5

--- Runtime state (not persisted; rebuilt from the cloud).
local gState = {
  --- @type table<string, table> serial number -> latest device object
  devices = {},
}

--- Set true once OnDriverLateInit finishes; guards the property handlers from
--- firing while Composer replays the initial property values.
local gInitialized = false

--- Monotonic ids for thermostat refreshes, so a slow response that started before
--- a newer one (or before a write) can't overwrite the newer state.
local gRefreshIssued = 0
local gRefreshAccepted = 0

--- os.time() before which no poll is sent, set from a 429's Retry-After.
local gRateLimitedUntil = 0

local client

--- All nuheat account instances on this controller, sorted by device id. Used
--- for leader election (lowest id is the leader that runs updates).
--- @return integer[]
local function getAccountDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id in pairs(drivers) do
    ids[#ids + 1] = tonumber(id)
  end
  table.sort(ids)
  return ids
end

-- ─── Companion handoff ─────────────────────────────────────────────────────

--- Push a thermostat's current object to its bound companion (if any).
--- @param serial string
local function handoff(serial)
  local device = gState.devices[serial]
  local binding = bindings:getDynamicBinding(NS, serial)
  if not device or not binding then
    return
  end
  SendToProxy(binding.bindingId, CMD.UPDATE_THERMOSTAT, { JSON = JSON:encode(device) })
end

--- Link state as the companions show it in the app's extras.
local gAuth = { linked = false, status = "Not linked", link = "" }

--- Send the link state to one binding's companion, or to every thermostat binding.
--- @param bindingId integer|nil
local function pushAuth(bindingId)
  local params = { LINKED = tostring(gAuth.linked), STATUS = gAuth.status, LINK = gAuth.link }
  if bindingId then
    SendToProxy(bindingId, CMD.AUTH_STATUS, params)
    return
  end
  for _, binding in pairs(bindings:getDynamicBindings(NS)) do
    SendToProxy(binding.bindingId, CMD.AUTH_STATUS, params)
  end
end

--- Tell a thermostat's companion it is gone.
--- @param serial string
local function goOffline(serial)
  local binding = bindings:getDynamicBinding(NS, serial)
  if binding then
    SendToProxy(binding.bindingId, CMD.GO_OFFLINE, {})
  end
end

--- Resolve the serial number behind a dynamic binding id.
--- @param idBinding integer
--- @return string|nil serial
local function serialForBinding(idBinding)
  for serial, binding in pairs(bindings:getDynamicBindings(NS)) do
    if binding.bindingId == idBinding then
      return serial
    end
  end
  return nil
end

-- ─── Thermostat discovery ──────────────────────────────────────────────────

--- Store a device, ensure its provider binding exists, register a bind handler
--- that hands the device off when a companion connects, and push the current
--- state to any companion already bound.
--- @param device table
local function ingestThermostat(device)
  local serial = tostring(device.SerialNumber)
  if serial == "nil" or serial == "" then
    return
  end
  gState.devices[serial] = device
  local binding = bindings:getOrAddDynamicBinding(
    NS,
    serial,
    "PROXY",
    true,
    Thermostat.displayName(device),
    constants.THERMOSTAT_CLASS
  )
  if binding then
    OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound)
      if bIsBound then
        handoff(serial)
        pushAuth(binding.bindingId)
      end
    end
    -- With every handoff, so a companion that re-initialized shows the real state.
    pushAuth(binding.bindingId)
  end
  handoff(serial)
end

local function connectedStatus(count)
  return string.format("Connected (%d thermostat%s)", count, count == 1 and "" or "s")
end

--- Set once a refresh has listed the account's thermostats, so Add Thermostats
--- can tell a thermostat that left the account from one not read yet.
local gListed = false

-- ─── Companion drivers ─────────────────────────────────────────────────────

local COMPANION_DRIVER = "nuheat_thermostat.c4z"
--- The companion's consumer binding for this driver's thermostat bindings.
local COMPANION_BINDING = 5002
--- Pause between companions, so each initializes before the next is added.
local ADD_SPACING_S = 5
local REMOVED_SUFFIX = " - REMOVED FROM NUHEAT"

local gAdding = false

--- @param bindingId integer
--- @return boolean
local function hasCompanion(bindingId)
  return next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), bindingId) or {}) ~= nil
end

--- Companion drivers in the project that no account is connected to.
--- @return integer[]
local function spareCompanions()
  local ids = {}
  for key in pairs(C4:GetDevicesByC4iName(COMPANION_DRIVER) or {}) do
    local id = tonumber(key)
    if id and C4:GetBoundProviderDevice(id, COMPANION_BINDING) == 0 then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

--- The project's rooms as { [roomId] = name }.
--- @return table<integer, string>
local function projectRooms()
  local rooms = {}
  for id, name in pairs(C4:GetDevicesByC4iName("roomdevice.c4i") or {}) do
    if tonumber(id) then
      rooms[tonumber(id)] = tostring(name)
    end
  end
  return rooms
end

--- The room a thermostat's companion goes in: the room whose name the Nuheat
--- name matches or contains (the longest such name), else this driver's room.
--- @param thermostatName string
--- @param rooms table<integer, string>
--- @return integer
local function roomFor(thermostatName, rooms)
  local wanted = string.lower(thermostatName or "")
  local bestId, bestLength = nil, 0
  for id, name in pairs(rooms) do
    local lowered = string.lower(name)
    if lowered ~= "" and #lowered > bestLength and wanted:find(lowered, 1, true) then
      bestId, bestLength = id, #lowered
    end
  end
  return bestId or C4:RoomGetId()
end

--- Show a proxy in the Navigators of one room and hide it in every other.
--- @param proxyId integer
--- @param roomId integer
--- @param rooms table<integer, string>
local function showOnlyInRoom(proxyId, roomId, rooms)
  for id in pairs(rooms) do
    SendToDevice(id, "SET_DEVICE_HIDDEN_STATE", {
      PROXY_GROUP = "ALL",
      DEVICE_ID = proxyId,
      IS_HIDDEN = id ~= roomId,
    })
  end
end

--- @param deviceId integer
--- @return integer|nil
local function proxyOf(deviceId)
  return tonumber((tostring(C4:GetProxyDevicesById(deviceId) or "")):match("^(%d+)"))
end

--- Rename the companions of thermostats that are no longer on the account, so
--- the integrator can find and remove them, and restore the name of one whose
--- thermostat is back.
local function markRemovedCompanions()
  for serial, binding in pairs(bindings:getDynamicBindings(NS)) do
    local device = gState.devices[serial]
    for deviceId in pairs(C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding.bindingId) or {}) do
      local proxyId = proxyOf(tonumber(deviceId))
      local name = proxyId and C4:GetDeviceDisplayName(proxyId)
      local marked = name and name:find(REMOVED_SUFFIX, 1, true) ~= nil
      if name and not device and not marked then
        log:info("Thermostat %s left the account; renaming %s", serial, name)
        C4:RenameDevice(proxyId, name .. REMOVED_SUFFIX)
      elseif name and device and marked then
        log:info("Thermostat %s is back on the account; renaming %s", serial, name)
        C4:RenameDevice(proxyId, (name:gsub(REMOVED_SUFFIX:gsub("%p", "%%%0"), "")))
      end
    end
  end
end

--- Give every thermostat on the account a companion driver: an unconnected one
--- already in the project when there is one, else a new one in the matching
--- room, shown only in that room. One at a time, ADD_SPACING_S apart.
local function addThermostats()
  if gAdding then
    log:info("Add Thermostats is already running")
    return
  end
  if not client:isAuthenticated() or not gListed then
    C4:UpdateProperty("Driver Status", "Link the account before adding thermostats")
    return
  end
  markRemovedCompanions()
  local rooms = projectRooms()
  local pending = {}
  for serial, device in pairs(gState.devices) do
    local binding = bindings:getDynamicBinding(NS, serial)
    if binding and not hasCompanion(binding.bindingId) then
      local name = Thermostat.displayName(device)
      pending[#pending + 1] = { bindingId = binding.bindingId, name = name, roomId = roomFor(name, rooms) }
    end
  end
  table.sort(pending, function(a, b)
    return a.name < b.name
  end)
  local total = #pending
  if total == 0 then
    C4:UpdateProperty("Driver Status", "Every thermostat already has a driver")
    return
  end
  local spares = spareCompanions()
  gAdding = true

  local function nextThermostat()
    local item = table.remove(pending, 1)
    if not item then
      gAdding = false
      log:info("Add Thermostats finished; refreshing Navigators")
      RefreshNavs()
      C4:UpdateProperty("Driver Status", connectedStatus(TableLength(gState.devices)))
      return
    end
    C4:UpdateProperty("Driver Status", string.format("Adding thermostat %d of %d...", total - #pending, total))
    local function connect(deviceId, isNew)
      Bind(C4:GetDeviceID(), item.bindingId, deviceId, COMPANION_BINDING, constants.THERMOSTAT_CLASS)
      local proxyId = proxyOf(deviceId)
      if proxyId then
        C4:RenameDevice(proxyId, item.name)
        if isNew then
          showOnlyInRoom(proxyId, item.roomId, rooms)
        end
      end
      SetTimer("NuheatAddThermostats", ADD_SPACING_S * ONE_SECOND, nextThermostat)
    end
    local spare = table.remove(spares, 1)
    if spare then
      log:info("Connecting %s to the existing companion %s", item.name, spare)
      connect(spare, false)
      return
    end
    log:info("Adding a companion for %s in room %s", item.name, item.roomId)
    C4:AddDevice(COMPANION_DRIVER, item.roomId, item.name, function(deviceId)
      deviceId = tonumber(deviceId)
      if not deviceId or deviceId == 0 then
        log:error("Control4 could not add %s for %s", COMPANION_DRIVER, item.name)
        SetTimer("NuheatAddThermostats", ONE_SECOND, nextThermostat)
        return
      end
      connect(deviceId, true)
    end)
  end
  nextThermostat()
end

--- Read every thermostat on the account. Responses are accepted in issue order
--- only, and a thermostat the account no longer lists is taken offline.
--- @return Deferred|nil refresh Settles when the read does; nil when none was sent.
local function refreshThermostats()
  if not client:isAuthenticated() then
    return nil
  end
  if os.time() < gRateLimitedUntil then
    log:debug("Skipping a refresh: rate limited for %ds more", gRateLimitedUntil - os.time())
    return nil
  end
  gRefreshIssued = gRefreshIssued + 1
  local refreshId = gRefreshIssued
  return client:getThermostats():next(function(devices)
    if refreshId < gRefreshAccepted then
      log:trace("Discarding stale thermostat refresh %d (accepted %d)", refreshId, gRefreshAccepted)
      return
    end
    gRefreshAccepted = refreshId
    gListed = true
    local listed = {}
    for _, device in ipairs(devices) do
      listed[tostring(device.SerialNumber)] = true
      ingestThermostat(device)
    end
    for serial in pairs(gState.devices) do
      if not listed[serial] then
        log:info("Thermostat %s is no longer on the account", serial)
        gState.devices[serial] = nil
        goOffline(serial)
      end
    end
    C4:UpdateProperty("Driver Status", connectedStatus(#devices))
  end, function(err)
    if refreshId < gRefreshAccepted or not client:isAuthenticated() then
      return
    end
    log:warn("Refreshing thermostats failed: %s", err.message)
    if err.retryAfter then
      gRateLimitedUntil = os.time() + err.retryAfter
      C4:UpdateProperty("Driver Status", string.format("Rate limited by Nuheat; retrying in %ds", err.retryAfter))
    else
      C4:UpdateProperty("Driver Status", "Error retrieving thermostats: " .. tostring(err.message))
    end
  end)
end

--- Whether a scheduled poll is still waiting on Nuheat.
local gPollInFlight = false

--- A scheduled poll, skipped while the last one is outstanding so a slow cloud
--- does not collect requests. Write read-backs and Refresh Thermostats are not
--- held back by this.
local function pollTick()
  if gPollInFlight then
    log:debug("Skipping a poll: the last one has not finished")
    return
  end
  local refresh = refreshThermostats()
  if refresh == nil then
    return
  end
  gPollInFlight = true
  local function done()
    gPollInFlight = false
  end
  refresh:next(done, done)
end

--- The poll interval in seconds, from the Poll Interval property.
--- @return integer
local function pollIntervalS()
  return tonumber((Properties["Poll Interval"] or ""):match("^(%d+)")) or DEFAULT_POLL_S
end

local function startPolling()
  SetTimer("NuheatPoll", pollIntervalS() * ONE_SECOND, pollTick, true)
end

local function stopPolling()
  CancelTimer("NuheatPoll")
end

-- ─── Sign-in ───────────────────────────────────────────────────────────────

--- driver.xml event ids.
local EVENT = { ACCOUNT_LINKED = 1, ACCOUNT_NOT_LINKED = 2 }

--- Tests whether the account is linked to Nuheat.
--- @param strConditionName string
--- @param tParams table VALUE ("Linked" or "Not Linked") and LOGIC.
--- @return boolean result
function TC.ACCOUNT_LINKED(strConditionName, tParams)
  log:trace("TC.ACCOUNT_LINKED(%s, %s)", strConditionName, tParams)
  local test = Select(tParams, "VALUE") == "Linked"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= gAuth.linked
  end
  return test == gAuth.linked
end

--- Whether the account was linked at the last change: nil until the first
--- change after start-up, false when start-up found no stored sign-in.
--- @type boolean|nil
local gWasLinked = nil

--- @param authenticated boolean
--- @param reason string|nil
local function onAuthChanged(authenticated, reason)
  gAuth = { linked = authenticated, status = authenticated and "Linked" or (reason or "Not linked"), link = "" }
  pushAuth()
  -- A stored sign-in restored at start-up is not news; a first link, a recovery
  -- and any loss are.
  if authenticated and gWasLinked == false then
    C4:FireEventByID(EVENT.ACCOUNT_LINKED)
  elseif not authenticated and gWasLinked ~= false then
    C4:FireEventByID(EVENT.ACCOUNT_NOT_LINKED)
  end
  gWasLinked = authenticated
  if authenticated then
    C4:UpdateProperty("Account Status", "Linked")
    UpdateProperty("Authentication URL", "")
    refreshThermostats()
    startPolling()
    return
  end
  stopPolling()
  C4:UpdateProperty("Account Status", gAuth.status)
  C4:UpdateProperty("Driver Status", "Not connected")
  for serial in pairs(gState.devices) do
    goOffline(serial)
  end
  gState.devices = {}
  gListed = false
end

--- @param link string
local function onLink(link)
  UpdateProperty("Authentication URL", link)
  gAuth.link = link or ""
  if not IsEmpty(link) then
    gAuth.status = "Open the link to sign in to Nuheat"
    C4:UpdateProperty("Account Status", "Open the Authentication URL to sign in to Nuheat")
  elseif gAuth.linked then
    gAuth.status = "Linked"
    C4:UpdateProperty("Account Status", "Linked")
  end
  pushAuth()
end

client = Client:new({ onLink = onLink, onAuthChanged = onAuthChanged })

--#ifndef DRIVERCENTRAL
--- Update the driver(s) from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(
      DRIVER_GITHUB_REPO,
      require("lib.driver-filenames"),
      Properties["Update Channel"] == "Prerelease",
      forceUpdate
    )
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("Driver update failed: %s", err)
    end)
end
--#endif

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

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

  -- Re-add persisted dynamic bindings. This must happen here, not in
  -- OnDriverLateInit: Director resolves stored connections before LateInit
  -- (see src/lib/bindings.lua).
  bindings:restoreBindings()
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

  --#ifndef DRIVERCENTRAL
  -- Auto-update: only the leader account instance checks, at most every 30 min,
  -- and only when Automatic Updates is On. The DriverCentral build lets
  -- cloud-client-byte own updates instead.
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    local isLeader = Select(getAccountDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  UpdateProperty("Authentication URL", "")
  if not client:isConfigured() then
    C4:UpdateProperty("Account Status", "This build has no Nuheat API credentials")
    C4:UpdateProperty("Driver Status", "Not configured")
    gAuth.status = "This build has no Nuheat API credentials"
    pushAuth()
    return
  end
  if client:start() then
    -- The refresh's outcome tells the companions, a moment from now.
    C4:UpdateProperty("Account Status", "Signing in...")
    C4:UpdateProperty("Driver Status", "Connecting")
  else
    gWasLinked = false
    C4:UpdateProperty("Account Status", "Not linked: run the Link Account action")
    C4:UpdateProperty("Driver Status", "Not connected")
    -- Companions keep the last state they were sent, which an update or a
    -- removed sign-in can leave saying Linked.
    pushAuth()
  end
end

function OnDriverDestroyed()
  stopPolling()
  CancelTimer("UpdateCheck")
  CancelTimer("NuheatReadback")
  CancelTimer("NuheatAddThermostats")
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

--- Writable only so Composer lets the link be selected and copied; an edit is undone.
function OPC.Authentication_URL(propertyValue)
  if propertyValue ~= gAuth.link then
    UpdateProperty("Authentication URL", gAuth.link)
  end
end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

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

function OPC.Poll_Interval(_v)
  if gInitialized and client:isAuthenticated() then
    startPolling()
  end
end

function OPC.Automatic_Updates(propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  if gInitialized then
    updateSettings:share("Update Channel", propertyValue)
  end
end
--#endif

-- ─── Messages from a companion (RFP dispatch) ──────────────────────────────

--- Serial numbers with a write in flight, and the newest settings that arrived
--- while it was. The companion re-pushes its intended state until the cloud
--- confirms it, so without coalescing one user action stacks several writes.
--- @type table<string, boolean>
local gWriteInFlight = {}
--- @type table<string, table>
local gQueuedWrite = {}

--- @type fun(serial: string, settings: table): void
local writeThermostat

writeThermostat = function(serial, settings)
  gWriteInFlight[serial] = true
  local function done()
    gWriteInFlight[serial] = nil
    local queued = gQueuedWrite[serial]
    if queued then
      gQueuedWrite[serial] = nil
      if client:isAuthenticated() then
        writeThermostat(serial, queued)
      end
    end
  end
  client:setThermostat(settings):next(function(written)
    -- Take the next refresh slot so a read already in flight, which may carry
    -- the pre-write state, is discarded when it lands.
    gRefreshIssued = gRefreshIssued + 1
    gRefreshAccepted = gRefreshIssued
    -- Not handed back: the companion already shows it, and an echo would read as
    -- the cloud confirming the write and end its wait before the cloud has.
    gState.devices[serial] = written
    SetTimer("NuheatReadback", WRITE_READBACK_S * ONE_SECOND, refreshThermostats)
    done()
  end, function(err)
    log:warn("Writing thermostat %s failed: %s", serial, err.message)
    if err.retryAfter then
      gRateLimitedUntil = os.time() + err.retryAfter
    end
    done()
  end)
end

--- A companion pushes mutated settings for this driver to write.
--- @param idBinding integer
--- @param _strCommand string
--- @param tParams table
function RFP.setThermostat(idBinding, _strCommand, tParams)
  log:trace("RFP.setThermostat(%s)", idBinding)
  local serial = serialForBinding(idBinding)
  if not serial or not client:isAuthenticated() then
    return
  end
  local ok, settings = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
  if not ok or type(settings) ~= "table" then
    return
  end
  settings.SerialNumber = serial
  if gWriteInFlight[serial] then
    log:trace("Write already in flight for %s; coalescing", serial)
    gQueuedWrite[serial] = settings
    return
  end
  writeThermostat(serial, settings)
end

--- A customer pressed Get Link in a thermostat's extras in the Control4 app.
function RFP.linkAccount(idBinding)
  log:trace("RFP.linkAccount(%s)", idBinding)
  EC.Link_Account()
end

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

function EC.Link_Account()
  log:trace("EC.Link_Account()")
  if not client:link() then
    C4:UpdateProperty("Account Status", "This build has no Nuheat API credentials")
    return
  end
  C4:UpdateProperty("Account Status", "Preparing a sign-in link...")
end

function EC.Unlink_Account()
  log:trace("EC.Unlink_Account()")
  client:unlink()
end

function EC.Refresh_Thermostats()
  log:trace("EC.Refresh_Thermostats()")
  refreshThermostats()
end

function EC.Add_Thermostats()
  log:trace("EC.Add_Thermostats()")
  addThermostats()
end

function EC.Reset_Driver(tParams)
  log:trace("EC.Reset_Driver()")
  if (tParams or {})["Are You Sure?"] == "Yes" then
    for serial in pairs(gState.devices) do
      goOffline(serial)
    end
    bindings:reset()
    gState.devices = {}
    client:unlink()
  end
end

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  UpdateDrivers(true)
end
--#endif

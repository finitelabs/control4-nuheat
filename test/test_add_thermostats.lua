-- The account driver's Add Thermostats action and its sign-in events: a
-- companion per thermostat, reusing an unconnected one, placed in the matching
-- room and shown only there; companions of thermostats that left the account
-- are renamed; Account Linked / Account Not Linked fire on real changes only.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_add_thermostats.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/nuheat/driver.lua"

local constants = require("constants")
constants.CLIENT_ID = "test-client"
constants.C4_OAUTH_API_KEY = "c4-oauth-key"
constants.C4_LINK_API_KEY = ""
constants.C4_OAUTH_PRODUCTION = ""

local function thermostat(serial, name)
  return {
    serialNumber = serial,
    name = name,
    setPointTemperature = 2333,
    mode = 1,
    online = true,
    isHeating = false,
    currentTemperature = 2378,
  }
end

require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
require("drivers-common-public.global.timer")
require("nuheat.client")

-- ─── Scripted services ─────────────────────────────────────────────────────

local thermostats = {
  thermostat("111", "Master Bathroom Floor"),
  thermostat("222", "Kitchen"),
  thermostat("333", "Garage Slab"),
}
urlDo = function(method, url, _data, _headers, callback, context)
  local code, body = 404, nil
  if url == "https://apps.control4driversdev.com/state" and method == "POST" then
    code, body = 200, { nonce = "nonce-1", expiresAt = os.time() + 300 }
  elseif url:find("^https://apps%.control4driversdev%.com/state%?") then
    code, body = 200, { code = "auth-code" }
  elseif url == constants.TOKEN_ENDPOINT then
    code, body = 200, { access_token = "access-1", refresh_token = "refresh-1", expires_in = 3600 }
  elseif url == constants.API_BASE .. "/api/v2/Thermostat" and method == "GET" then
    code, body = 200, thermostats
  end
  callback(nil, code, {}, body, context, url)
end

local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end

local props = {}
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.SendToProxy = function() end

local events = {}
local EVENT_NAMES = { "Account Linked", "Account Not Linked" }
C4.FireEventByID = function(_, id)
  events[#events + 1] = EVENT_NAMES[id]
end

-- ─── A project: rooms, devices and the calls that change them ───────────────

local ME = C4:GetDeviceID()
local ACCOUNT_ROOM = 19
local ROOMS = { [19] = "Utility", [40] = "Master Bathroom", [41] = "Kitchen", [42] = "Bathroom" }
local names = {}
local companions = {}
local proxies = {}
local nextId = 900

C4.RoomGetId = function()
  return ACCOUNT_ROOM
end
C4.GetDevicesByC4iName = function(_, filename)
  if filename == "roomdevice.c4i" then
    return ROOMS
  end
  if filename == "nuheat_thermostat.c4z" then
    return companions
  end
  return {}
end
C4.GetProxyDevicesById = function(_, deviceId)
  return proxies[deviceId]
end
C4.GetDeviceDisplayName = function(_, deviceId)
  return names[deviceId]
end
C4.RenameDevice = function(_, deviceId, name)
  names[deviceId] = name
end
local function addCompanion(name)
  nextId = nextId + 2
  local id, proxyId = nextId, nextId + 1
  companions[id] = name
  proxies[id] = proxyId
  names[proxyId] = name
  return id, proxyId
end
local added = {}
C4.AddDevice = function(_, filename, roomId, name, callback)
  local id = addCompanion(name)
  added[#added + 1] = { filename = filename, roomId = roomId, name = name, id = id }
  callback(id, {})
end
local hidden = {}
C4.SendToDevice = function(_, deviceId, command, params)
  if command == "SET_DEVICE_HIDDEN_STATE" then
    hidden[params.DEVICE_ID] = hidden[params.DEVICE_ID] or {}
    hidden[params.DEVICE_ID][deviceId] = params.IS_HIDDEN
  end
end

local navRefreshes = 0
RefreshNavs = function()
  navRefreshes = navRefreshes + 1
end

local function companionOf(serial)
  local binding = require("lib.bindings"):getDynamicBinding(constants.BINDING_NAMESPACE, serial)
  local id = next(C4:GetBoundConsumerDevices(ME, binding.bindingId) or {})
  return id, id and proxies[id]
end

local function runAddQueue()
  while timers.NuheatAddThermostats do
    local timer = timers.NuheatAddThermostats
    timers.NuheatAddThermostats = nil
    timer.callback()
  end
end

C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261025", model = "Nuheat" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
Properties["Poll Interval"] = "60 seconds"
Properties["Authentication URL"] = ""
Properties["Log Level"] = "3 - Info"
Properties["Log Mode"] = "Off"
package.preload["cloud-client-byte"] = function()
  return {}
end

-- An unconnected companion the integrator already dropped in.
local spareId, spareProxy = addCompanion("Nuheat Thermostat")

dofile(DRIVER)
OnDriverInit()
OnDriverLateInit()

T.section("before linking")
EC.Add_Thermostats()
T.contains("Add Thermostats asks for a link", props["Driver Status"], "Link the account")
T.eq("and adds nothing", #added, 0)

T.section("a first link fires Account Linked")
EC.Link_Account()
timers["OAuth_Nuheat_Timer_CheckState"].callback()
T.eq("Account Status", props["Account Status"], "Linked")
T.eq("one event", events, { "Account Linked" })

T.section("Add Thermostats gives every thermostat a companion")
EC.Add_Thermostats()
runAddQueue()
T.eq("the existing companion is reused for the first, by name", select(1, companionOf("333")), spareId)
T.eq("and renamed for it", names[spareProxy], "Garage Slab")
T.eq("it is left where the integrator put it", hidden[spareProxy], nil)
T.eq("two companions are added", #added, 2)
T.eq("the companion driver", added[1].filename, "nuheat_thermostat.c4z")

local kitchenId, kitchenProxy = companionOf("222")
T.truthy("Kitchen is bound", kitchenId)
T.eq("in the room of the same name", added[1].name == "Kitchen" and added[1].roomId or added[2].roomId, 41)
T.eq("shown in Kitchen", hidden[kitchenProxy][41], false)
T.eq("hidden in Utility", hidden[kitchenProxy][19], true)
T.eq("hidden in Master Bathroom", hidden[kitchenProxy][40], true)

local _, bathProxy = companionOf("111")
T.eq("Master Bathroom Floor goes in Master Bathroom, not Bathroom", hidden[bathProxy][40], false)
T.eq("hidden in Bathroom", hidden[bathProxy][42], true)
T.eq("named for the thermostat", names[bathProxy], "Master Bathroom Floor")
T.eq("Driver Status when done", props["Driver Status"], "Connected (3 thermostats)")
T.eq("Navigators are refreshed once", navRefreshes, 1)

T.section("running it again adds nothing")
EC.Add_Thermostats()
runAddQueue()
T.eq("no new companions", #added, 2)
T.contains("Driver Status says so", props["Driver Status"], "already has a driver")

T.section("an unmatched name goes in the account's room")
thermostats[#thermostats + 1] = thermostat("444", "Sunroom")
timers.NuheatPoll.callback()
EC.Add_Thermostats()
runAddQueue()
T.eq("added in the account driver's room", added[3].roomId, ACCOUNT_ROOM)

T.section("a thermostat that leaves the account is marked")
table.remove(thermostats, 2)
timers.NuheatPoll.callback()
EC.Add_Thermostats()
runAddQueue()
T.eq("its companion is renamed", names[kitchenProxy], "Kitchen - REMOVED FROM NUHEAT")
EC.Add_Thermostats()
T.eq("only once", names[kitchenProxy], "Kitchen - REMOVED FROM NUHEAT")

T.section("a thermostat that comes back gets its name back")
table.insert(thermostats, 2, thermostat("222", "Kitchen"))
timers.NuheatPoll.callback()
EC.Add_Thermostats()
runAddQueue()
T.eq("the suffix is removed", names[kitchenProxy], "Kitchen")
T.eq("and no new companion is added", #added, 3)

T.section("losing the sign-in fires Account Not Linked once")
events = {}
EC.Unlink_Account()
T.eq("one event", events, { "Account Not Linked" })
EC.Unlink_Account()
T.eq("not again while unlinked", events, { "Account Not Linked" })

T.section("a restart with no stored sign-in")
events = {}
local authSends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  if command == "authStatus" then
    authSends[#authSends + 1] = { idBinding = idBinding, linked = tParams.LINKED }
  end
end
dofile(DRIVER)
OnDriverInit()
OnDriverLateInit()
T.eq("fires no event", events, {})
T.eq("tells each restored thermostat binding", #authSends, 4)
T.eq("that the account is not linked", authSends[1] and authSends[1].linked, "false")

T.finish()

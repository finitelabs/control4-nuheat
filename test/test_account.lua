-- The nuheat account driver end to end against scripted services: Control4's
-- OAuth redirect server, Nuheat's identity server and the v1 OpenAPI. Covers
-- Link Account through to a thermostat handed to its companion, a companion's
-- write, a 429's pause, a thermostat leaving the account, and Unlink Account.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_account.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/nuheat/driver.lua"

local constants = require("constants")
constants.CLIENT_ID = "test-client"
constants.CLIENT_SECRET = "test-secret"
constants.C4_OAUTH_API_KEY = "c4-oauth-key"
constants.C4_LINK_API_KEY = ""
constants.C4_OAUTH_PRODUCTION = ""

local THERMOSTAT = {
  serialNumber = "1234567",
  name = "Master Bathroom Floor",
  setPointTemperature = 2333,
  mode = 1,
  online = true,
  isHeating = false,
  currentTemperature = 2378,
}

-- Loaded before the stubs below, which would otherwise be redefined when the
-- driver's requires first run these modules.
require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
require("drivers-common-public.global.timer")
require("nuheat.client")

-- ─── Scripted services ─────────────────────────────────────────────────────

local requests = {}
local thermostats = { THERMOSTAT }
local apiStatus, apiHeaders = 200, {}
urlDo = function(method, url, data, headers, callback, context)
  table.insert(requests, { method = method, url = url, data = data, headers = headers })
  local code, body, responseHeaders = 404, nil, {}
  if url == "https://apps.control4driversdev.com/state" and method == "POST" then
    code, body = 200, { nonce = "nonce-1", expiresAt = os.time() + 300 }
  elseif url:find("^https://apps%.control4driversdev%.com/state%?") then
    code, body = 200, { code = "auth-code" }
  elseif url == constants.TOKEN_ENDPOINT then
    code, body = 200, { access_token = "access-1", refresh_token = "refresh-1", expires_in = 3600 }
  elseif url == constants.API_BASE .. "/api/v2/Thermostat" and method == "GET" then
    code, body, responseHeaders = apiStatus, apiStatus == 200 and thermostats or nil, apiHeaders
  elseif url:find("^" .. constants.API_BASE:gsub("%p", "%%%0") .. "/api/v2/Mode/") and method == "PUT" then
    code = 204
  end
  callback(nil, code, responseHeaders, body, context, url)
end

local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end

-- SaltedEncrypt asks for a cipher the shim does not model; persistence of the
-- refresh token is auth_code_grant's and covered by its own test.
SaltedEncrypt = function(key, plaintext)
  return plaintext
end
SaltedDecrypt = function(key, ciphertext)
  return ciphertext
end

local props = {}
C4.UpdateProperty = function(_, name, value)
  props[name] = value
end
local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  table.insert(sends, { idBinding = idBinding, command = command, params = tParams })
end

local function lastSend(command)
  for i = #sends, 1, -1 do
    if sends[i].command == command then
      return sends[i]
    end
  end
end

local function lastRequest(method, pattern)
  for i = #requests, 1, -1 do
    if requests[i].method == method and requests[i].url:find(pattern) then
      return requests[i]
    end
  end
end

-- CheckMinimumVersion compares driver.xml's minimum against the controller's.
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261023", model = "Nuheat" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end

Properties["Poll Interval"] = "60 seconds"
Properties["Log Level"] = "3 - Info"
Properties["Log Mode"] = "Off"

-- Source, not a build: both sides of every #ifdef run, and the DriverCentral
-- licensing client would take over OnDriverLateInit.
package.preload["cloud-client-byte"] = function()
  return {}
end

dofile(DRIVER)
OnDriverInit()
OnDriverLateInit()

T.section("a fresh driver waits to be linked")
T.contains("Account Status asks for Link Account", props["Account Status"], "Link Account")
T.eq("nothing polls", timers.NuheatPoll, nil)

T.section("Link Account signs in through Control4's redirect service")
EC.Link_Account()
local state = lastRequest("POST", "control4driversdev%.com/state$")
T.truthy("a state is registered on the development server", state)
T.eq("with the C4 OAuth API key", state and state.headers.Authorization, "c4-oauth-key")
T.contains(
  "the Authentication URL is Nuheat's authorize endpoint",
  props["Authentication URL"],
  constants.AUTH_ENDPOINT
)
T.contains("for this client", props["Authentication URL"], "client_id=test-client")

timers["OAuth_Nuheat_Timer_CheckState"].callback()
local token = lastRequest("POST", "connect/token")
T.contains("the code is exchanged", token and token.data, "grant_type=authorization_code")
T.eq("Account Status", props["Account Status"], "Linked")
T.eq("the link is cleared", props["Authentication URL"], "")
T.truthy("polling starts", timers.NuheatPoll and timers.NuheatPoll.repeating)
T.eq("every Poll Interval", timers.NuheatPoll.delay, 60 * 1000)

T.section("the account's thermostat is handed to its companion")
T.eq("Driver Status", props["Driver Status"], "Connected (1 thermostat)")
local handoff = lastSend("updateThermostat")
T.truthy("UPDATE_THERMOSTAT is sent", handoff)
local device = JSON:decode(handoff.params.JSON)
T.eq("carrying the device object", device.SerialNumber, "1234567")
T.eq("named for the thermostat", device.Room, "Master Bathroom Floor")
local bindingId = handoff.idBinding

T.section("a companion's write is sent as a ThermostatUpdateModel")
requests = {}
device.SetPointTemp = 2500
device.Mode = 2
RFP.setThermostat(bindingId, "setThermostat", { JSON = JSON:encode(device) })
local put = lastRequest("PUT", "/api/v2/Mode/Hold$")
T.truthy("one PUT", put)
T.eq(
  "with the new setpoint and hold",
  JSON:decode(put.data),
  { serialNumber = "1234567", temperature = 2500, temperatureType = 0 }
)
T.eq("the write is not echoed to the companion", lastSend("updateThermostat"), handoff)
T.truthy("and a read-back is scheduled", timers.NuheatReadback)

T.section("a 429 pauses polling for Retry-After")
apiStatus, apiHeaders = 429, { ["Retry-After"] = "120" }
timers.NuheatPoll.callback()
T.contains("Driver Status says so", props["Driver Status"], "Rate limited")
requests = {}
apiStatus, apiHeaders = 200, {}
timers.NuheatPoll.callback()
T.eq("the next poll inside the window sends nothing", #requests, 0)

T.section("a thermostat that leaves the account goes offline")
thermostats = {}
-- Past the rate-limit window from the section above.
local realTime = os.time
os.time = function()
  return realTime() + 3600
end
timers.NuheatPoll.callback()
os.time = realTime
T.truthy("GO_OFFLINE is sent", lastSend("goOffline"))
T.eq("Driver Status counts none", props["Driver Status"], "Connected (0 thermostats)")

T.section("every poll re-sends the link state with the device")
thermostats = { THERMOSTAT }
sends = {}
os.time = function()
  return realTime() + 3600
end
timers.NuheatPoll.callback()
os.time = realTime
local polled = lastSend("authStatus")
T.eq("to the thermostat's binding", polled and polled.idBinding, bindingId)
T.eq("linked", polled and polled.params.LINKED, "true")

T.section("a new link that expires while linked keeps the account linked")
EC.Link_Account()
T.contains("a link is shown", props["Authentication URL"], constants.AUTH_ENDPOINT)
timers["OAuth_Nuheat_Timer_GetCodeStatusExpired"].callback()
T.eq("the link is cleared", props["Authentication URL"], "")
T.eq("Account Status is still Linked", props["Account Status"], "Linked")
T.truthy("and polling continues", timers.NuheatPoll)

T.section("a bound companion is told the link state")
sends = {}
OBC[bindingId](bindingId, "NUHEAT_THERMOSTAT", true)
local auth = lastSend("authStatus")
T.eq("on bind, to that binding", auth and auth.idBinding, bindingId)
T.eq("linked", auth and auth.params.LINKED, "true")

T.section("Unlink Account signs out and stops polling")
EC.Unlink_Account()
T.eq("Account Status", props["Account Status"], "Signed out")
T.eq("polling stops", timers.NuheatPoll, nil)
auth = lastSend("authStatus")
T.eq("the companion is told", auth and auth.params.LINKED, "false")
T.eq("why", auth and auth.params.STATUS, "Signed out")

T.section("Get Link pressed in the app starts a sign-in")
requests = {}
RFP.linkAccount(bindingId, "linkAccount", {})
T.truthy("a state is registered", lastRequest("POST", "control4driversdev%.com/state$"))
auth = lastSend("authStatus")
T.contains("the companion gets the link", auth and auth.params.LINK, constants.AUTH_ENDPOINT)
T.eq("still unlinked", auth and auth.params.LINKED, "false")

T.section("a build without secrets says so")
constants.CLIENT_ID = "__NUHEAT_CLIENT_ID__"
dofile(DRIVER)
OnDriverLateInit()
T.eq("Driver Status", props["Driver Status"], "Not configured")
T.contains("Account Status", props["Account Status"], "no Nuheat API credentials")

T.finish()

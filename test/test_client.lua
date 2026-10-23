-- nuheat.client against a scripted Nuheat OpenAPI: the v1 ThermostatModel
-- translation, the ThermostatUpdateModel a write sends, and what a 401 and a 429
-- do. The payloads are shaped like the API's real responses (captured from a
-- live account, serial numbers and names replaced).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_client.lua

local T = require("testlib")

require("c4_shim")
JSON = require("JSON")

local constants = require("constants")
constants.CLIENT_ID = "test-client"
constants.CLIENT_SECRET = "test-secret"
constants.C4_OAUTH_API_KEY = "c4-oauth-key"
constants.C4_LINK_API_KEY = ""
constants.C4_OAUTH_PRODUCTION = ""

local Client = require("nuheat.client")

--- GET /api/v1/Thermostat as a live account answered it.
local V1_THERMOSTATS = {
  {
    serialNumber = "1234567",
    name = "Master Bathroom Floor",
    setPointTemp = 2333,
    scheduleMode = 1,
    holdSetPointDateTime = nil,
    groupId = "11111111-2222-3333-4444-555555555555",
    swVersion = "2.0.1",
    online = false,
    operatingMode = 1,
    isHeating = false,
    currentTemperature = 2378,
    tzOffset = "-5:00",
    error = nil,
  },
}

local requests = {}
local respond = function(_req)
  return nil, 200, {}, nil
end
urlDo = function(method, url, data, headers, callback, context)
  local req = { method = method, url = url, data = data, headers = headers }
  table.insert(requests, req)
  local strError, code, responseHeaders, body = respond(req)
  callback(strError, code, responseHeaders or {}, body, context, url)
end

local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end

--- A client holding an access token, as if a sign-in had completed.
local function signedIn()
  local client = Client:new()
  client:start()
  client.grant.ACCESS_TOKEN = "access-1"
  client.grant.REFRESH_TOKEN = "refresh-1"
  return client
end

--- Settle a Deferred synchronously (the stubbed transport answers inline).
local function settle(d)
  local out = {}
  d:next(function(value)
    out.value = value
  end, function(err)
    out.err = err
  end)
  return out
end

T.section("a build without secrets cannot sign in")
do
  local saved = constants.CLIENT_ID
  constants.CLIENT_ID = "__NUHEAT_CLIENT_ID__"
  local client = Client:new()
  T.falsy("an unsubstituted placeholder is not a client ID", client:isConfigured())
  T.falsy("start declines", client:start())
  T.falsy("link declines", client:link())
  constants.CLIENT_ID = saved
end

T.section("ThermostatModel becomes the drivers' device object")
local device = Client.toDevice(V1_THERMOSTATS[1])
T.eq("serial", device.SerialNumber, "1234567")
T.eq("room from the thermostat's name", device.Room, "Master Bathroom Floor")
T.eq("temperature in hundredths of a degree C", device.Temperature, 2378)
T.eq("setpoint", device.SetPointTemp, 2333)
T.eq("schedule mode", device.ScheduleMode, 1)
T.eq("operating mode", device.OperatingMode, 1)
T.eq("online", device.Online, false)
T.eq("heating", device.Heating, false)
T.eq("time zone offset", device.TzOffset, "-5:00")

T.section("getThermostats reads v1 with the bearer token")
requests = {}
respond = function()
  return nil, 200, {}, V1_THERMOSTATS
end
local client = signedIn()
local got = settle(client:getThermostats())
T.eq("one GET", #requests, 1)
T.eq("to the v1 list", requests[1].url, "https://api.mynuheat.com/api/v1/Thermostat")
T.eq("with the access token", requests[1].headers.Authorization, "Bearer access-1")
T.eq("one device", #got.value, 1)
T.eq("translated", got.value[1].Room, "Master Bathroom Floor")

respond = function()
  return nil, 200, {}, { V1_THERMOSTATS[1], { name = "no serial" }, "junk" }
end
T.eq("entries without a serial are skipped", #settle(client:getThermostats()).value, 1)

T.section("setThermostat sends a ThermostatUpdateModel")
requests = {}
respond = function()
  return nil, 204, {}, nil
end
local write = Client.toDevice(V1_THERMOSTATS[1])
write.SetPointTemp = 2500
write.ScheduleMode = 2
got = settle(client:setThermostat(write))
T.eq("a PUT", requests[1].method, "PUT")
T.eq("to v1 Thermostat", requests[1].url, "https://api.mynuheat.com/api/v1/Thermostat")
T.eq("as JSON", requests[1].headers["Content-Type"], "application/json")
T.eq("carrying the serial, setpoint and mode only", JSON:decode(requests[1].data), {
  serialNumber = "1234567",
  setPointTemp = 2500,
  scheduleMode = 2,
})
T.eq("resolves with the device as written", got.value.SetPointTemp, 2500)

write.HoldSetPointDateTime = "2026-10-24T05:00:00Z"
settle(client:setThermostat(write))
T.eq(
  "a hold end time goes when set",
  JSON:decode(requests[#requests].data).holdSetPointDateTime,
  "2026-10-24T05:00:00Z"
)

T.section("a 401 refreshes the token and rejects")
requests = {}
local refreshed = false
client.grant.RefreshToken = function()
  refreshed = true
end
respond = function()
  return nil, 401, {}, nil
end
got = settle(client:getThermostats())
T.eq("rejects with the status", got.err and got.err.code, 401)
T.truthy("and asks the grant to refresh", refreshed)

T.section("a 429 carries Retry-After")
respond = function()
  return nil, 429, { ["Retry-After"] = "58" }, "API calls quota exceeded!"
end
got = settle(client:getThermostats())
T.eq("rejects with the status", got.err and got.err.code, 429)
T.eq("and the seconds to wait", got.err and got.err.retryAfter, 58)

respond = function()
  return nil, 429, {}, nil
end
T.eq("a minute when Nuheat sends none", settle(client:getThermostats()).err.retryAfter, 60)

T.section("no request goes out signed out")
requests = {}
local signedOut = Client:new()
got = settle(signedOut:getThermostats())
T.eq("nothing sent", #requests, 0)
T.truthy("rejects", got.err)

T.finish()

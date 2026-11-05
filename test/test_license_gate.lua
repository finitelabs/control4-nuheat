-- The Nuheat account's license gate in the DriverCentral build, driven by the real cloud client against a fake
-- Cloud driver and scripted Nuheat services. Licensed, the account signs in, polls and writes; five minutes without a
-- license stop every sign-in, token refresh, poll and write and take the thermostats offline; a license starts it
-- again at once. With no product id yet the account is stopped from its load.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_gate.lua

require("c4_shim")
local T = require("testlib")
local cloud = require("dc_cloud")

local DRIVER = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../drivers/nuheat/driver.lua"

local constants = require("constants")
constants.CLIENT_ID = "test-client"
constants.C4_OAUTH_API_KEY = "c4-oauth-key"
constants.C4_LINK_API_KEY = ""
constants.C4_OAUTH_PRODUCTION = ""

-- Loaded before the stubs below, which the driver's requires would otherwise replace.
require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
require("drivers-common-public.global.timer")
-- The account's client, kept as the driver makes it.
local Client = require("nuheat.client")
local newClient, client = Client.new, nil
Client.new = function(...)
  client = newClient(...)
  return client
end

-- Control4's redirect service, Nuheat's identity server and the OpenAPI, answering at once.
local requests = {}
urlDo = function(method, url, _data, _headers, callback, context)
  requests[#requests + 1] = { method = method, url = url }
  local code, body = 404, nil
  if url == "https://apps.control4driversdev.com/state" and method == "POST" then
    code, body = 200, { nonce = "nonce-1", expiresAt = os.time() + 300 }
  elseif url:find("^https://apps%.control4driversdev%.com/state%?") then
    code, body = 200, { code = "auth-code" }
  elseif url == constants.TOKEN_ENDPOINT then
    code, body = 200, { access_token = "access-1", refresh_token = "refresh-1", expires_in = 3600 }
  elseif url == constants.API_BASE .. "/api/v2/Thermostat" and method == "GET" then
    code, body =
      200, {
        {
          serialNumber = "1234567",
          name = "Bath Floor",
          setPointTemperature = 2333,
          mode = 1,
          online = true,
          isHeating = false,
          currentTemperature = 2378,
        },
      }
  elseif url:find("/api/v2/Mode/") and method == "PUT" then
    code = 204
  end
  callback(nil, code, {}, body, context, url)
end

--- Requests whose method is `method` and whose URL matches `pattern`.
local function count(method, pattern)
  local n = 0
  for _, r in ipairs(requests) do
    if r.method == method and r.url:find(pattern) then
      n = n + 1
    end
  end
  return n
end

-- drivers-common-public's named timers, kept so a test fires them by hand.
local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end
local function fire(name)
  if timers[name] then
    timers[name].callback()
  end
end
local function grantTimers()
  local n = 0
  for name in pairs(timers) do
    if name:find("^OAuth_Nuheat_Timer_") then
      n = n + 1
    end
  end
  return n
end

C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  sends[#sends + 1] = { idBinding = idBinding, command = command, params = tParams }
end
local function sent(command)
  local n = 0
  for _, s in ipairs(sends) do
    if s.command == command then
      n = n + 1
    end
  end
  return n
end
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261104", model = "Nuheat" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
local events = 0
C4.FireEventByID = function()
  events = events + 1
end

--- Runs `path` as the DriverCentral build compiles it: a line its directives leave out is blanked.
local function dofileDriverCentral(path)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and (name == "DRIVERCENTRAL") == (ifdef == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  assert(load(table.concat(lines, "\n"), "@" .. path))()
end

local gate

--- A load of the account driver with a fresh client and gate. The stored sign-in is kept only when asked.
--- @param answer? table What the Cloud driver answers each ping with; nil answers nothing.
--- @param options? table `pid` for the product id (999), `keepSignIn` to keep the stored token.
local function load(answer, options)
  options = options or {}
  if gate and gate._timer then
    gate._timer:Cancel()
  end
  package.loaded["cloud-client-byte"] = nil
  package.loaded["lib.drivercentral"] = nil
  cloud.ping, cloud.answer, cloud.silent, cloud.present = nil, answer, answer == nil, true
  for k in pairs(timers) do
    timers[k] = nil
  end
  if not options.keepSignIn then
    PersistDeleteValue(C4:Hash("SHA256", C4:GetDeviceID() .. constants.CLIENT_ID, SHA_ENC_DEFAULTS))
  end
  Properties = {
    ["Poll Interval"] = "60 seconds",
    ["Authentication URL"] = "",
    ["Log Level"] = "3 - Info",
    ["Log Mode"] = "Off",
    ["Cloud Status"] = "",
    ["Automatic Updates"] = "Off",
    ["Cloud Monitoring"] = "Disabled",
  }
  DC_OnDriverStatus = nil
  dofileDriverCentral(DRIVER)
  gate = require("lib.drivercentral")
  gate.PRODUCT_ID = options.pid or 999
  OnDriverInit()
  OnDriverLateInit("DIT_STARTUP")
end

--- `n` rounds of 10 s: one ping, then one read by the gate.
local function tick(n)
  for _ = 1, n or 1 do
    if cloud.ping then
      cloud.poll(1)
    end
    gate:_check()
  end
end

--- Link Account, then the link check finds the code and the token comes back: a first sign-in.
local function link()
  EC.Link_Account()
  fire("OAuth_Nuheat_Timer_CheckState")
end

--- The thermostat handed to its companion last, as a companion would write it back.
local function handoff()
  for i = #sends, 1, -1 do
    if sends[i].command == "updateThermostat" then
      return sends[i]
    end
  end
end
local function write()
  local h = handoff()
  local device = JSON:decode(h.params.JSON)
  device.SetPointTemp = 2500
  ReceivedFromProxy(h.idBinding, "setThermostat", { JSON = JSON:encode(device) })
end

T.section("A licensed account signs in, polls and writes")
do
  load({ AC = 1, AS = "License Activated" })
  link()
  T.eq("signed in", count("POST", "connect/token") > 0, true)
  T.eq("polling", timers.NuheatPoll ~= nil, true)
  T.eq("a thermostat handed to its companion", handoff() ~= nil, true)
  tick(40)
  local before = count("GET", "/api/v2/Thermostat$")
  fire("NuheatPoll")
  T.eq("still polling after 400 s", count("GET", "/api/v2/Thermostat$") > before, true)
  write()
  T.eq("a companion's write reaches Nuheat", count("PUT", "/api/v2/Mode/"), 1)
end

T.section("Without a license the account stops five minutes after its load, and nothing reaches Nuheat")
do
  load({ AC = 0, AS = "Invalid License" })
  link()
  tick(29)
  T.eq("29 reads of 0: polling", timers.NuheatPoll ~= nil, true)
  local offline = sent("goOffline")
  tick()
  T.eq("the 30th read stops polling", timers.NuheatPoll, nil)
  T.eq("and the grant's own timers", grantTimers(), 0)
  T.eq("the thermostat goes offline", sent("goOffline") > offline, true)
  T.eq("Driver Status says why", Properties["Driver Status"], "No active license")
  T.eq("and Account Status", Properties["Account Status"], "No active license")
  local before = #requests
  EC.Link_Account()
  EC.Refresh_Thermostats()
  EC.Add_Thermostats()
  write()
  OnPropertyChanged("Poll Interval")
  T.eq("Link, Refresh, Add Thermostats, a write and a poll change send nothing", #requests, before)
  T.eq("and start no poll", timers.NuheatPoll, nil)
end

T.section("A refresh already in flight when the account stops cannot start it again")
do
  load({ AC = 1, AS = "License Activated" })
  link()
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  tick(30)
  local before = #requests
  -- What a token response still on its way when the gate stopped the account would run next.
  client.grant:RefreshToken()
  client.grant:CheckState("state", nil, "nonce-1")
  T.eq("the stopped grant sends nothing", #requests, before)
  T.eq("and sets no timer of its own", grantTimers(), 0)
end

T.section("A license back signs in again with the stored token and polls, as a load does")
do
  load({ AC = 1, AS = "License Activated" })
  link()
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  tick(30)
  ShimPersistLand() -- the stored token lands long before a purchase
  T.eq("stopped", timers.NuheatPoll, nil)
  local tokens = count("POST", "connect/token")
  local eventsBefore = events
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.say(cloud.answer)
  fire("OAuth_Nuheat_Timer_InitWithToken")
  T.eq("the stored token is refreshed", count("POST", "connect/token") > tokens, true)
  T.eq("polling again", timers.NuheatPoll ~= nil, true)
  T.eq("no Account Linked or Not Linked event fires", events, eventsBefore)
end

T.section("An Add Thermostats run the stop cut short runs again once a license is back")
do
  -- Rooms and companions as an empty project has them; Control4 has not yet answered the companion's add.
  local devicesByName, roomGetId, addDevice, proxies =
    C4.GetDevicesByC4iName, C4.RoomGetId, C4.AddDevice, C4.GetProxyDevicesById
  C4.GetProxyDevicesById = function() end
  C4.RoomGetId = function()
    return 1
  end
  C4.GetDevicesByC4iName = function(self, name)
    if name == "roomdevice.c4i" or name == "nuheat_thermostat.c4z" then
      return {}
    end
    return devicesByName(self, name)
  end
  local answer
  C4.AddDevice = function(_, _, _, _, callback)
    answer = callback
  end
  load({ AC = 1, AS = "License Activated" })
  link()
  EC.Add_Thermostats()
  T.eq("the run is under way", Properties["Driver Status"], "Adding thermostat 1 of 1...")
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  tick(30)
  answer(901) -- Control4 answers the add after the stop
  T.eq("the late answer leaves the account stopped", Properties["Driver Status"], "No active license")
  T.eq("and arms no next step", timers.NuheatAddThermostats, nil)
  ShimPersistLand()
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.say(cloud.answer)
  fire("OAuth_Nuheat_Timer_InitWithToken")
  fire("NuheatPoll")
  EC.Add_Thermostats()
  T.eq("Add Thermostats runs again", Properties["Driver Status"], "Adding thermostat 1 of 1...")
  C4.GetDevicesByC4iName, C4.RoomGetId, C4.AddDevice, C4.GetProxyDevicesById =
    devicesByName, roomGetId, addDevice, proxies
end

T.section("A Cloud driver update leaves a licensed account polling")
do
  load({ AC = 1, AS = "License Activated" })
  link()
  tick(3)
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  tick(3)
  cloud.silent = false
  tick(40)
  T.eq("polling", timers.NuheatPoll ~= nil, true)
end

T.section("With no product id yet the account is stopped from its load")
do
  requests = {}
  load({ AC = 1, AS = "License Activated" }, { pid = 0 })
  T.eq("the client is not loaded", package.loaded["cloud-client-byte"], nil)
  T.eq("Driver Status", Properties["Driver Status"], "No active license")
  EC.Link_Account()
  tick(40)
  T.eq("nothing reaches Nuheat", #requests, 0)
end

if gate and gate._timer then
  gate._timer:Cancel()
end
T.finish()

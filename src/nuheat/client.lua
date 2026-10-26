--- Nuheat OpenAPI client.
---
--- Signs in with OAuth2 through Control4's redirect service (drivers-common-public
--- auth_code_grant), which keeps the refresh token encrypted in persistent storage
--- and refreshes it on its own. Reads and writes thermostats through the v2 API
--- and translates the v2 models to and from the device object the drivers share:
--- { SerialNumber, Room, Online, Heating, Temperature, SetPointTemp, Mode,
--- HoldUntil, Error }, with temperatures in hundredths of a degree Celsius as the
--- API sends them.

local deferred = require("deferred")
local http = require("lib.http")
local log = require("lib.logging")
local JSON = require("JSON")
local constants = require("constants")
local OAuth = require("drivers-common-public.module.auth_code_grant")
local Thermostat = require("nuheat.thermostat")

--- @class NuheatClient
--- @field grant table|nil The auth_code_grant object, once start() has run.
--- @field _onLink fun(link: string)
--- @field _onAuthChanged fun(authenticated: boolean, reason: string|nil)
local Client = {}
Client.__index = Client

--- A build secret, or nil when the build substituted none (a source checkout
--- still holds the literal __NAME__ placeholder).
--- @param value string|nil
--- @return string|nil
local function secret(value)
  if type(value) ~= "string" or value == "" or value:match("^__[%w_]+__$") then
    return nil
  end
  return value
end

--- @return boolean
local function inProduction()
  return secret(constants.C4_OAUTH_PRODUCTION) == "true"
end

--- @param options table|nil { onLink = fun(link: string), onAuthChanged = fun(authenticated: boolean, reason: string|nil) }
--- @return NuheatClient
function Client:new(options)
  options = options or {}
  local instance = setmetatable({}, self)
  instance._onLink = options.onLink or function() end
  instance._onAuthChanged = options.onAuthChanged or function() end
  instance.grant = nil
  return instance
end

--- Whether this build carries the client and Control4 keys a sign-in needs.
--- @return boolean
function Client:isConfigured()
  return secret(constants.CLIENT_ID) ~= nil
    and secret(constants.CLIENT_SECRET) ~= nil
    and secret(constants.C4_OAUTH_API_KEY) ~= nil
end

--- Create the grant. A refresh token stored by an earlier sign-in on this device
--- is refreshed a second later, which reports through onAuthChanged.
--- @return boolean willRefresh Whether a stored token is about to be refreshed.
function Client:start()
  if not self:isConfigured() then
    log:warn("This build has no Nuheat client or Control4 OAuth keys; sign-in is unavailable")
    return false
  end
  -- make_short_link reads the global to pick its server.
  IN_PRODUCTION = inProduction()
  local grant, willRefresh = OAuth:new({
    NAME = "Nuheat",
    AUTHORIZATION = secret(constants.C4_OAUTH_API_KEY),
    SHORT_LINK_AUTHORIZATION = secret(constants.C4_LINK_API_KEY),
    LINK_CHANGE_CALLBACK = function(link)
      self._onLink(link or "")
    end,
    REDIRECT_URI = inProduction() and constants.REDIRECT_URI_PROD or constants.REDIRECT_URI_DEV,
    AUTH_ENDPOINT_URI = constants.AUTH_ENDPOINT,
    TOKEN_ENDPOINT_URI = constants.TOKEN_ENDPOINT,
    -- The redirect service's maximum; the short link is given the same lifetime.
    REDIRECT_DURATION = 10 * 60,
    API_CLIENT_ID = secret(constants.CLIENT_ID),
    API_SECRET = secret(constants.CLIENT_SECRET),
    -- Chemelex enabled PKCE on this client; the secret is kept as well.
    USE_PKCE = true,
    SCOPES = constants.SCOPES,
  })
  grant.notifyHandler.AccessTokenGranted = function()
    self._onAuthChanged(true)
  end
  grant.notifyHandler.AccessTokenDenied = function(_, err, description)
    self._onAuthChanged(false, description or err or "Nuheat refused the sign-in")
  end
  -- A sign-in started while already signed in that then fails leaves the
  -- existing token in place, so it only clears the link.
  local function linkFailed(reason)
    if self:isAuthenticated() then
      log:info("A new sign-in did not complete (%s); keeping the existing one", reason)
      self._onLink("")
    else
      self._onAuthChanged(false, reason)
    end
  end
  grant.notifyHandler.LinkCodeDenied = function(_, err, description)
    linkFailed(description or err or "Access was denied")
  end
  grant.notifyHandler.LinkCodeExpired = function()
    linkFailed("The sign-in link expired")
  end
  grant.notifyHandler.ActivationTimeOut = function()
    linkFailed("The sign-in link expired")
  end
  grant.notifyHandler.MakeStateFailed = function(_, responseCode)
    linkFailed("Control4's sign-in service refused the request (" .. tostring(responseCode) .. ")")
  end
  grant.notifyHandler.RefreshTokenDeleted = function()
    self._onAuthChanged(false, "Signed out")
  end
  self.grant = grant
  return willRefresh == true
end

--- Start a sign-in: the link to open arrives through onLink.
--- @return boolean started False when the build cannot sign in.
function Client:link()
  if not self.grant then
    return false
  end
  self.grant:MakeState()
  return true
end

--- Forget the account's tokens.
function Client:unlink()
  if self.grant then
    self.grant:DeleteRefreshToken()
  end
end

--- @return boolean
function Client:isAuthenticated()
  return self.grant ~= nil and self.grant.ACCESS_TOKEN ~= nil
end

-- ─── Model translation ─────────────────────────────────────────────────────

--- v2 ThermostatModel → the drivers' device object.
--- @param m table
--- @return table
function Client.toDevice(m)
  m = type(m) == "table" and m or {}
  return {
    SerialNumber = m.serialNumber,
    Room = m.name or "",
    Online = m.online == true,
    Heating = m.isHeating == true,
    Temperature = m.currentTemperature,
    SetPointTemp = m.setPointTemperature,
    Mode = m.mode,
    HoldUntil = m.holdUntil,
    Error = m.errorState,
  }
end

--- The drivers' device object → the v2 Mode request that applies it: the path
--- and its body. Temperatures are absolute (temperatureType 0).
--- @param device table
--- @return string path
--- @return table body
function Client.toModeRequest(device)
  local mode = tonumber(device.Mode)
  if mode == Thermostat.MODE.AUTO then
    return "/api/v2/Mode/Auto", { serialNumber = device.SerialNumber }
  end
  local body = {
    serialNumber = device.SerialNumber,
    temperature = tonumber(device.SetPointTemp),
    temperatureType = 0,
  }
  if mode == Thermostat.MODE.MANUAL then
    return "/api/v2/Mode/Manual", body
  end
  if type(device.HoldUntil) == "string" and device.HoldUntil ~= "" then
    body.holdUntil = device.HoldUntil
  end
  return "/api/v2/Mode/Hold", body
end

-- ─── Requests ──────────────────────────────────────────────────────────────

--- An authenticated API request. Rejects with { message, code, retryAfter? }:
--- a 401 also asks the grant to refresh its token, and a 429 carries the
--- Retry-After seconds Nuheat sends.
--- @param method string
--- @param path string
--- @param body table|nil
--- @return Deferred<any, table>
function Client:_request(method, path, body)
  local d = deferred.new()
  if not self:isAuthenticated() then
    return d:reject({ message = "Not signed in to Nuheat" })
  end
  local headers = {
    ["Authorization"] = "Bearer " .. self.grant.ACCESS_TOKEN,
    ["Accept"] = "application/json",
  }
  local data
  if body ~= nil then
    headers["Content-Type"] = "application/json"
    data = JSON:encode(body)
  end
  http:request(method, constants.API_BASE .. path, data, headers):next(function(response)
    d:resolve(response.body)
  end, function(err)
    local code = type(err) == "table" and tonumber(err.code) or nil
    local result = { code = code, message = type(err) == "table" and err.error or tostring(err) }
    if code == 401 then
      log:info("Nuheat rejected the access token; refreshing it")
      self.grant:RefreshToken()
    elseif code == 429 then
      local responseHeaders = type(err) == "table" and err.headers or {}
      result.retryAfter = tonumber(responseHeaders["Retry-After"] or responseHeaders["retry-after"]) or 60
    end
    d:reject(result)
  end)
  return d
end

--- Every thermostat on the account.
--- @return Deferred<table[], table>
function Client:getThermostats()
  return self:_request("GET", "/api/v2/Thermostat"):next(function(list)
    local devices = {}
    for _, model in ipairs(type(list) == "table" and list or {}) do
      if type(model) == "table" and model.serialNumber ~= nil then
        devices[#devices + 1] = Client.toDevice(model)
      end
    end
    return devices
  end)
end

--- Write a device's mode and setpoint through the matching v2 Mode request.
--- Resolves with the device as written: the API answers 204 with no body, and
--- the cloud applies a write over seconds, so a read straight after would mostly
--- return the old state.
--- @param device table
--- @return Deferred<table, table>
function Client:setThermostat(device)
  local path, body = Client.toModeRequest(device)
  return self:_request("PUT", path, body):next(function()
    return device
  end)
end

return Client

--- Driver-wide constants for control4-nuheat.
local M = {}

--- Nuheat OpenAPI (North America) and its OAuth2 / OpenID identity server. v2
--- serves both Signature and Conductor; v1 serves Signature only.
M.API_BASE = "https://api.nam.mynuheat.com"
M.AUTH_ENDPOINT = "https://identity.nam.mynuheat.com/connect/authorize"
M.TOKEN_ENDPOINT = "https://identity.nam.mynuheat.com/connect/token"
M.SCOPES = { "openid", "openapi", "offline_access" }

--- Build secrets, substituted by tools/preprocess.py from .env / CI secrets (see
--- .env.default). Empty in a build that was given none.
M.CLIENT_ID = "__NUHEAT_CLIENT_ID__"
M.CLIENT_SECRET = "__NUHEAT_CLIENT_SECRET__"
M.C4_OAUTH_API_KEY = "__C4_OAUTH_API_KEY__"
M.C4_LINK_API_KEY = "__C4_LINK_API_KEY__"
--- "true" selects Control4's production OAuth redirect and short-link servers,
--- which take their own keys; anything else selects the development servers.
M.C4_OAUTH_PRODUCTION = "__C4_OAUTH_PRODUCTION__"

M.REDIRECT_URI_PROD = "https://apps.control4drivers.com/"
M.REDIRECT_URI_DEV = "https://apps.control4driversdev.com/"

--- C4:SetPropertyAttribs values used by lib.values / lib.utils for runtime
--- property visibility.
M.SHOW_PROPERTY = 0
M.HIDE_PROPERTY = 1

--- Dynamic-binding namespace for thermostat provider bindings on the account
--- driver (see lib.bindings). Keyed by thermostat serial number.
M.BINDING_NAMESPACE = "nuheat"

--- Proprietary connection class shared by the account (provider) and the
--- nuheat_thermostat companion (consumer). Must match the companion driver.xml.
M.THERMOSTAT_CLASS = "NUHEAT_THERMOSTAT"

--- Proxy commands exchanged across the account ↔ companion binding.
M.CMD = {
  --- account → companion: full thermostat object as {JSON=...}
  UPDATE_THERMOSTAT = "updateThermostat",
  --- account → companion: thermostat is gone / account unlinked
  GO_OFFLINE = "goOffline",
  --- companion → account: push mutated settings object as {JSON=...}
  SET_THERMOSTAT = "setThermostat",
  --- account → companion: link state for the app's extras, as
  --- { LINKED = "true"|"false", STATUS = text, LINK = sign-in link or "" }
  AUTH_STATUS = "authStatus",
  --- companion → account: a customer pressed Get Link in the app
  LINK_ACCOUNT = "linkAccount",
}

return M

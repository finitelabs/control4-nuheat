-- The thermostat companion's "Nuheat Account" extras, which let a customer link
-- the account from the Control4 app: the state the account sends becomes
-- EXTRAS_STATE_CHANGED, and Get Link is passed to the account.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_companion_extras.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/nuheat_thermostat/driver.lua"

local PROXY_BINDING = 5001
local ACCOUNT_BINDING = 5002

local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  table.insert(sends, { idBinding = idBinding, command = command, params = tParams })
end

dofile(DRIVER)

local function last(command)
  for i = #sends, 1, -1 do
    if sends[i].command == command then
      return sends[i]
    end
  end
end

--- The attributes of the object with `id` in an extras XML string.
local function object(xml, id)
  return xml:match('<object id="' .. id .. '"([^>]*)/>') or xml:match('<object[^>]-id="' .. id .. '"([^>]*)/>')
end

T.section("the section is described at startup")
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261024", model = "Nuheat Thermostat" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
OnDriverLateInit()
local setup = last("EXTRAS_SETUP_CHANGED")
local setupXml = setup and setup.params.XML or ""
T.contains("a Nuheat Account section", setupXml, '<section label="Nuheat Account">')
T.contains("with a Get Link button that sends LinkNuheatAccount", setupXml, 'command="LinkNuheatAccount"')
T.contains("and the link text object", setupXml, 'id="NuheatAuthLink"')

T.section("unlinked with a link waiting")
RFP.authStatus(ACCOUNT_BINDING, "authStatus", {
  LINKED = "false",
  STATUS = "Open the link to sign in to Nuheat",
  LINK = "https://identity.mynuheat.com/connect/authorize?client_id=x&state=y",
})
local state = last("EXTRAS_STATE_CHANGED")
T.eq("goes to the thermostat proxy", state and state.idBinding, PROXY_BINDING)
local xml = state and state.params.XML or ""
T.contains("shows the status", object(xml, "NuheatAccountStatus"), 'value="Open the link to sign in to Nuheat"')
T.contains("shows Get Link", object(xml, "LinkNuheatAccount"), 'hidden="False"')
T.contains("shows the link", object(xml, "NuheatAuthLink"), 'hidden="False"')
T.contains("with & escaped", object(xml, "NuheatAuthLink"), "client_id=x&amp;state=y")
T.excludes("and no bare &", xml, "x&state")

T.section("linked")
RFP.authStatus(ACCOUNT_BINDING, "authStatus", { LINKED = "true", STATUS = "Linked", LINK = "" })
xml = last("EXTRAS_STATE_CHANGED").params.XML
T.contains("shows Linked", object(xml, "NuheatAccountStatus"), 'value="Linked"')
T.contains("hides Get Link", object(xml, "LinkNuheatAccount"), 'hidden="True"')
T.contains("hides the link", object(xml, "NuheatAuthLink"), 'hidden="True"')

T.section("unlinked with no link yet")
RFP.authStatus(ACCOUNT_BINDING, "authStatus", { LINKED = "false", STATUS = "Signed out", LINK = "" })
xml = last("EXTRAS_STATE_CHANGED").params.XML
T.contains("shows Get Link", object(xml, "LinkNuheatAccount"), 'hidden="False"')
T.contains("hides the empty link", object(xml, "NuheatAuthLink"), 'hidden="True"')

T.section("the thermostat screen's banner follows the link state")
sends = {}
RFP.authStatus(ACCOUNT_BINDING, "authStatus", { LINKED = "false", STATUS = "Signed out", LINK = "" })
T.eq("unchanged while still unlinked, not re-sent", last("MESSAGE_CHANGED"), nil)
RFP.authStatus(ACCOUNT_BINDING, "authStatus", { LINKED = "true", STATUS = "Linked", LINK = "" })
local banner = last("MESSAGE_CHANGED")
T.eq("cleared once linked", banner and banner.params.MESSAGE, "")
T.eq("on the thermostat proxy", banner and banner.idBinding, PROXY_BINDING)
RFP.authStatus(ACCOUNT_BINDING, "authStatus", { LINKED = "false", STATUS = "Signed out", LINK = "" })
T.eq("points to Extras when unlinked", last("MESSAGE_CHANGED").params.MESSAGE, "Sign in to Nuheat from Extras")

T.section("Get Link goes to the account")
sends = {}
RFP.LinkNuheatAccount(PROXY_BINDING, "LinkNuheatAccount", {})
local press = last("linkAccount")
T.eq("over the account binding", press and press.idBinding, ACCOUNT_BINDING)
sends = {}
RFP.LinkNuheatAccount(ACCOUNT_BINDING, "LinkNuheatAccount", {})
T.eq("only from the proxy", last("linkAccount"), nil)

T.finish()

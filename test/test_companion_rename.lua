-- The thermostat companion names itself after its thermostat in the Nuheat app
-- while Auto Rename Driver is On, and leaves its name alone when it is Off.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_companion_rename.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/nuheat_thermostat/driver.lua"

local ACCOUNT_BINDING = 5002
local PROXY_ID = 401

C4.SendToProxy = function() end
C4.GetProxyDevicesById = function()
  return tostring(PROXY_ID)
end
local names = { [PROXY_ID] = "Nuheat Thermostat" }
local renames = 0
C4.GetDeviceDisplayName = function(_, deviceId)
  return names[deviceId]
end
C4.RenameDevice = function(_, deviceId, name)
  renames = renames + 1
  names[deviceId] = name
end
C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261029", model = "Nuheat Thermostat" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
Properties["Auto Rename Driver"] = "On"

dofile(DRIVER)

local function handoff(room)
  RFP.updateThermostat(ACCOUNT_BINDING, "updateThermostat", {
    JSON = JSON:encode({
      SerialNumber = "111",
      Room = room,
      SetPointTemp = 2333,
      Temperature = 2378,
      ScheduleMode = 1,
      Online = true,
      Heating = false,
    }),
  })
end

T.section("before any handoff")
OnDriverLateInit()
T.eq("the default name is kept", names[PROXY_ID], "Nuheat Thermostat")

T.section("a handoff names the driver")
handoff("Master Bathroom")
T.eq("Thermostat Name shows the Nuheat name", Properties["Thermostat Name"], "Master Bathroom")
T.eq("the proxy is renamed", names[PROXY_ID], "Master Bathroom")
handoff("Master Bathroom")
T.eq("only once", renames, 1)

T.section("a rename in the Nuheat app follows")
handoff("Primary Bath")
T.eq("renamed again", names[PROXY_ID], "Primary Bath")

T.section("a thermostat with no name")
handoff("")
T.eq("falls back to its serial", names[PROXY_ID], "Nuheat 111")

T.section("Off keeps a custom name")
Properties["Auto Rename Driver"] = "Off"
OnPropertyChanged("Auto Rename Driver")
names[PROXY_ID] = "Spa Floor"
handoff("Master Bathroom")
T.eq("not renamed", names[PROXY_ID], "Spa Floor")
T.eq("Thermostat Name still updates", Properties["Thermostat Name"], "Master Bathroom")

T.section("turning it back On renames now")
Properties["Auto Rename Driver"] = "On"
OnPropertyChanged("Auto Rename Driver")
T.eq("renamed", names[PROXY_ID], "Master Bathroom")

T.section("offline")
RFP.goOffline(ACCOUNT_BINDING, "goOffline")
names[PROXY_ID] = "Master Bathroom - REMOVED FROM NUHEAT"
OnPropertyChanged("Auto Rename Driver")
T.eq("a removed marker is left alone", names[PROXY_ID], "Master Bathroom - REMOVED FROM NUHEAT")

T.finish()

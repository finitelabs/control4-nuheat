# <span style="color:#FF0547">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

<!-- #ifdef DRIVERCENTRAL -->

### Added

- Added a `Support Code` property to the Nuheat and Nuheat Thermostat drivers. A
  code from Finite Labs support opens the driver's Lua tab in Composer for an
  hour; leave it blank otherwise.
- Added a `Cloud Monitoring` property, Enabled by default, and a
  `Diagnostics Snapshot` action to every driver. Cloud Monitoring sends Finite
  Labs an hourly report of the driver's memory use and a report of each error it
  hits; the documentation says what they hold.

<!-- #endif -->

### Fixed

- Fixed the Nuheat account unlinking, and every thermostat going offline until
  it was linked again, when Nuheat's sign-in service was too busy to renew the
  sign-in. The driver now waits and tries again, and the account stays linked.

<!-- #ifdef DRIVERCENTRAL -->

### Changed

- Changed Automatic Updates to one setting for the Nuheat driver and its Nuheat
  Thermostat drivers: changing it on any of them now changes it on all of them,
  so the drivers update together.

<!-- #endif -->

## v20261029 - 2026-10-29

### Added

- Thermostat drivers name themselves after the thermostat in the Nuheat app,
  including one added and bound by hand, and follow a rename there. Turn the new
  Auto Rename Driver property Off to keep a name of your own.

### Fixed

- The Authentication URL can be selected and copied in Composer Pro.

## v20261027 - 2026-10-27

### Added

- Initial release.
- Control for Nuheat Signature and Conductor floor-heating thermostats through
  the official Nuheat OpenAPI. An account driver links to your Nuheat account,
  and its Add Thermostats action adds a thermostat companion driver for each
  thermostat it finds, shown only in that thermostat's room.
- Sign-in on Nuheat's own page, so no password is entered in Control4. Link from
  Composer or the Control4 app's Extras, or send the homeowner a short sign-in
  link. The link survives reboots and driver updates.
- Native Control4 thermostat integration (ThermostatV2): floor temperature, heat
  setpoint, and Heat/Off mode, in °C or °F.
- Hold options (Until Next, Permanent).
- Floor temperature exposed as a temperature-value connection for other drivers.
- Account Linked and Account Not Linked programming events.
  <!-- #ifndef DRIVERCENTRAL -->
- Automatic driver updates via GitHub.
  <!-- #endif -->

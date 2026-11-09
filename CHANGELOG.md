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

- Added a Support Code property to the Nuheat and Nuheat Thermostat drivers,
  which lets Finite Labs support open the driver's Lua tab and its Trace and
  Ultra log levels for an hour
- Added Cloud Monitoring, Enabled by default, which sends Finite Labs each
  driver's memory use every hour and each error it hits, and a Diagnostics
  Snapshot action
- Added one Automatic Updates setting for the Nuheat driver and its thermostat
  drivers, so the drivers update together

<!-- #endif -->

### Fixed

- Fixed the Nuheat account unlinking, and its thermostats going offline, when
  Nuheat's sign-in service was too busy to renew the sign-in

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
- Native Control4 thermostat control of floor temperature, heat setpoint and
  Heat or Off mode, in °C or °F.
- Until Next and Permanent hold options.
- Floor temperature exposed as a temperature-value connection for other drivers.
- Account Linked and Account Not Linked programming events.
  <!-- #ifndef DRIVERCENTRAL -->
- Automatic driver updates via GitHub.
  <!-- #endif -->

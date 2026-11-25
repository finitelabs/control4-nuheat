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
  Ultra log levels for an hour.
- Added Cloud Monitoring, Enabled by default, which sends Finite Labs each
  driver's memory use every hour and each error it hits, and a Diagnostics
  Snapshot action.

<!-- #endif -->

### Fixed

- Fixed the Nuheat account unlinking, and its thermostats going offline, when
  Nuheat's sign-in service was too busy to renew the sign-in.

<!-- #ifdef DRIVERCENTRAL -->

### Changed

- Changed Automatic Updates to one setting for every Nuheat driver in the
  project, so the drivers update together.

<!-- #endif -->

## v20261029 - 2026-10-29

### Added

- Added automatic naming of thermostat drivers after their thermostat in the
  Nuheat app, including one added and bound by hand, and renaming them when the
  thermostat is renamed there. Turn the new Auto Rename Driver property Off to
  keep a name of your own.

### Fixed

- Fixed the Authentication URL so it can be selected and copied in Composer Pro.

## v20261027 - 2026-10-27

### Added

- Added the Nuheat and Nuheat Thermostat drivers.
- Added control for Nuheat Signature and Conductor floor-heating thermostats
  through the official Nuheat OpenAPI. An account driver links to your Nuheat
  account, and its Add Thermostats action adds a thermostat companion driver for
  each thermostat it finds, shown only in that thermostat's room.
- Added sign-in on Nuheat's own page, so no password is entered in Control4.
  Link from Composer or the Control4 app's Extras, or send the homeowner a short
  sign-in link. The link survives reboots and driver updates.
- Added native Control4 thermostat control of floor temperature, heat setpoint
  and Heat or Off mode, in °C or °F.
- Added Until Next and Permanent hold options.
- Added floor temperature as a temperature-value connection for other drivers.
- Added Account Linked and Account Not Linked programming events.
  <!-- #ifndef DRIVERCENTRAL -->
- Added automatic driver updates via GitHub.
  <!-- #endif -->

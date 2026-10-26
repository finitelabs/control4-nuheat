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

### Added

- **Nuheat** account driver. Links to a Nuheat account through the official
  Nuheat OpenAPI, with sign-in on Nuheat's own page so no password is entered in
  Control4, and stays linked through reboots and updates. Discovers the
  account's Signature and Conductor thermostats and polls them.
- **Nuheat Thermostat** companion. Presents a thermostat as a native Control4
  thermostat: floor temperature, heat setpoint, Heat/Off, and Until Next /
  Permanent holds, in °C or °F, with the floor temperature also offered as a
  temperature connection.
- Linking from Composer or the Control4 app's Extras, with a short sign-in link
  the integrator can send to the homeowner.
- **Add Thermostats** action: adds, connects and names a companion per
  thermostat and shows each only in its own room.
- **Account Linked** and **Account Not Linked** events for programming.
  <!-- #ifndef DRIVERCENTRAL -->
- Automatic updates from GitHub releases.
  <!-- #endif -->

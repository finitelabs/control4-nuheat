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

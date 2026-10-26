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
- A **Nuheat** account driver that links to a Nuheat account through the Nuheat
  OpenAPI. The homeowner signs in on Nuheat's own page, so their password is
  never entered in Control4. It discovers the account's Signature and Conductor
  thermostats and polls them on a configurable interval, reading a change back a
  few seconds after it is sent.
- Linking by sign-in link: the **Link Account** action shows a short link, valid
  for ten minutes, that the integrator can send to the homeowner. The driver
  stays linked through reboots and updates until it is unlinked.
- Linking from the Control4 app: each thermostat's **Extras** show whether the
  account is linked and offer **Get Link** when it isn't, and the thermostat
  screen says "Sign in to Nuheat from Extras" until it is.
- An **Add Thermostats** action that adds a **Nuheat Thermostat** driver for
  every thermostat on the account, connects it, names it after the thermostat,
  places it in the room its Nuheat name matches (or the account driver's room),
  and shows it in that room only. A driver whose thermostat leaves the account
  is renamed so it can be found and removed.
- **Account Linked** and **Account Not Linked** events for programming, for
  example to notify the integrator when the sign-in is lost.
- A **Nuheat Thermostat** companion driver that presents each thermostat as a
  native Control4 thermostat: floor temperature, heat setpoint, Heat/Off (Off is
  Nuheat's Standby), and Until Next / Permanent holds, in Celsius or Fahrenheit
  as the project uses. The floor temperature is also offered as a temperature
  connection for other drivers.

<!-- #ifndef DRIVERCENTRAL -->

- Automatic updates from GitHub releases.

<!-- #endif -->

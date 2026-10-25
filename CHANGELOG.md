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
  OpenAPI (sign-in on Nuheat's own page, no password in Control4), discovers its
  Signature and Conductor thermostats, and polls them on a configurable
  interval.
- A **Nuheat Thermostat** companion driver that presents each thermostat as a
  native Control4 thermostat: floor temperature, heat setpoint, Heat/Off, and
  Until Next / Permanent holds.
- Linking the account from the Control4 app with **Get Link** in a thermostat's
  extras, including before anything is bound: a dealer can install the drivers
  and leave the sign-in to the customer, and a single thermostat is bound to a
  single unbound thermostat driver automatically.

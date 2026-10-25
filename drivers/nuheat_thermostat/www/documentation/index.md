<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="Nuheat Thermostat" src="./images/header.png" width="275"/>

______________________________________________________________________

# <span style="color:#FF0547">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Nuheat-Systems.

<!-- #endif -->

This driver represents a single Nuheat floor-heating thermostat as a native
Control4 thermostat, through the Control4 ThermostatV2 proxy. It does not talk
to the cloud itself. It binds to the **Nuheat** account driver, which hands it
the device and its live state. The driver adapts its capabilities (heat-only,
heat setpoint, temperature range) to the device it is given.

# <span style="color:#FF0547">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
  - [Connections](#connections)
- [Schedules and Holds](#schedules-and-holds)
- [Linking from the Control4 App](#linking-from-the-control4-app)

<!-- #ifdef DRIVERCENTRAL -->

- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#FF0547">System Requirements</span>

- Control4 OS 3.3.0 or later
- A configured **Nuheat** account driver in the same project, signed in and
  reporting at least one thermostat

# <span style="color:#FF0547">Features</span>

- Native Control4 ThermostatV2 proxy integration
- Current floor temperature, heat setpoint, and Heat/Off mode
- Hold options (Until Next, Permanent)
- Floor temperature exposed as a temperature-value connection for other drivers
- Temperature values communicated in Celsius, with the Control4 proxy handling
  display conversion to the project's configured scale

# <span style="color:#FF0547">Compatibility</span>

Works with any Nuheat Signature or Conductor thermostat discovered by the
**Nuheat** account driver. Nuheat is heat-only, so cooling and dual-setpoint
capabilities are not advertised. The heat setpoint ranges from 5 to 40 °C (41 to
104 °F).

# <span style="color:#FF0547">Installer Setup</span>

Refer to the main **Nuheat** account driver documentation for linking the
account. Once the account driver is linked, its **Add Thermostats** action adds
and binds one of these drivers per thermostat, so you usually don't add this
driver yourself.

## Adding the Driver

To add one by hand instead:

1. In Composer Pro, add the **Nuheat Thermostat** driver to your project.
1. In the "Connections" tab, bind this driver's **Nuheat Thermostat** connection
   to the thermostat exposed by the **Nuheat** account driver.
1. The driver automatically synchronizes its state and capabilities once bound.
   The **Serial ID** property shows which thermostat it is bound to.

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status (e.g. `Online`, `Offline`, or
`Waiting for thermostat`).

#### Driver Version (read-only)

Displays the current version of the driver.

#### Serial ID (read-only)

The serial number of the Nuheat thermostat this driver is bound to.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

## Connections

### Thermostat (provider)

The Control4 ThermostatV2 proxy connection, automatically managed by the driver.
Program against this like any Control4 thermostat.

### Nuheat Thermostat (consumer)

Bind this to a thermostat exposed by the **Nuheat** account driver. This is how
the driver receives its device and live state.

### Temperature (provider)

Outputs the thermostat's current floor temperature to other Control4 drivers via
a `TEMPERATURE_VALUE` connection (both Celsius and Fahrenheit).

# <span style="color:#FF0547">Schedules and Holds</span>

The thermostat runs its own weekly schedule, which is managed in the Nuheat app:
the Nuheat OpenAPI does not offer schedule editing, so it is not shown in
Control4.

Setting a temperature in Control4 holds it until the next schedule event, or
keeps a permanent hold at the new temperature if one is active. The hold mode
can also be set directly: **Until Next**, **Permanent**, or **Off** to resume
the schedule. Switching the HVAC mode back to **Heat** resumes the schedule.

**Permanent** is the thermostat's Manual mode, which holds until something
changes it. **Off** is Standby: Manual at 5 °C (41 °F), which the Nuheat app
shows as Standby. Setting a temperature from Standby holds it until the next
schedule event.

# <span style="color:#FF0547">Linking from the Control4 App</span>

The thermostat's extras in the Control4 app have a **Nuheat Account** section
showing whether the account is linked. If it is not (after **Unlink Account**,
or if Nuheat stops accepting the sign-in), the section shows a **Get Link**
button: press it, then open the link it shows in a browser within five minutes
and sign in to Nuheat. The account driver picks up the sign-in and every
thermostat reconnects. While the account is not linked, the thermostat screen
shows "Sign in to Nuheat from Extras".

The first link is started from the account driver's **Link Account** action,
since this driver is only added once the account driver has found the
thermostats. The integrator can send that link to the homeowner to sign in.

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#FF0547">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://drivercentral.io/platforms/control4-drivers/utility/nuheat

<!-- #endif -->

# <span style="color:#FF0547">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4, you
can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-nuheat/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->

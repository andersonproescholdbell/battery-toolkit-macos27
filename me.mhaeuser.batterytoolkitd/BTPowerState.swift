//
// Copyright (C) 2022 - 2024 Marvin Häuser. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//

import Foundation
import os.log

@MainActor
internal enum BTPowerState {
    private static var chargingDisabled = false
    private static var powerDisabled = false

    static func initState() {
        let chargingDisabled = SMCComm.Power.isChargingDisabled()
        self.chargingDisabled = chargingDisabled
        if !chargingDisabled, case .legacy = SMCComm.Power.backend {
            //
            // Sleep must always be disabled when charging is enabled, unless
            // the system itself is holding the limit.
            //
            GlobalSleep.disable()
        }

        let powerDisabled = SMCComm.Power.powerAdapterSupported &&
            SMCComm.Power.isPowerAdapterDisabled()
        self.powerDisabled = powerDisabled
        if powerDisabled {
            //
            // Sleep must be disabled when external power is disabled.
            //
            self.disableAdapterSleep()
        }

        SMCComm.MagSafe.prepare()

        if BTSettings.magSafeSync {
            self.syncMagSafeState()
        }
    }

    static func refreshState() {
        //
        // Refresh platform stated when waking from sleep, as events might not
        // fire.
        //
        let chargingDisabled = SMCComm.Power.isChargingDisabled()
        if chargingDisabled != self.chargingDisabled {
            self.chargingDisabled = chargingDisabled

            if chargingDisabled {
                GlobalSleep.restore()
            } else if case .legacy = SMCComm.Power.backend {
                GlobalSleep.disable()
            }
        }

        //
        // The system limit is shared with System Settings, so reassert it if
        // something else raised it while we believe charging is held.
        //
        // Only a ceiling above the target is worth correcting: as the battery
        // discharges the guard naturally leaves the ceiling above the current
        // charge, and rewriting on every refresh would post a notification and
        // poll the agent each time for no gain.
        //
        if case .mcl = SMCComm.Power.backend, self.chargingDisabled {
            let (percent, _, _) = self.getPercentRemaining()
            let target = Int(max(BTSettings.maxCharge, percent))
            if let limit = SystemChargeLimit.agentLimit(), limit > target {
                _ = SMCComm.Power.setChargingLimit(
                    limit: BTSettings.maxCharge,
                    currentPercent: percent
                )
            }
        }

        let powerDisabled = SMCComm.Power.isPowerAdapterDisabled()
        if powerDisabled != self.powerDisabled {
            self.powerDisabled = powerDisabled

            if powerDisabled {
                self.disableAdapterSleep()
            } else {
                self.restoreAdapterSleep()
            }
        }

        if BTSettings.magSafeSync {
            self.syncMagSafeState()
        }
    }

    static func getPercentRemaining() -> (UInt8, Bool, Bool) {
        return IOPSPrivate.GetPercentRemaining() ?? (100, false, false)
    }

    static func adapterSleepSettingToggled() {
        //
        // If power is disabled, toggle sleep.
        //
        guard self.powerDisabled else {
            return
        }

        if !BTSettings.adapterSleep {
            GlobalSleep.disable()
        } else {
            GlobalSleep.restore()
        }
    }

    static func syncMagSafeStatePowerEnabled(percent: UInt8) {
        assert(BTSettings.magSafeSync)
        assert(!self.powerDisabled)

        if percent == 100 {
            _ = SMCComm.MagSafe.setGreen()
        } else if self.chargingDisabled {
            _ = SMCComm.MagSafe.setOrange()
        } else {
            _ = SMCComm.MagSafe.setOrangeSlowBlink()
        }
    }

    static func syncMagSafeState() {
        assert(BTSettings.magSafeSync)

        if self.powerDisabled {
            _ = SMCComm.MagSafe.setOff()
        } else {
            let (percent, _, _) = self.getPercentRemaining()
            self.syncMagSafeStatePowerEnabled(percent: percent)
        }
    }

    static func magSafeSyncSettingToggled() {
        if BTSettings.magSafeSync {
            self.syncMagSafeState()
        } else {
            _ = SMCComm.MagSafe.setSystem()
        }
    }

    static func disableCharging(percent: UInt8) -> Bool {
        guard !self.chargingDisabled else {
            return true
        }

        let success: Bool
        switch SMCComm.Power.backend {
        case .legacy:
            success = SMCComm.Power.disableCharging()

        case .mcl:
            //
            // Arm the ceiling at the configured maximum. The guard keeps it
            // from landing below the current charge, which would make the Mac
            // discharge from wall power to reach it.
            //
            success = SMCComm.Power.setChargingLimit(
                limit: BTSettings.maxCharge,
                currentPercent: percent
            )
        }

        guard success else {
            os_log("Failed to disable charging")
            return false
        }

        self.chargingDisabled = true

        if BTSettings.magSafeSync {
            BTPowerState.syncMagSafeStatePowerEnabled(percent: percent)
        }

        GlobalSleep.restore()

        return true
    }

    static func enableCharging(percent: UInt8) -> Bool {
        guard self.chargingDisabled else {
            return true
        }

        let success = SMCComm.Power.enableCharging()
        if !success {
            os_log("Failed to enable charging")
            return false
        }

        //
        // Only the legacy backend needs the machine awake: it drives every
        // transition itself, while powerd keeps the limit through sleep.
        //
        if case .legacy = SMCComm.Power.backend {
            GlobalSleep.disable()
        }

        self.chargingDisabled = false

        if BTSettings.magSafeSync {
            BTPowerState.syncMagSafeStatePowerEnabled(percent: percent)
        }

        return true
    }

    static func disablePowerAdapter() -> Bool {
        //
        // macOS 27 removed the adapter keys. Inhibiting the adapter there would
        // mean running the Mac off its battery, which cycles it for no benefit,
        // so the feature is refused rather than approximated.
        //
        guard SMCComm.Power.powerAdapterSupported else {
            os_log("Power adapter control is unavailable on this Mac")
            return false
        }

        guard !self.powerDisabled else {
            return true
        }

        self.disableAdapterSleep()

        let success = SMCComm.Power.disablePowerAdapter()
        guard success else {
            os_log("Failed to disable power adapter")
            self.restoreAdapterSleep()
            return false
        }

        if BTSettings.magSafeSync {
            _ = SMCComm.MagSafe.setOff()
        }

        self.powerDisabled = true
        return true
    }

    static func enablePowerAdapter() -> Bool {
        guard self.powerDisabled else {
            return true
        }

        let success = SMCComm.Power.enablePowerAdapter()
        guard success else {
            os_log("Failed to enable power adapter")
            return false
        }

        self.powerDisabled = false

        if BTSettings.magSafeSync {
            let (percent, _, _) = self.getPercentRemaining()
            BTPowerState.syncMagSafeStatePowerEnabled(percent: percent)
        }

        self.restoreAdapterSleep()

        return true
    }

    static func isChargingDisabled() -> Bool {
        return self.chargingDisabled
    }

    static func isPowerAdapterDisabled() -> Bool {
        return self.powerDisabled
    }

    private static func disableAdapterSleep() {
        if !BTSettings.adapterSleep {
            GlobalSleep.disable()
        }
    }

    private static func restoreAdapterSleep() {
        if !BTSettings.adapterSleep {
            GlobalSleep.restore()
        }
    }
}

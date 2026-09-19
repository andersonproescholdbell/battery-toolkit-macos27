//
// Copyright (C) 2022 - 2025 Marvin Häuser. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//

import Foundation
import os.log

public extension SMCComm {
    @MainActor
    enum Power {
        //
        // How charging is controlled on this machine.
        //
        // macOS 27 removed the SMC charge-inhibit keys, leaving the system's
        // own manual charge limit as the only lever. See SystemChargeLimit.
        //
        enum Backend {
            case legacy
            case mcl
        }

        private static let chargeKeys = [
            KeyControl.CHTE,
            KeyControl.CH0C
        ]
        private static let adapterKeys = [
            KeyControl.CHIE,
            KeyControl.CH0J
        ]

        private static var chargeKey = 0
        //
        // Optional: a machine that still limits charging but has lost its
        // adapter key is supported, it just cannot force-discharge.
        //
        private static var adapterKey: Int?

        private(set) static var backend = Backend.legacy

        static func supported() -> Bool {
            //
            // Ensure all required SMC keys are present and well-formed.
            //
            let chargeKey = self.chargeKeys.firstIndex { key in
                SMCComm.keySupported(keyInfo: key.keyInfo)
            }

            self.adapterKey = self.adapterKeys.firstIndex { key in
                SMCComm.keySupported(keyInfo: key.keyInfo)
            }

            if let chargeKey = chargeKey {
                self.chargeKey = chargeKey
                self.backend = .legacy
                return true
            }

            //
            // No inhibit key: fall back to the system charge limit, which is
            // what macOS 27 itself uses.
            //
            SystemChargeLimit.prepare()
            guard SystemChargeLimit.supported, MCLPreflight.run().passed else {
                return false
            }

            self.backend = .mcl
            return true
        }

        static func enableCharging() -> Bool {
            switch self.backend {
            case .legacy:
                return SMCComm.writeKey(
                    key: self.chargeKeys[self.chargeKey].keyInfo.key,
                    bytes: self.chargeKeys[self.chargeKey].onBytes
                )

            case .mcl:
                //
                // A ceiling of 100 is the closest equivalent to lifting the
                // inhibit: the firmware charges all the way up again.
                //
                return self.setSystemLimit(100)
            }
        }

        static func disableCharging() -> Bool {
            switch self.backend {
            case .legacy:
                return SMCComm.writeKey(
                    key: self.chargeKeys[self.chargeKey].keyInfo.key,
                    bytes: self.chargeKeys[self.chargeKey].offBytes
                )

            case .mcl:
                //
                // Without a target the only safe ceiling is the current charge,
                // which holds the level without provoking a drain.
                //
                let percent = IOPSPrivate.GetPercentRemaining()?.0 ?? 100
                return self.setChargingLimit(
                    limit: percent,
                    currentPercent: percent
                )
            }
        }

        //
        // Applies a ceiling without ever placing it below the current charge.
        //
        // The manualChargeLimit policy carries drain: true, so a ceiling below
        // the current level makes the Mac discharge from wall power to reach
        // it. Holding at the current level instead lets the ceiling follow the
        // charge down as it is used.
        //
        static func setChargingLimit(limit: UInt8, currentPercent: UInt8) -> Bool {
            guard case .mcl = self.backend else {
                return false
            }

            return self.setSystemLimit(Int(max(limit, currentPercent)))
        }

        private static func setSystemLimit(_ percent: Int) -> Bool {
            do {
                try SystemChargeLimit.setLimit(percent)
                return true
            } catch {
                os_log("Failed to set system charge limit: \(error.localizedDescription)")
                return false
            }
        }

        static func isChargingDisabled() -> Bool {
            switch self.backend {
            case .legacy:
                let value = SMCComm.readKey(
                    key: self.chargeKeys[self.chargeKey].keyInfo.key,
                    dataSize: self.chargeKeys[self.chargeKey].onBytes.count
                )
                guard let value else {
                    return false
                }

                return value != self.chargeKeys[self.chargeKey].onBytes

            case .mcl:
                //
                // Charging is held whenever the battery has reached the ceiling
                // the system is applying.
                //
                guard let limit = SystemChargeLimit.agentLimit(),
                      let (percent, _, _) = IOPSPrivate.GetPercentRemaining()
                else {
                    return false
                }

                return Int(percent) >= limit
            }
        }

        static var powerAdapterSupported: Bool {
            return self.adapterKey != nil
        }

        static func enablePowerAdapter() -> Bool {
            guard let adapterKey = self.adapterKey else {
                return false
            }

            return SMCComm.writeKey(
                key: self.adapterKeys[adapterKey].keyInfo.key,
                bytes: self.adapterKeys[adapterKey].onBytes
            )
        }

        static func disablePowerAdapter() -> Bool {
            guard let adapterKey = self.adapterKey else {
                return false
            }

            return SMCComm.writeKey(
                key: self.adapterKeys[adapterKey].keyInfo.key,
                bytes: self.adapterKeys[adapterKey].offBytes
            )
        }

        static func isPowerAdapterDisabled() -> Bool {
            guard let adapterKey = self.adapterKey else {
                return false
            }

            let value = SMCComm.readKey(
                key: self.adapterKeys[adapterKey].keyInfo.key,
                dataSize: self.adapterKeys[adapterKey].onBytes.count
            )
            guard let value else {
                return false
            }

            return value != self.adapterKeys[adapterKey].onBytes
        }
    }
}

private extension SMCComm.Power {
    private enum Keys {
        static let CHTE = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "T", "E"),
            info: SMCComm.KeyInfoData(
                dataSize: 4,
                dataType: SMCComm.KeyTypes.ui32,
                dataAttributes: 0xD4
            )
        )
        static let CH0C = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "0", "C"),
            info: SMCComm.KeyInfoData(
                dataSize: 1,
                dataType: SMCComm.KeyTypes.hex,
                dataAttributes: 0xD4
            )
        )
        static let CHIE = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "I", "E"),
            info: SMCComm.KeyInfoData(
                dataSize: 1,
                dataType: SMCComm.KeyTypes.hex,
                dataAttributes: 0xD4
            )
        )
        static let CH0J = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "0", "J"),
            info: SMCComm.KeyInfoData(
                dataSize: 1,
                dataType: SMCComm.KeyTypes.ui8,
                dataAttributes: 0xD4
            )
        )
    }
    
    private struct KeyControl {
        let keyInfo: SMCComm.KeyInfo
        let onBytes: [UInt8]
        let offBytes: [UInt8]

        static let CHTE = KeyControl(
            keyInfo: Keys.CHTE,
            onBytes: [0x00, 0x00, 0x00, 0x00],
            offBytes: [0x01, 0x00, 0x00, 0x00]
        )
        static let CH0C = KeyControl(
            keyInfo: Keys.CH0C,
            onBytes: [0x00],
            offBytes: [0x01]
        )
        static let CHIE = KeyControl(
            keyInfo: Keys.CHIE,
            onBytes: [0x00],
            offBytes: [0x08]
        )
        static let CH0J = KeyControl(
            keyInfo: Keys.CH0J,
            onBytes: [0x00],
            offBytes: [0x20]
        )
    }
}

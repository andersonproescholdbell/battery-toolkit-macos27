//
// Copyright (C) 2022 - 2024 Marvin Häuser. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//

import BTPreprocessor
import Foundation
import os.log

internal enum BTDaemonManagement {
    /// How long to wait for the daemon to identify itself before assuming it is
    /// not installed.
    ///
    /// When the daemon's Mach service is absent - after `launchctl bootout`, or
    /// before the first registration - the XPC reply and the error handler can
    /// both stay silent, leaving the continuation suspended forever. The app
    /// would then never reach `daemonStatusHandler`, so it shows no menu bar
    /// item and no error at all.
    private static let uniqueIdTimeoutNanoseconds: UInt64 = 5 * 1_000_000_000

    @BTBackgroundActor static func start() async -> BTDaemonManagement.Status {
        let daemonId = await self.uniqueIdOrTimeout()
        guard self.daemonUpToDate(daemonId: daemonId) else {
            if #available(macOS 13.0, *) {
                return await self.Service.register()
            } else {
                return await self.Legacy.register()
            }
        }

        os_log("Daemon is up-to-date, skip install")
        return .enabled
    }

    /// The daemon's unique ID, or nil if it does not answer in time.
    @BTBackgroundActor private static func uniqueIdOrTimeout() async -> Data? {
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                return try? await BTDaemonXPCClient.getUniqueId()
            }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: self.uniqueIdTimeoutNanoseconds
                )
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()

            if result == nil {
                os_log("Daemon did not identify itself, assuming not installed")
            }

            return result
        }
    }

    @BTBackgroundActor static func upgrade() async -> BTDaemonManagement.Status {
        if #available(macOS 13.0, *) {
            return await self.Service.upgrade()
        } else {
            //
            // There is no upgrade path to legacy daemons.
            //
            assertionFailure()
            return .notRegistered
        }
    }

    static func approve(timeout: UInt8) async throws {
        if #available(macOS 13.0, *) {
            try await self.Service.approve(timeout: timeout)
        } else {
            //
            // Approval is exclusive to SMAppService daemons.
            //
            assertionFailure()
        }
    }

    @BTBackgroundActor static func remove() async throws {
        let authData = try await BTAppXPCClient.getDaemonAuthorization()

        _ = try await BTDaemonXPCClient.prepareDisable(authData: authData)
        if #available(macOS 13.0, *) {
            try await self.Service.unregister()
        } else {
            let simpleAuth = SimpleAuth.fromData(authData: authData)
            guard let simpleAuth else {
                throw BTError.notAuthorized
            }

            self.Legacy.unregister(simpleAuth: simpleAuth)
        }
    }

    private static func daemonUpToDate(daemonId: Data?) -> Bool {
        guard let daemonId else {
            os_log("Daemon unique ID is nil")
            return false
        }

        let bundleId = CSIdentification.getBundleRelativeUniqueId(
            relative: "Contents/Library/LaunchServices/" + BT_DAEMON_ID
        )
        guard let bundleId else {
            os_log("Bundle daemon unique ID is nil")
            return false
        }

        return bundleId == daemonId
    }
}

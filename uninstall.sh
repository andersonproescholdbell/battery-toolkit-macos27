#!/bin/sh

##
# Uninstalls Battery Toolkit and its settings.
#
# Copyright (C) 2022 Marvin Häuser. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
##

# Remove the Battery Toolkit daemon.
sudo rm /Library/LaunchDaemons/io.github.andersonproescholdbell.batterytoolkitd.plist
sudo rm /Library/PrivilegedHelperTools/io.github.andersonproescholdbell.batterytoolkitd
sudo launchctl remove io.github.andersonproescholdbell.batterytoolkitd

# Remove the Battery Toolkit daemon data.
sudo defaults delete io.github.andersonproescholdbell.batterytoolkitd
sudo security authorizationdb remove io.github.andersonproescholdbell.batterytoolkitd.manage

# Remove the Battery Toolkit Autostart helper.
launchctl remove io.github.andersonproescholdbell.BatteryToolkitAutostart

# Remove the Battery Toolkit app data.
defaults remove io.github.andersonproescholdbell.BatteryToolkit

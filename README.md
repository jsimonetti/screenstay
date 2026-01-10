# ScreenStay

ScreenStay is a macOS menu bar application that organizes your workspace by automatically managing window positions based on display configurations and user-defined regions.

## Overview

ScreenStay allows you to create profiles that match your display setup and define rectangular regions where specific applications should be positioned. The app automatically detects when displays are connected or disconnected and switches to the appropriate profile.

## Features

### Profile-Based Configuration

Create multiple profiles, each associated with a specific display topology. A profile contains:

- Display topology fingerprint for automatic matching
- One or more rectangular regions for window placement
- Application assignments for each region
- Optional keyboard shortcuts for region focus

### Automatic Profile Switching

When you connect or disconnect displays, ScreenStay automatically detects the change and activates the matching profile. This ensures your window layout adapts to your current display configuration without manual intervention.

### Region-Based Window Management

Define rectangular regions on any display where applications should be positioned. Each region can:

- Be assigned multiple applications by bundle identifier
- Have customizable padding from edges
- Include a keyboard shortcut for quick focus cycling
- Be visually edited using an interactive overlay

### Keyboard Shortcuts

Assign keyboard shortcuts to regions to cycle focus between windows in that region. Shortcuts support modifier keys (Command, Option, Control, Shift) combined with any standard key.

### Configuration Interface

The Settings window provides a graphical interface for:

- Creating and deleting profiles
- Capturing current display topology
- Managing regions within each profile
- Assigning applications to regions
- Configuring keyboard shortcuts
- Adjusting global settings

### Display Topology Matching

ScreenStay identifies display configurations using a position-independent fingerprint based on display type (built-in vs external) and resolution. This ensures profiles match correctly regardless of physical display arrangement in System Settings.

## Requirements

- macOS 15.0 or later
- Accessibility permissions (required for window management)
- Input Monitoring permissions (required for keyboard shortcuts)

## Configuration

Configuration is stored in JSON format at:

```
~/Library/Application Support/ScreenStay/config.json
```

The configuration file contains:

- List of profiles with display topologies and regions
- Global settings for automatic profile switching and window repositioning
- Application assignments and keyboard shortcut definitions

## Menu Bar Controls

The menu bar icon provides access to:

- **Profiles**: Quick switching between configured profiles
- **Settings**: Open the configuration window
- **Reload Config**: Reload configuration from disk
- **Logs**: View application logs
- **Clear Logs**: Clear the log file
- **Quit ScreenStay**: Exit the application

## Permissions

ScreenStay requires two system permissions:

1. **Accessibility**: Required to read window information and reposition windows
2. **Input Monitoring**: Required to capture keyboard shortcuts

The app will prompt for these permissions on first launch. You can also grant them manually in System Settings under Privacy & Security.

## Logs

Application logs are stored at:

```
~/Library/Logs/ScreenStay/screenstay.log
```

Logs can be accessed through the menu bar (Logs option) or cleared when needed (Clear Logs option).

## How It Works

1. Create a profile for your current display configuration
2. Define regions on your displays where windows should be positioned
3. Assign applications to each region by bundle identifier
4. Optionally assign keyboard shortcuts to regions for quick focus cycling
5. ScreenStay automatically repositions windows when applications launch
6. When displays change, ScreenStay switches to the matching profile

## Region Overlay

The interactive region overlay allows you to:

- View all regions in the active profile
- Drag regions to reposition them
- Resize regions by dragging edges or corners
- Press ESC to save changes and close the overlay

## Focus Cycling

When you trigger a keyboard shortcut assigned to a region, ScreenStay cycles focus between all windows currently in that region. This provides a quick way to navigate between applications without using the mouse or Command-Tab.

## License

Copyright 2026. All rights reserved.

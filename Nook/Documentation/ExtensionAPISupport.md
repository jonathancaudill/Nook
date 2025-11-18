# Extension API Support Documentation

## Overview

This document describes the Chrome Extension APIs supported by Nook, their implementation status, and any known limitations.

## Fully Supported APIs

### chrome.tabs
- `chrome.tabs.query()` - Query tabs with various filters
- `chrome.tabs.get()` - Get tab information
- `chrome.tabs.create()` - Create new tabs
- `chrome.tabs.update()` - Update tab properties
- `chrome.tabs.remove()` - Close tabs
- `chrome.tabs.reload()` - Reload tabs
- `chrome.tabs.goBack()` - Navigate back
- `chrome.tabs.goForward()` - Navigate forward
- `chrome.tabs.duplicate()` - Duplicate tabs
- `chrome.tabs.captureVisibleTab()` - Capture tab screenshots

### chrome.windows
- `chrome.windows.get()` - Get window information
- `chrome.windows.getAll()` - Get all windows
- `chrome.windows.create()` - Create new windows
- `chrome.windows.update()` - Update window properties
- `chrome.windows.remove()` - Close windows

### chrome.storage
- `chrome.storage.local` - Local storage API
- `chrome.storage.sync` - Sync storage API (limited support)

### chrome.runtime
- `chrome.runtime.sendMessage()` - Send one-time messages
- `chrome.runtime.connect()` - Create persistent message ports
- `chrome.runtime.onMessage` - Listen for messages
- `chrome.runtime.onConnect` - Listen for connections
- `chrome.runtime.getURL()` - Get extension URLs

### chrome.action
- `chrome.action.setIcon()` - Set action icon
- `chrome.action.setTitle()` - Set action title
- `chrome.action.setBadgeText()` - Set badge text
- `chrome.action.setBadgeBackgroundColor()` - Set badge color
- `chrome.action.onClicked` - Listen for action clicks
- `chrome.action.setPopup()` - Set popup HTML

### chrome.commands
- `chrome.commands.getAll()` - Get all commands
- `chrome.commands.onCommand` - Listen for command execution

### chrome.contextMenus
- `chrome.contextMenus.create()` - Create context menu items
- `chrome.contextMenus.remove()` - Remove context menu items
- `chrome.contextMenus.onClicked` - Listen for menu item clicks

### chrome.permissions
- `chrome.permissions.request()` - Request permissions
- `chrome.permissions.remove()` - Remove permissions
- `chrome.permissions.contains()` - Check permission status
- `chrome.permissions.getAll()` - Get all permissions

### chrome.scripting
- `chrome.scripting.executeScript()` - Execute scripts in tabs
- `chrome.scripting.insertCSS()` - Insert CSS in tabs
- `chrome.scripting.removeCSS()` - Remove CSS from tabs

## Partially Supported APIs

### chrome.storage.sync
- Limited support - sync storage may not persist across devices

### chrome.identity
- `chrome.identity.launchWebAuthFlow()` - OAuth flow support (requires native implementation)

### chrome.notifications
- Basic notification support (platform-specific limitations)

## Known Limitations

1. **Platform Differences**: Some APIs behave differently on macOS compared to Chrome
2. **Storage Limits**: Storage quotas may differ from Chrome
3. **Network Requests**: Some network request APIs may have different CORS behavior
4. **File System**: File system access is more restricted on macOS

## Extension Developer Guidelines

### Manifest Requirements

- Minimum `manifest_version`: 3
- Required fields: `name`, `version`, `manifest_version`
- Optional but recommended: `description`, `icons`, `permissions`

### Best Practices

1. **Permissions**: Request only the permissions you need
2. **Content Scripts**: Use isolated worlds when possible
3. **Background Scripts**: Use service workers for Manifest V3
4. **Error Handling**: Always handle errors gracefully
5. **Testing**: Test extensions on macOS before distribution

### Debugging Tips

1. Use `chrome.runtime.lastError` to check for errors
2. Enable extension inspection in Nook settings
3. Check console logs for extension errors
4. Use Web Inspector for debugging extension pages

## Migration Guide

### From Chrome to Nook

1. **Test Compatibility**: Test your extension in Nook
2. **Check Permissions**: Verify all permissions work as expected
3. **Update Icons**: Ensure icons display correctly
4. **Test Native Messaging**: If using native messaging, verify handlers are registered
5. **Check Storage**: Verify storage APIs work correctly

### Common Issues

1. **Permission Denied**: Some permissions may require user approval
2. **Icon Not Displaying**: Check icon paths and formats
3. **Message Port Errors**: Verify native message handlers are registered
4. **Storage Errors**: Check storage quotas and permissions

## Testing Checklist

- [ ] Extension installs successfully
- [ ] Extension loads without errors
- [ ] All permissions work correctly
- [ ] Action button displays and works
- [ ] Context menus appear and function
- [ ] Commands execute correctly
- [ ] Storage APIs work
- [ ] Native messaging works (if used)
- [ ] Error handling works correctly
- [ ] Extension uninstalls cleanly

## Support

For issues or questions, please refer to the Nook documentation or file an issue on the project repository.


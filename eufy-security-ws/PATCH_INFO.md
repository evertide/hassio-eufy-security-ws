# Eufy Security Client Runtime Patches

This add-on applies runtime patches to the `eufy-security-client` npm package to fix issues and add diagnostic capabilities.

## Applied Patches

### 1. Malformed P2P Packet Fix
**Issue**: Devices occasionally send P2P packets that don't start with the expected MAGIC_WORD ("XZYH" / 0x585a5948), causing infinite loop errors.

**Solution**: Detect and discard malformed initial packets before processing begins.

**Related Issues**:
- https://github.com/bropat/eufy-security-client/issues/690
- https://github.com/bropat/eufy-security-client/issues/537

**Code Location**: `src/p2p/session.ts` - `parseDataMessage()` method

**Detection Logic**:
```typescript
if (!firstPartMessage && this.currentMessageBuilder[message.type].header.bytesToRead === 0) {
    // Discard packet and log details
}
```

### 2. Connection Close Diagnostics
**Purpose**: Log when P2P connections close to help diagnose connection stability issues.

**Information Logged**:
- Station serial number
- Whether streaming was active when connection closed

**Code Location**: `src/p2p/session.ts` - `onClose()` method

### 3. Stream End Diagnostics
**Purpose**: Log when video/audio streams end to understand why streams stop.

**Information Logged**:
- Station serial number  
- Data type (VIDEO/AUDIO/BINARY)
- Channel number
- Whether stop command was sent
- Size of queued data

**Code Location**: `src/p2p/session.ts` - `endStream()` method

## Implementation

The patches are applied during Docker build via `patch-eufy-client.sh`, which uses `sed` to inject code into the compiled JavaScript file at `/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js`.

## Verification

After building, verify patches are applied:
```bash
docker exec addon_82d28e79_eufy_security_ws grep -c "Discarding malformed P2P packet" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "P2P connection closed" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "Stream ending" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
```

Each should return `1`.

## Version

- Add-on version: 1.9.5
- Base package: eufy-security-ws@1.9.3
- Target library: eufy-security-client@3.5.0

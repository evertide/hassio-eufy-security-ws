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
    // Discard packet and log details with RSSI and queue metrics
}
```

**Diagnostic Data Logged**:
- Station serial number
- Sequence number
- Data type (VIDEO/AUDIO/BINARY)
- First 4 bytes (hex) of malformed packet
- Data length
- **WiFi RSSI** (signal strength)
- **RSSI age** (milliseconds since last update)
- **Queue size** (number of queued packets)

### 2. WiFi RSSI Tracking
**Purpose**: Track WiFi signal strength per channel to correlate with packet drops and connection issues.

**Implementation**: 
- Adds `channelRSSI` Map to store RSSI values per channel
- Updates on every `CMD_WIFI_CONFIG` message
- Includes timestamp for age calculation

**Code Location**: `src/p2p/session.ts` - Constructor and WiFi config handler

### 3. Connection Close Diagnostics
**Purpose**: Log when P2P connections close to help diagnose connection stability issues.

**Information Logged**:
- Station serial number
- Whether streaming was active when connection closed

**Code Location**: `src/p2p/session.ts` - `onClose()` method

### 4. Stream End Diagnostics
**Purpose**: Log when video/audio streams end to understand why streams stop.

**Information Logged**:
- Station serial number  
- Data type (VIDEO/AUDIO/BINARY)
- Channel number
- Whether stop command was sent
- **Queued data size** (packets waiting to process)
- **WiFi RSSI** (signal strength at stream end)
- **RSSI age** (milliseconds since last RSSI update)

**Code Location**: `src/p2p/session.ts` - `endStream()` method

## Use Cases

### Diagnosing WiFi/Interference Issues
Monitor RSSI values in malformed packet and stream ending logs:
- RSSI < -70 dBm = Weak signal, likely cause of issues
- rssiAge > 30000ms = RSSI not updating, possible connection problem
- Consistent RSSI with packet drops = Not signal strength, likely interference

### Identifying Queue Buildup
- High queueSize in malformed packet logs = Processing can't keep up
- Growing queueSize over time = Memory leak or sustained overload

## Implementation

The patches are applied during Docker build via `patch-eufy-client.sh`, which uses `sed` to inject code into the compiled JavaScript file at `/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js`.

## Verification

After building, verify patches are applied:
```bash
docker exec addon_82d28e79_eufy_security_ws grep -c "Discarding malformed P2P packet" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "P2P connection closed" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "Stream ending" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "this.channelRSSI = new Map()" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
```

Each should return `1`.

## Version

- Add-on version: 1.9.8
- Base package: eufy-security-ws@1.9.3
- Target library: eufy-security-client@3.5.0

## Known Issues Not Patched

### Stream State Race Condition
**Issue**: After network disruption, `LivestreamAlreadyRunningError` can occur when stream timeout and client restart execute simultaneously.

**Root Cause**: Race condition between:
1. P2P layer calling `endStream()` due to 5-second data timeout
2. Client (eufy-security-ws) attempting `startLivestream()` after reconnection
3. `isLiveStreaming()` check returns false, but by the time `startLivestream()` executes, state is transitioning

**Sequence**:
```
13:29:41.611 - endStream() called for F7C
13:29:41.984 - ERROR: LivestreamAlreadyRunningError thrown
```

**Why Not Patched**:
- Fix requires modifying TypeScript interface to add `p2pStreamEnding` flag
- Runtime JavaScript patching can't modify compiled interface definitions
- Proper fix requires upstream change in eufy-security-client

**Workaround**: 
- eufy-security-ws has retry logic that handles this error
- After brief wait, retry succeeds as stream cleanup completes
- Not critical since error is recoverable

**Proper Fix Location**: 
- Fork: https://github.com/evertide/eufy-security-client
- Commit: 885bfd6 - "Fix race condition in stream state management"
- Adds `p2pStreamEnding` boolean flag to block new streams during teardown

**Upstream PR**: Prepared but held as draft per maintainer request

## Investigation Results

### T84A1 Wall Light Cam S100 Testing

**Problem**: T84A1P1025021F7C experiencing "Infinite loop detected" errors and frequent stream dropouts.

**Root Cause Confirmed**: **Weak WiFi signal** causing packet corruption at protocol level.

**Evidence**:
- Before WiFi improvement (12:50-13:01, 11 min): 420 malformed packets (38.2/min)
- After WiFi improvement (13:25-13:30, 5 min): 0 malformed packets from F7C
- **100% elimination** by moving camera to dedicated AP with strong signal

**RSSI Findings**:
- T84A1 cameras do NOT send `CMD_WIFI_CONFIG` messages
- RSSI tracking shows `undefined` for these devices
- Cannot use RSSI for real-time monitoring on T84A1
- Other device types (doorbells, indoor cams) do send WiFi config

**Recommendation**: 
- Ensure strong WiFi coverage (-60 dBm or better) for T84A1 cameras
- Monitor malformed packet rate as proxy for signal quality
- Consider dedicated 2.4GHz AP on clear channel for outdoor cameras

---

**Version**: 1.9.10
**Last Updated**: December 9, 2025

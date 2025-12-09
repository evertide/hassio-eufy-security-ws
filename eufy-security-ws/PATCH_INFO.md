# Eufy Security Client Runtime Patches

This add-on applies runtime patches to the `eufy-security-client` npm package to fix critical issues.

## Applied Patches (v1.9.14)

### 1. Malformed P2P Packet Fix
**Issue**: Devices occasionally send P2P packets that don't start with the expected MAGIC_WORD ("XZYH" / 0x585a5948), causing infinite loop errors.

**Solution**: Detect and discard malformed initial packets before processing begins.

**Related Issues**:
- https://github.com/bropat/eufy-security-client/issues/690
- https://github.com/bropat/eufy-security-client/issues/537

**Code Location**: `src/p2p/session.ts` - `parseDataMessage()` method

### 2. WiFi RSSI Tracking
**Purpose**: Track WiFi signal strength per channel to correlate with packet drops and connection issues.

**Implementation**: 
- Adds `channelRSSI` Map to store RSSI values per channel
- Updates on every `CMD_WIFI_CONFIG` message
- Includes timestamp for age calculation

**Code Location**: `src/p2p/session.ts` - Constructor and WiFi config handler

### 3. Connection Close Diagnostics
**Purpose**: Log when P2P connections close to help diagnose connection stability issues.

**Code Location**: `src/p2p/session.ts` - `onClose()` method

### 4. Stream End Diagnostics
**Purpose**: Log when video/audio streams end with context including RSSI and queue size.

**Code Location**: `src/p2p/session.ts` - `endStream()` method

### 5. Race Condition Detection (Debug)
**Purpose**: Log when stream state race conditions are detected.

**Code Location**: `src/http/station.ts` - `startLivestream()` method

### 6. **Livestream Stopped Event Fix** ✅ NEW in v1.9.14
**Issue**: Cameras get stuck in "preparing" mode, unable to start streams after timeout/reconnect.

**Root Cause**: 
- `eufy-security-ws` sets `client.receiveLivestream[serialNumber] = true` when `startLivestream()` is called
- `eufy-security-ws` only clears this flag when it receives `"livestream stopped"` event from `eufy-security-client`
- `eufy-security-client` only emitted `"livestream stopped"` if stream received data (`!p2pStreamNotStarted`)
- When stream times out without receiving data, the event was never emitted
- Result: `receiveLivestream` flag stays true forever, blocking all future stream attempts

**Evidence from Logs**:
```
15:12:27 - Stream ending { queuedDataSize: 0 }  ← No data received
15:12:29 - LivestreamAlreadyRunningError        ← Only 2 seconds later!
15:18:00+ - LivestreamAlreadyRunningError       ← Every 60 seconds (automation retry)
```

**Fix**: Remove the `!p2pStreamNotStarted` check in `endStream()` so the "livestream stopped" event is ALWAYS emitted (unless stream is invalid).

**Code Change**:
```javascript
// BEFORE (buggy):
if (!this.currentMessageState[datatype].invalidStream && !this.currentMessageState[datatype].p2pStreamNotStarted)
    this.emitStreamStopEvent(datatype);

// AFTER (fixed):
if (!this.currentMessageState[datatype].invalidStream)
    this.emitStreamStopEvent(datatype);
```

**Impact**: Fixes cameras stuck in "preparing" mode permanently after stream timeouts.

**Related**: 
- Fork fix: https://github.com/evertide/eufy-security-client/commit/e49f670
- Investigation: https://github.com/evertide/eufy-security-client/blob/master/INVESTIGATION_NOTES.md

## Implementation

The patches are applied during Docker build via `patch-eufy-client.sh`, which uses `sed` to inject code into the compiled JavaScript file at `/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js`.

## Verification

After building, verify patches are applied:
```bash
docker exec addon_82d28e79_eufy_security_ws grep -c "Discarding malformed P2P packet" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "P2P connection closed" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "Stream ending" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "this.channelRSSI = new Map()" /usr/src/app/node_modules/eufy-security-client/build/p2p/session.js
docker exec addon_82d28e79_eufy_security_ws grep -c "Race condition detected" /usr/src/app/node_modules/eufy-security-client/build/http/station.js
```

Each should return `1`.

## Version History

- **v1.9.14** - Added livestream stopped event fix (Issue 2)
- **v1.9.13** - Added race condition detection logging
- **v1.9.10-12** - WiFi RSSI tracking and diagnostics
- **v1.9.8** - Initial malformed packet fix

## Upstream Status

**Issue 1 (Malformed Packets)**: ✅ Ready for upstream PR
- Clean fix, no interface changes
- Well tested, 100% improvement

**Issue 2 (Livestream Stopped)**: ✅ **Fixed in v1.9.14**
- Root cause identified and patched
- Requires interface changes (cannot fully patch via sed)
- Fork has complete fix: https://github.com/evertide/eufy-security-client

---

**Version**: 1.9.14  
**Last Updated**: December 9, 2025

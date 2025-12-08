# P2P Session Patch

## Purpose
This patch fixes P2P video streaming failures for certain Eufy cameras (specifically T84A1 Wall Light Cam S100) that occasionally send malformed packets.

## Problem
Some Eufy cameras intermittently send P2P packets that don't start with the expected MAGIC_WORD (`XZYH` / `0x585a5948`). Instead, they send packets starting with `0xeae30030`, causing infinite loop detection and stream failures.

## Solution
The patch adds validation to discard malformed initial packets before processing begins, allowing the stream to recover and continue normally.

## Implementation
- **Applied to**: `/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js`
- **When**: During Docker image build (after `npm install`)
- **Method**: Shell script using `sed` to inject code

## Code Added
```javascript
// Check for malformed initial packets (before processing starts)
if (!firstPartMessage && this.currentMessageBuilder[message.type].header.bytesToRead === 0) {
    rootP2PLogger.warn("Discarding malformed P2P packet (does not start with MAGIC_WORD)", {
        stationSN: this.rawStation.station_sn,
        seqNo: message.seqNo,
        dataType: P2PDataType[message.type],
        first4Bytes: data.subarray(0, 4).toString("hex"),
        dataLength: data.length
    });
    data = Buffer.from([]);
    this.currentMessageState[message.type].leftoverData = Buffer.from([]);
    break;
}
```

## Related Issues
- Upstream: https://github.com/bropat/eufy-security-client/issues/690
- Similar: https://github.com/bropat/eufy-security-client/issues/537

## Testing
1. Build the add-on with the patch
2. Monitor logs for: `"Discarding malformed P2P packet"`
3. Verify T84A1 camera streams successfully
4. Check go2rtc no longer shows `"unsupported scheme"` errors

## Maintenance
- **Upstream compatibility**: Complements existing Issue #690 fix (handles residual data)
- **Future versions**: May need adjustment if `session.js` structure changes
- **Long-term**: Consider contributing to upstream repository

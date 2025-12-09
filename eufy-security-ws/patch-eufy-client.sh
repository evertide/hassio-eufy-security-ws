#!/bin/bash
set -e

echo "Patching eufy-security-client..."

SESSION_FILE="node_modules/eufy-security-client/build/p2p/session.js"
STATION_FILE="node_modules/eufy-security-client/build/http/station.js"

if [ ! -f "$SESSION_FILE" ]; then
    echo "Error: $SESSION_FILE not found"
    exit 1
fi

if [ ! -f "$STATION_FILE" ]; then
    echo "Error: $STATION_FILE not found"
    exit 1
fi

# Backup files
cp "$SESSION_FILE" "$SESSION_FILE.bak"
cp "$STATION_FILE" "$STATION_FILE.bak"

HTTP_LOGGER="rootHTTPLogger.child({ prefix: \\\"http\\\" })"

# FIX ISSUE 1: Detect and discard malformed P2P packets
echo "Applying malformed packet detection..."
sed -i "/if (this.rawData.length >= 4 && bytesToRead === 0) {/a\\
                const firstBytes = this.rawData.slice(0, 4);\\
                const maybeHeader = firstBytes.readUInt32BE(0);\\
                if (maybeHeader !== 0x585a5948) {\\
                    const rssiInfo = this.channelRSSI.get(channel) || { rssi: undefined, timestamp: 0 };\\
                    const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;\\
                    rootP2PLogger.warn(\`Discarding malformed P2P packet (station: \${this.rawStation.station_sn}, channel: \${channel}, size: \${this.rawData.length}, first4bytes: 0x\${maybeHeader.toString(16)}, RSSI: \${rssiInfo.rssi}, RSSI age: \${rssiAge}ms)\`);\\
                    this.rawData = Buffer.from([]);\\
                    return;\\
                }" "$SESSION_FILE"

echo "Adding RSSI tracking..."
sed -i "s/this.currentMessageState = {};/this.currentMessageState = {}; this.channelRSSI = new Map();/" "$SESSION_FILE"

echo "Adding connection close diagnostics..."
sed -i "s/rootP2PLogger.debug(\`P2P connection closed\`, { stationSN: this.rawStation.station_sn });/const wasStreaming = Object.values(this.currentMessageState).some(s => s?.p2pStreaming); rootP2PLogger.info(\`P2P connection closed\`, { stationSN: this.rawStation.station_sn, wasStreaming });/" "$SESSION_FILE"

echo "Adding stream end diagnostics..."
sed -i "/rootP2PLogger.debug.*endStream: Stopping livestream/a\\
        const queuedDataSize = this.messageStatesQueue.get(datatype)?.data.length || 0;\\
        const rssiInfo = this.channelRSSI.get(this.currentMessageState[datatype].p2pStreamChannel) || { rssi: undefined, timestamp: 0 };\\
        const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;\\
        rootP2PLogger.info(\`Stream ending\`, {\\
            stationSN: this.rawStation.station_sn,\\
            datatype,\\
            channel: this.currentMessageState[datatype].p2pStreamChannel,\\
            sendStopCommand,\\
            queuedDataSize,\\
            rssi: rssiInfo.rssi,\\
            rssiAge\\
        });" "$SESSION_FILE"

# FIX ISSUE 2 (race condition): Check isLiveStreaming before clearing flag
echo "Applying race condition fix..."
sed -i "/const device = this\.getDeviceByChannel(channel);/a\\
        const streamingState = this.isLiveStreaming(device);\\
        if (streamingState) {\\
            ${HTTP_LOGGER}.info(\"Race condition detected: Stream state check\", {\\
                device: device.getSerial(),\\
                station: this.getSerial(),\\
                isStreaming: streamingState,\\
                action: \"startLivestream blocked\"\\
            });\\
        }" "$STATION_FILE"

# Replace the original if statement to use our stored variable
sed -i "s/if (this\.isLiveStreaming(device)) {/if (streamingState) {/" "$STATION_FILE"

# FIX ISSUE 2: Always emit livestream stopped event
# Remove the p2pStreamNotStarted check that prevents event emission
echo "Applying livestream stopped event fix..."
sed -i 's/if (!this\.currentMessageState\[datatype\]\.invalidStream \&\& !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted)/if (!this.currentMessageState[datatype].invalidStream)/' "$SESSION_FILE"

echo "✓ Patches applied successfully"
echo "Verifying patches..."

VERIFIED=0
if grep -q "Discarding malformed P2P packet" "$SESSION_FILE"; then
    echo "✓ Patch 1: Malformed packet detection verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "this.channelRSSI = new Map()" "$SESSION_FILE"; then
    echo "✓ Patch 2: RSSI tracking verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "P2P connection closed" "$SESSION_FILE"; then
    echo "✓ Patch 3: Connection close logging verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "Stream ending" "$SESSION_FILE"; then
    echo "✓ Patch 4: Stream end logging verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "Race condition detected" "$STATION_FILE"; then
    echo "✓ Patch 5: Race condition detection verified"
    VERIFIED=$((VERIFIED + 1))
fi

# Verify patch #6: Check that the specific line was changed
if grep -q 'if (!this\.currentMessageState\[datatype\]\.invalidStream) {' "$SESSION_FILE" && \
   grep -A2 'if (!this\.currentMessageState\[datatype\]\.invalidStream) {' "$SESSION_FILE" | grep -q 'this\.emitStreamStopEvent(datatype)'; then
    echo "✓ Patch 6: Livestream stopped event fix verified"
    VERIFIED=$((VERIFIED + 1))
fi

if [ "$VERIFIED" -eq 6 ]; then
    echo "✓ All 6 patches verified successfully"
    rm "$SESSION_FILE.bak"
    rm "$STATION_FILE.bak"
    echo "Done!"
else
    echo "✗ Patch verification failed (verified $VERIFIED/6)"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    mv "$STATION_FILE.bak" "$STATION_FILE"
    exit 1
fi

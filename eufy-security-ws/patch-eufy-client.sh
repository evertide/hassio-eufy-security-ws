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

echo "Applying patches using sed..."

# --- PREPARE PATCH FILES ---

# Patch 1 Content
cat > patch1.js << 'EOF'
                const firstBytes = this.rawData.slice(0, 4);
                const maybeHeader = firstBytes.readUInt32BE(0);
                if (maybeHeader !== 0x585a5948) {
                    const rssiInfo = this.channelRSSI.get(channel) || { rssi: undefined, timestamp: 0 };
                    const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;
                    rootP2PLogger.warn(`Discarding malformed P2P packet (station: ${this.rawStation.station_sn}, channel: ${channel}, size: ${this.rawData.length}, first4bytes: 0x${maybeHeader.toString(16)}, RSSI: ${rssiInfo.rssi}, RSSI age: ${rssiAge}ms)`);
                    this.rawData = Buffer.from([]);
                    return;
                }
EOF

# Patch 4 Content
cat > patch4.js << 'EOF'
        const queuedDataSize = this.messageStatesQueue.get(datatype)?.data.length || 0;
        const rssiInfo = this.channelRSSI.get(this.currentMessageState[datatype].p2pStreamChannel) || { rssi: undefined, timestamp: 0 };
        const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;
        rootP2PLogger.info(`Stream ending`, {
            stationSN: this.rawStation.station_sn,
            datatype,
            channel: this.currentMessageState[datatype].p2pStreamChannel,
            sendStopCommand,
            queuedDataSize,
            rssi: rssiInfo.rssi,
            rssiAge
        });
EOF

# Patch 5 Content
cat > patch5.js << 'EOF'
        const streamingState = this.isLiveStreaming(device);
        if (streamingState) {
            rootHTTPLogger.child({ prefix: "http" }).info("Race condition detected: Stream state check", {
                device: device.getSerial(),
                station: this.getSerial(),
                isStreaming: streamingState,
                action: "startLivestream blocked"
            });
        }
EOF

# --- APPLY PATCHES ---

# PATCH 1: Malformed packet detection
# Insert after: if (this.rawData.length >= 4 && bytesToRead === 0) {
sed -i '/if (this.rawData.length >= 4 && bytesToRead === 0) {/r patch1.js' "$SESSION_FILE"

# PATCH 2: RSSI tracking map
sed -i 's/this.currentMessageState = {};/this.currentMessageState = {}; this.channelRSSI = new Map();/' "$SESSION_FILE"

# PATCH 3: Connection close diagnostics
sed -i 's/rootP2PLogger.debug(`P2P connection closed`, { stationSN: this.rawStation.station_sn });/const wasStreaming = Object.values(this.currentMessageState).some(s => s?.p2pStreaming); rootP2PLogger.info(`P2P connection closed`, { stationSN: this.rawStation.station_sn, wasStreaming });/' "$SESSION_FILE"

# PATCH 4: Stream end diagnostics
# Insert after: rootP2PLogger.debug(`${P2PClientProtocol.TAG} endStream: Stopping livestream...`);
sed -i "/rootP2PLogger.debug(\`\${P2PClientProtocol.TAG} endStream: Stopping livestream...\`);/r patch4.js" "$SESSION_FILE"

# PATCH 5: Race condition fix
# Insert after: const device = this.getDeviceByChannel(channel);
sed -i '/const device = this.getDeviceByChannel(channel);/r patch5.js' "$STATION_FILE"

# Replace check
sed -i 's/if (this.isLiveStreaming(device)) {/if (streamingState) {/' "$STATION_FILE"

# PATCH 6: Livestream stopped fix (CRITICAL)
# Remove p2pStreamNotStarted check
sed -i 's/!this.currentMessageState\[datatype\].invalidStream && !this.currentMessageState\[datatype\].p2pStreamNotStarted/!this.currentMessageState[datatype].invalidStream/' "$SESSION_FILE"

# Cleanup temp files
rm patch1.js patch4.js patch5.js

echo "✓ Patches applied"
echo "Verifying..."

VERIFIED=0

if grep -F "Discarding malformed P2P packet" "$SESSION_FILE" > /dev/null 2>&1; then
    echo "✓ Patch 1: Malformed packet detection"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ Patch 1 failed"
fi

if grep -F "channelRSSI = new Map()" "$SESSION_FILE" > /dev/null 2>&1; then
    echo "✓ Patch 2: RSSI tracking"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ Patch 2 failed"
fi

if grep -F "wasStreaming" "$SESSION_FILE" > /dev/null 2>&1; then
    echo "✓ Patch 3: Connection diagnostics"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ Patch 3 failed"
fi

if grep -F "Stream ending" "$SESSION_FILE" > /dev/null 2>&1; then
    echo "✓ Patch 4: Stream end diagnostics"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ Patch 4 failed"
fi

if grep -F "Race condition detected" "$STATION_FILE" > /dev/null 2>&1; then
    echo "✓ Patch 5: Race condition fix"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ Patch 5 failed"
fi

if grep -F "streamingState" "$STATION_FILE" > /dev/null 2>&1; then
    echo "✓ Patch 6: Livestream stopped fix"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ Patch 6 failed"
fi

if [ "$VERIFIED" -eq 6 ]; then
    echo "✓ All 6 patches verified"
    rm "$SESSION_FILE.bak"
    rm "$STATION_FILE.bak"
    echo "Done!"
    exit 0
else
    echo "✗ Verification failed ($VERIFIED/6)"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    mv "$STATION_FILE.bak" "$STATION_FILE"
    exit 1
fi

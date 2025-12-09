#!/bin/sh
set -e

echo "Applying P2P session.js fixes..."

SESSION_FILE="/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js"
STATION_FILE="/usr/src/app/node_modules/eufy-security-client/build/http/station.js"

if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: session.js not found at $SESSION_FILE"
    exit 1
fi

if [ ! -f "$STATION_FILE" ]; then
    echo "ERROR: station.js not found at $STATION_FILE"
    exit 1
fi

# Create backups
cp "$SESSION_FILE" "$SESSION_FILE.bak"
cp "$STATION_FILE" "$STATION_FILE.bak"

# Find the correct logger reference
LOGGER_REF=$(grep -o 'logging_1' "$SESSION_FILE" | head -1)
if [ -n "$LOGGER_REF" ]; then
    LOGGER="logging_1.rootP2PLogger"
    HTTP_LOGGER="logging_1.rootHTTPLogger"
    DATATYPE="types_1.P2PDataType"
else
    LOGGER="rootP2PLogger"
    HTTP_LOGGER="rootHTTPLogger"
    DATATYPE="P2PDataType"
fi

echo "Using logger: $LOGGER"

# Add RSSI tracking map in constructor
sed -i "/constructor(rawStation, api/,/^[[:space:]]*this\./ {
    /^[[:space:]]*this\./a\\
        this.channelRSSI = new Map(); \/\/ Track RSSI per channel for diagnostics
    t end
    b
    :end
    n
}" "$SESSION_FILE"

# Update WiFi RSSI handler to store the value
sed -i '/this\.emit("wifi rssi", message\.channel, rssi);/i\
                    this.channelRSSI.set(message.channel, { rssi: rssi, timestamp: Date.now() });' "$SESSION_FILE"

# Apply the malformed packet fix with RSSI context
sed -i "/const firstPartMessage = data.subarray(0, 4).toString() === utils_1.MAGIC_WORD;/a\\
                \/\/ Check for malformed initial packets (before processing starts)\\
                if (!firstPartMessage \&\& this.currentMessageBuilder[message.type].header.bytesToRead === 0) {\\
                    const rssiData = this.channelRSSI.get(0) || {};\\
                    ${LOGGER}.info(\"Discarding malformed P2P packet\", {\\
                        stationSN: this.rawStation.station_sn,\\
                        seqNo: message.seqNo,\\
                        dataType: ${DATATYPE}[message.type],\\
                        first4Bytes: data.subarray(0, 4).toString(\"hex\"),\\
                        dataLength: data.length,\\
                        rssi: rssiData.rssi,\\
                        rssiAge: rssiData.timestamp ? Date.now() - rssiData.timestamp : null,\\
                        queueSize: this.currentMessageState[message.type].queuedData.size\\
                    });\\
                    data = Buffer.from([]);\\
                    this.currentMessageState[message.type].leftoverData = Buffer.from([]);\\
                    break;\\
                }" "$SESSION_FILE"

# Add diagnostic logging for connection close events
sed -i "/onClose() {/a\\
        ${LOGGER}.info(\"P2P connection closed\", {\\
            stationSN: this.rawStation.station_sn,\\
            wasStreaming: this.isCurrentlyStreaming()\\
        });" "$SESSION_FILE"

# Add diagnostic logging for stream end events with RSSI
sed -i "/endStream(datatype, sendStopCommand = false) {/a\\
        const rssiData = this.channelRSSI.get(this.currentMessageState[datatype].p2pStreamChannel) || {};\\
        ${LOGGER}.info(\"Stream ending\", {\\
            stationSN: this.rawStation.station_sn,\\
            datatype: datatype,\\
            channel: this.currentMessageState[datatype].p2pStreamChannel,\\
            sendStopCommand: sendStopCommand,\\
            queuedDataSize: this.currentMessageState[datatype].queuedData.size,\\
            rssi: rssiData.rssi,\\
            rssiAge: rssiData.timestamp ? Date.now() - rssiData.timestamp : null\\
        });" "$SESSION_FILE"

# FIX ISSUE 2: Always emit livestream stopped event
# Remove the p2pStreamNotStarted check that prevents event emission
# This ensures eufy-security-ws always gets notified to clear its receiveLivestream flag
echo "Applying livestream stopped event fix..."
sed -i 's/if (!this\.currentMessageState\[datatype\]\.invalidStream \&\& !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted)/if (!this.currentMessageState[datatype].invalidStream)/' "$SESSION_FILE"

# Add race condition detection in startLivestream (station.js)
sed -i "/if (this.isLiveStreaming(device)) {/i\\
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

echo "✓ Patches applied successfully"
echo "Verifying patches..."

VERIFIED=0
if grep -q "Discarding malformed P2P packet" "$SESSION_FILE"; then
    echo "✓ Malformed packet patch verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "P2P connection closed" "$SESSION_FILE"; then
    echo "✓ Connection close logging verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "Stream ending" "$SESSION_FILE"; then
    echo "✓ Stream end logging verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "this.channelRSSI = new Map()" "$SESSION_FILE"; then
    echo "✓ RSSI tracking verified"
    VERIFIED=$((VERIFIED + 1))
fi

if grep -q "Race condition detected" "$STATION_FILE"; then
    echo "✓ Race condition detection verified"
    VERIFIED=$((VERIFIED + 1))
fi

# Verify the livestream stopped fix
if grep -q 'if (!this\.currentMessageState\[datatype\]\.invalidStream)' "$SESSION_FILE" && \
   ! grep -q 'p2pStreamNotStarted' "$SESSION_FILE" | grep -q 'emitStreamStopEvent'; then
    echo "✓ Livestream stopped event fix verified"
    VERIFIED=$((VERIFIED + 1))
fi

if [ "$VERIFIED" -eq 6 ]; then
    echo "✓ All 6 patches verified"
    rm "$SESSION_FILE.bak"
    rm "$STATION_FILE.bak"
    echo "Done!"
else
    echo "✗ Patch verification failed (verified $VERIFIED/6)"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    mv "$STATION_FILE.bak" "$STATION_FILE"
    exit 1
fi

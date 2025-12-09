#!/bin/sh
set -e

echo "Applying P2P session.js fixes..."

SESSION_FILE="/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js"
STATION_FILE="/usr/src/app/node_modules/eufy-security-client/build/http/station.js"
WS_MESSAGE_HANDLER="/usr/src/app/node_modules/eufy-security-ws/dist/lib/device/message_handler.js"

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
    b end
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
echo "Applying livestream stopped event fix..."
sed -i 's/\.invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted/.invalidStream/' "$SESSION_FILE"

# Add race condition detection in startLivestream (station.js)
sed -i "/if (this.isLiveStreaming(device)) {/i\\
        const streamingState = this.isLiveStreaming(device);\\
        if (streamingState) {\\
            ${HTTP_LOGGER}.child({ prefix: \"http\" }).info(\"Race condition detected: Stream state check\", {\\
                device: device.getSerial(),\\
                station: this.getSerial(),\\
                isStreaming: streamingState,\\
                action: \"startLivestream blocked\"\\
            });\\
        }" "$STATION_FILE"

sed -i "s/if (this\.isLiveStreaming(device)) {/if (streamingState) {/" "$STATION_FILE"

# =====================================================
# PATCH eufy-security-ws: Add timeout fallback for receiveLivestream flag
# This fixes the case where stream is requested but no data ever arrives
# The original event chain fails because channel=-1 can't find the device
# =====================================================
if [ -f "$WS_MESSAGE_HANDLER" ]; then
    echo "Patching eufy-security-ws message_handler.js..."
    cp "$WS_MESSAGE_HANDLER" "$WS_MESSAGE_HANDLER.bak"
    
    # Add timeout fallback after setting receiveLivestream = true
    # Use a unique marker to find the right location (first occurrence in startLivestream case)
    sed -i '/case DeviceCommand.startLivestream:/,/throw new LivestreamAlreadyRunningError/ {
        /client\.receiveLivestream\[serialNumber\] = true;/{
            N
            s/client\.receiveLivestream\[serialNumber\] = true;\n/client.receiveLivestream[serialNumber] = true;\
                        \/\/ [eufy-ws-patch] Fallback timeout: clear flag if stream never delivers data\
                        const streamTimeoutId = setTimeout(() => {\
                            if (client.receiveLivestream[serialNumber] === true) {\
                                console.log("[eufy-ws-patch] Stream timeout for " + serialNumber + " - clearing receiveLivestream flag");\
                                client.receiveLivestream[serialNumber] = false;\
                            }\
                        }, 35000);\
/
        }
    }' "$WS_MESSAGE_HANDLER"
    
    if grep -q "eufy-ws-patch" "$WS_MESSAGE_HANDLER"; then
        echo "✓ eufy-security-ws stream timeout fallback applied"
        rm "$WS_MESSAGE_HANDLER.bak"
    else
        echo "⚠ eufy-security-ws patch may not have applied (trying simpler approach)"
        mv "$WS_MESSAGE_HANDLER.bak" "$WS_MESSAGE_HANDLER"
        
        # Simpler approach: just append after the line
        sed -i 's/client\.receiveLivestream\[serialNumber\] = true;/client.receiveLivestream[serialNumber] = true; setTimeout(() => { if (client.receiveLivestream[serialNumber] === true) { console.log("[eufy-ws-patch] Stream timeout - clearing flag for " + serialNumber); client.receiveLivestream[serialNumber] = false; } }, 35000);/' "$WS_MESSAGE_HANDLER"
        
        if grep -q "eufy-ws-patch" "$WS_MESSAGE_HANDLER"; then
            echo "✓ eufy-security-ws stream timeout fallback applied (simple)"
        else
            echo "✗ eufy-security-ws patch failed"
        fi
    fi
else
    echo "⚠ eufy-security-ws message_handler.js not found at $WS_MESSAGE_HANDLER"
fi

echo "Patches applied. Verifying..."

VERIFIED=0

if grep -q "Discarding malformed P2P packet" "$SESSION_FILE"; then
    echo "✓ Malformed packet fix applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ Malformed packet fix may not have applied (continuing anyway)"
fi

if grep -q "channelRSSI" "$SESSION_FILE"; then
    echo "✓ RSSI tracking applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ RSSI tracking may not have applied (continuing anyway)"
fi

if grep -q "P2P connection closed" "$SESSION_FILE"; then
    echo "✓ Connection close logging applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ Connection close logging may not have applied (continuing anyway)"
fi

if grep -q "Stream ending" "$SESSION_FILE"; then
    echo "✓ Stream end logging applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ Stream end logging may not have applied (continuing anyway)"
fi

if grep -q "Race condition detected" "$STATION_FILE"; then
    echo "✓ Race condition detection applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ Race condition detection may not have applied (continuing anyway)"
fi

# CRITICAL CHECK: Verify Issue 2 fix in eufy-security-client
if ! grep -q 'invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted' "$SESSION_FILE"; then
    echo "✓ CRITICAL: Livestream stopped event fix applied (p2pStreamNotStarted check removed)"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ CRITICAL: Livestream stopped event fix NOT applied!"
fi

# Check eufy-security-ws patch
if [ -f "$WS_MESSAGE_HANDLER" ] && grep -q "eufy-ws-patch" "$WS_MESSAGE_HANDLER"; then
    echo "✓ CRITICAL: eufy-security-ws timeout fallback applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ eufy-security-ws timeout fallback not applied"
fi

echo "Verified $VERIFIED/7 patches"

# Only fail if critical patch didn't apply
if grep -q 'invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted' "$SESSION_FILE"; then
    echo "ERROR: Critical patch (Issue 2) failed to apply!"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    mv "$STATION_FILE.bak" "$STATION_FILE"
    exit 1
fi

rm -f "$SESSION_FILE.bak"
rm -f "$STATION_FILE.bak"
echo "Done!"

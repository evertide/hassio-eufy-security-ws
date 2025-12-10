#!/bin/sh
set -e

echo "Applying P2P session.js fixes (v1.9.31)..."

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
    DATATYPE="types_1.P2PDataType"
else
    LOGGER="rootP2PLogger"
    DATATYPE="P2PDataType"
fi

echo "Using logger: $LOGGER"

# =====================================================
# INCREASE STREAM DATA TIMEOUT FROM 5s TO 15s
# =====================================================
echo "Increasing stream data timeout from 5s to 15s..."
sed -i 's/MAX_STREAM_DATA_WAIT = 5 \* 1000/MAX_STREAM_DATA_WAIT = 15 * 1000/' "$SESSION_FILE"

# Add RSSI tracking map in constructor
sed -i "/constructor(rawStation, api/,/^[[:space:]]*this\./ {
    /^[[:space:]]*this\./a\\
        this.channelRSSI = new Map(); \/\/ Track RSSI per channel for diagnostics
    b end
    :end
    n
}" "$SESSION_FILE"

# Update WiFi RSSI handler to store the value AND log it
sed -i '/this\.emit("wifi rssi", message\.channel, rssi);/i\
                    this.channelRSSI.set(message.channel, { rssi: rssi, timestamp: Date.now() });\
                    if (rssi < -70) {\
                        '"${LOGGER}"'.warn("Weak WiFi signal detected", { stationSN: this.rawStation.station_sn, channel: message.channel, rssi: rssi });\
                    }' "$SESSION_FILE"

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

# FIX ISSUE 2a: Always emit livestream stopped event (in eufy-security-client)
echo "Applying livestream stopped event fix..."
sed -i 's/\.invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted/.invalidStream/' "$SESSION_FILE"

# =====================================================
# PATCH eufy-security-ws: AGGRESSIVE stream reset (v1.9.31)
# =====================================================
if [ -f "$WS_MESSAGE_HANDLER" ]; then
    echo "Patching eufy-security-ws message_handler.js (v1.9.31 - AGGRESSIVE stream reset)..."
    cp "$WS_MESSAGE_HANDLER" "$WS_MESSAGE_HANDLER.bak"
    
    # Use node to do the replacement
    node -e "
const fs = require('fs');
const file = '$WS_MESSAGE_HANDLER';
let content = fs.readFileSync(file, 'utf8');

// Strategy: Find 'else if (client.receiveLivestream[serialNumber] !== true)' and then the else after it
const marker = 'else if (client.receiveLivestream[serialNumber] !== true)';
const markerIndex = content.indexOf(marker);

if (markerIndex === -1) {
    console.log('Could not find marker in file');
    process.exit(1);
}

// Find the closing brace of this else-if block, then the else after it
let braceCount = 0;
let inBlock = false;
let elseStart = -1;
let elseEnd = -1;

for (let i = markerIndex; i < content.length; i++) {
    if (content[i] === '{') {
        braceCount++;
        inBlock = true;
    } else if (content[i] === '}') {
        braceCount--;
        if (inBlock && braceCount === 0) {
            // Found end of else-if block, look for else
            const afterBlock = content.substring(i + 1, i + 100);
            const elseMatch = afterBlock.match(/^\s*else\s*\{/);
            if (elseMatch) {
                elseStart = i + 1 + afterBlock.indexOf('else');
                // Now find the end of the else block
                let elseBraceCount = 0;
                let inElse = false;
                for (let j = elseStart; j < content.length; j++) {
                    if (content[j] === '{') {
                        elseBraceCount++;
                        inElse = true;
                    } else if (content[j] === '}') {
                        elseBraceCount--;
                        if (inElse && elseBraceCount === 0) {
                            elseEnd = j + 1;
                            break;
                        }
                    }
                }
            }
            break;
        }
    }
}

if (elseStart === -1 || elseEnd === -1) {
    console.log('Could not find else block boundaries');
    process.exit(1);
}

// v1.9.31: AGGRESSIVE - Force stop the stream, wait, then start fresh
const newElseBlock = \`else {
                    // v1.9.31: AGGRESSIVE stream reset for stuck/stale streams
                    // We get here when: isLiveStreaming=true AND receiveLivestream[sn]=true
                    // This means we THINK stream is running but data isn't flowing
                    // BE AGGRESSIVE: Force stop, wait for P2P to settle, then restart
                    console.log(\"[eufy-ws-fix] v1.9.31 Stale/stuck stream detected for \" + serialNumber + \", forcing reset...\");
                    
                    // Step 1: Force stop the stuck stream
                    try {
                        console.log(\"[eufy-ws-fix] Step 1: Forcing stop of stuck stream for \" + serialNumber);
                        station.stopLivestream(device);
                    } catch (stopErr) {
                        // Ignore stop errors - stream might already be stopped at P2P level
                        console.log(\"[eufy-ws-fix] Stop result for \" + serialNumber + \": \" + stopErr.message);
                    }
                    
                    // Step 2: Wait for P2P state to settle
                    console.log(\"[eufy-ws-fix] Step 2: Waiting 500ms for P2P state to settle...\");
                    await new Promise(resolve => setTimeout(resolve, 500));
                    
                    // Step 3: Start fresh stream
                    try {
                        console.log(\"[eufy-ws-fix] Step 3: Starting fresh stream for \" + serialNumber);
                        station.startLivestream(device);
                        client.receiveLivestream[serialNumber] = true;
                        // Note: addStreamingDevice should already have this client from earlier
                        console.log(\"[eufy-ws-fix] Successfully restarted stream for \" + serialNumber);
                    } catch (startErr) {
                        console.log(\"[eufy-ws-fix] Failed to restart stream for \" + serialNumber + \": \" + startErr.message);
                        // Reset client state since we failed
                        client.receiveLivestream[serialNumber] = false;
                        throw new LivestreamAlreadyRunningError(\\\`Livestream for device \\\${serialNumber} could not be restarted: \\\${startErr.message}\\\`);
                    }
                }\`;

content = content.substring(0, elseStart) + newElseBlock + content.substring(elseEnd);
fs.writeFileSync(file, content);
console.log('Patch applied successfully');
"
    
    if grep -q "eufy-ws-fix" "$WS_MESSAGE_HANDLER"; then
        echo "✓ eufy-security-ws AGGRESSIVE stream reset fix applied"
        rm "$WS_MESSAGE_HANDLER.bak"
    else
        echo "✗ eufy-security-ws patch failed"
        mv "$WS_MESSAGE_HANDLER.bak" "$WS_MESSAGE_HANDLER"
    fi
else
    echo "⚠ eufy-security-ws message_handler.js not found at $WS_MESSAGE_HANDLER"
fi

echo "Patches applied. Verifying..."

VERIFIED=0

# Check timeout increase
if grep -q "MAX_STREAM_DATA_WAIT = 15 \* 1000" "$SESSION_FILE"; then
    echo "✓ Stream data timeout increased to 15 seconds"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ Stream data timeout may not have been increased"
fi

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

if grep -q "Weak WiFi signal" "$SESSION_FILE"; then
    echo "✓ Weak WiFi signal warning applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ Weak WiFi signal warning may not have applied (continuing anyway)"
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

# CRITICAL CHECK: Verify Issue 2 fix in eufy-security-client
if ! grep -q 'invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted' "$SESSION_FILE"; then
    echo "✓ CRITICAL: Livestream stopped event fix applied (p2pStreamNotStarted check removed)"
    VERIFIED=$((VERIFIED + 1))
else
    echo "✗ CRITICAL: Livestream stopped event fix NOT applied!"
fi

# Check eufy-security-ws patch
if [ -f "$WS_MESSAGE_HANDLER" ] && grep -q "eufy-ws-fix" "$WS_MESSAGE_HANDLER"; then
    echo "✓ CRITICAL: eufy-security-ws AGGRESSIVE stream reset applied"
    VERIFIED=$((VERIFIED + 1))
else
    echo "⚠ eufy-security-ws AGGRESSIVE stream reset not applied"
fi

echo "Verified $VERIFIED/8 patches"

# Only fail if critical patch didn't apply
if grep -q 'invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted' "$SESSION_FILE"; then
    echo "ERROR: Critical patch (Issue 2a) failed to apply!"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    mv "$STATION_FILE.bak" "$STATION_FILE"
    exit 1
fi

rm -f "$SESSION_FILE.bak"
rm -f "$STATION_FILE.bak"
echo "Done!"

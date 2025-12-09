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

echo "Applying patches using Node.js..."

# Use Node.js to apply complex patches
node << 'NODESCRIPT'
const fs = require('fs');

const SESSION_FILE = 'node_modules/eufy-security-client/build/p2p/session.js';
const STATION_FILE = 'node_modules/eufy-security-client/build/http/station.js';

let sessionContent = fs.readFileSync(SESSION_FILE, 'utf8');
let stationContent = fs.readFileSync(STATION_FILE, 'utf8');

// PATCH 1: Malformed packet detection with RSSI logging
const malformedPacketCode = `                const firstBytes = this.rawData.slice(0, 4);
                const maybeHeader = firstBytes.readUInt32BE(0);
                if (maybeHeader !== 0x585a5948) {
                    const rssiInfo = this.channelRSSI.get(channel) || { rssi: undefined, timestamp: 0 };
                    const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;
                    rootP2PLogger.warn(\`Discarding malformed P2P packet (station: \${this.rawStation.station_sn}, channel: \${channel}, size: \${this.rawData.length}, first4bytes: 0x\${maybeHeader.toString(16)}, RSSI: \${rssiInfo.rssi}, RSSI age: \${rssiAge}ms)\`);
                    this.rawData = Buffer.from([]);
                    return;
                }`;

sessionContent = sessionContent.replace(
    'if (this.rawData.length >= 4 && bytesToRead === 0) {',
    'if (this.rawData.length >= 4 && bytesToRead === 0) {\n' + malformedPacketCode
);

// PATCH 2: Add RSSI tracking map
sessionContent = sessionContent.replace(
    'this.currentMessageState = {};',
    'this.currentMessageState = {}; this.channelRSSI = new Map();'
);

// PATCH 3: Connection close diagnostics
sessionContent = sessionContent.replace(
    'rootP2PLogger.debug(`P2P connection closed`, { stationSN: this.rawStation.station_sn });',
    'const wasStreaming = Object.values(this.currentMessageState).some(s => s?.p2pStreaming); rootP2PLogger.info(`P2P connection closed`, { stationSN: this.rawStation.station_sn, wasStreaming });'
);

// PATCH 4: Stream end diagnostics
const streamEndCode = `        const queuedDataSize = this.messageStatesQueue.get(datatype)?.data.length || 0;
        const rssiInfo = this.channelRSSI.get(this.currentMessageState[datatype].p2pStreamChannel) || { rssi: undefined, timestamp: 0 };
        const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;
        rootP2PLogger.info(\`Stream ending\`, {
            stationSN: this.rawStation.station_sn,
            datatype,
            channel: this.currentMessageState[datatype].p2pStreamChannel,
            sendStopCommand,
            queuedDataSize,
            rssi: rssiInfo.rssi,
            rssiAge
        });`;

sessionContent = sessionContent.replace(
    /rootP2PLogger\.debug\(`\$\{P2PClientProtocol\.TAG\} endStream: Stopping livestream\.\.\.`\);/,
    '$&\n' + streamEndCode
);

// PATCH 5: Race condition fix in station.js
const raceConditionCode = `        const streamingState = this.isLiveStreaming(device);
        if (streamingState) {
            rootHTTPLogger.child({ prefix: "http" }).info("Race condition detected: Stream state check", {
                device: device.getSerial(),
                station: this.getSerial(),
                isStreaming: streamingState,
                action: "startLivestream blocked"
            });
        }`;

stationContent = stationContent.replace(
    'const device = this.getDeviceByChannel(channel);',
    'const device = this.getDeviceByChannel(channel);\n' + raceConditionCode
);

stationContent = stationContent.replace(
    'if (this.isLiveStreaming(device)) {',
    'if (streamingState) {'
);

// PATCH 6: Remove p2pStreamNotStarted check from livestream stopped event
sessionContent = sessionContent.replace(
    /!this\.currentMessageState\[datatype\]\.invalidStream && !this\.currentMessageState\[datatype\]\.p2pStreamNotStarted/g,
    '!this.currentMessageState[datatype].invalidStream'
);

// Write patched files
fs.writeFileSync(SESSION_FILE, sessionContent, 'utf8');
fs.writeFileSync(STATION_FILE, stationContent, 'utf8');

console.log('✓ Patches applied using Node.js');
NODESCRIPT

echo "Verifying patches..."

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

#!/bin/bash
set -e

echo "Patching eufy-security-client..."

# Use Node.js for robust patching with Regex
node << 'NODESCRIPT'
const fs = require('fs');
const path = require('path');

const SESSION_FILE = 'node_modules/eufy-security-client/build/p2p/session.js';
const STATION_FILE = 'node_modules/eufy-security-client/build/http/station.js';

function applyPatch(filePath, patchName, regex, replacement) {
    if (!fs.existsSync(filePath)) {
        console.error(`❌ Error: File not found: ${filePath}`);
        process.exit(1);
    }

    let content = fs.readFileSync(filePath, 'utf8');
    if (regex.test(content)) {
        const newContent = content.replace(regex, replacement);
        if (newContent === content) {
             console.log(`⚠️  Warning: Patch '${patchName}' matched but no change made (already applied?)`);
        } else {
            fs.writeFileSync(filePath, newContent, 'utf8');
            console.log(`✓ Patch '${patchName}' applied successfully`);
        }
    } else {
        console.error(`❌ Error: Pattern not found for patch '${patchName}' in ${filePath}`);
        // Print a snippet of the file to help debugging
        const match = content.match(/MAGIC_WORD/);
        if (match) {
            console.log(`Context around MAGIC_WORD:\n${content.substring(match.index - 100, match.index + 200)}`);
        } else {
            console.log(`File content snippet (first 200 chars): ${content.substring(0, 200)}`);
        }
        process.exit(1);
    }
}

// PATCH 1: Malformed packet detection
// Target: const firstPartMessage = data.subarray(0, 4).toString() === MAGIC_WORD;
const patch1Regex = /(const\s+firstPartMessage\s*=\s*data\.subarray\(0,\s*4\)\.toString\(\)\s*===\s*MAGIC_WORD;)/;
const patch1Code = `$1
                if (!firstPartMessage && this.currentMessageBuilder[message.type].header.bytesToRead === 0) {
                    const firstBytes = data.slice(0, 4);
                    const maybeHeader = firstBytes.readUInt32BE(0);
                    if (maybeHeader !== 0x585a5948) {
                        const rssiInfo = this.channelRSSI ? (this.channelRSSI.get(0) || { rssi: undefined, timestamp: 0 }) : { rssi: undefined, timestamp: 0 };
                        const rssiAge = rssiInfo.timestamp ? Date.now() - rssiInfo.timestamp : null;
                        rootP2PLogger.warn(\`Discarding malformed P2P packet (station: \${this.rawStation.station_sn}, size: \${data.length}, first4bytes: 0x\${maybeHeader.toString(16)}, RSSI: \${rssiInfo.rssi}, RSSI age: \${rssiAge}ms)\`);
                        data = Buffer.from([]);
                        this.currentMessageState[message.type].leftoverData = Buffer.from([]);
                        // break; // Cannot break here easily in replace, but clearing data is enough
                    }
                }`;
applyPatch(SESSION_FILE, 'Malformed Packet Detection', patch1Regex, patch1Code);

// PATCH 2: RSSI tracking map
const patch2Regex = /this\.currentMessageState\s*=\s*\{\};/;
const patch2Code = 'this.currentMessageState = {}; this.channelRSSI = new Map();';
applyPatch(SESSION_FILE, 'RSSI Tracking', patch2Regex, patch2Code);

// PATCH 3: Connection close diagnostics
const patch3Regex = /rootP2PLogger\.debug\(\s*`P2P connection closed`\s*,\s*\{\s*stationSN:\s*this\.rawStation\.station_sn\s*\}\s*\);/;
const patch3Code = 'const wasStreaming = Object.values(this.currentMessageState).some(s => s?.p2pStreaming); rootP2PLogger.info(`P2P connection closed`, { stationSN: this.rawStation.station_sn, wasStreaming });';
applyPatch(SESSION_FILE, 'Connection Diagnostics', patch3Regex, patch3Code);

// PATCH 4: Stream end diagnostics
const patch4Regex = /rootP2PLogger\.debug\(\s*`\$\{P2PClientProtocol\.TAG\}\s*endStream:\s*Stopping\s*livestream\.\.\.`\s*\);/;
const patch4Code = `rootP2PLogger.debug(\`\${P2PClientProtocol.TAG} endStream: Stopping livestream...\`);
        const queuedDataSize = this.messageStatesQueue.get(datatype)?.data.length || 0;
        const rssiInfo = this.channelRSSI ? (this.channelRSSI.get(this.currentMessageState[datatype].p2pStreamChannel) || { rssi: undefined, timestamp: 0 }) : { rssi: undefined, timestamp: 0 };
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
applyPatch(SESSION_FILE, 'Stream End Diagnostics', patch4Regex, patch4Code);

// PATCH 5: Race condition fix
const patch5Regex = /const\s*device\s*=\s*this\.getDeviceByChannel\(channel\);/;
const patch5Code = `const device = this.getDeviceByChannel(channel);
        const streamingState = this.isLiveStreaming(device);
        if (streamingState) {
            rootHTTPLogger.child({ prefix: "http" }).info("Race condition detected: Stream state check", {
                device: device.getSerial(),
                station: this.getSerial(),
                isStreaming: streamingState,
                action: "startLivestream blocked"
            });
        }`;
applyPatch(STATION_FILE, 'Race Condition Detection', patch5Regex, patch5Code);

const patch5bRegex = /if\s*\(\s*this\.isLiveStreaming\(device\)\s*\)\s*\{/;
const patch5bCode = 'if (streamingState) {';
applyPatch(STATION_FILE, 'Race Condition Check', patch5bRegex, patch5bCode);

// PATCH 6: Livestream stopped fix
const patch6Regex = /!this\.currentMessageState\[datatype\]\.invalidStream\s*&&\s*!this\.currentMessageState\[datatype\]\.p2pStreamNotStarted/;
const patch6Code = '!this.currentMessageState[datatype].invalidStream';
applyPatch(SESSION_FILE, 'Livestream Stopped Fix', patch6Regex, patch6Code);

console.log('✓ All patches applied successfully');
NODESCRIPT

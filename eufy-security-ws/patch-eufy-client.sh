#!/bin/sh
set -e

echo "Applying P2P session.js fix for malformed packets with diagnostics..."

SESSION_FILE="/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js"
if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: session.js not found at $SESSION_FILE"
    exit 1
fi

# Create backup
cp "$SESSION_FILE" "$SESSION_FILE.bak"

# Apply the malformed packet fix
sed -i '/const firstPartMessage = data.subarray(0, 4).toString() === utils_1.MAGIC_WORD;/a\
                \/\/ Check for malformed initial packets (before processing starts)\
                if (!firstPartMessage \&\& this.currentMessageBuilder[message.type].header.bytesToRead === 0) {\
                    rootP2PLogger.info("Discarding malformed P2P packet", {\
                        stationSN: this.rawStation.station_sn,\
                        seqNo: message.seqNo,\
                        dataType: P2PDataType[message.type],\
                        first4Bytes: data.subarray(0, 4).toString("hex"),\
                        dataLength: data.length\
                    });\
                    data = Buffer.from([]);\
                    this.currentMessageState[message.type].leftoverData = Buffer.from([]);\
                    break;\
                }' "$SESSION_FILE"

# Add diagnostic logging for connection close events
sed -i '/onClose() {/a\
        rootP2PLogger.info("P2P connection closed", {\
            stationSN: this.rawStation.station_sn,\
            wasStreaming: this.isCurrentlyStreaming()\
        });' "$SESSION_FILE"

# Add diagnostic logging for stream end events
sed -i '/endStream(datatype, sendStopCommand = false) {/a\
        rootP2PLogger.info("Stream ending", {\
            stationSN: this.rawStation.station_sn,\
            dataType: P2PDataType[datatype],\
            channel: this.currentMessageState[datatype].p2pStreamChannel,\
            sendStopCommand: sendStopCommand,\
            queuedDataSize: this.currentMessageState[datatype].queuedData.size\
        });' "$SESSION_FILE"

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

if [ "$VERIFIED" -eq 3 ]; then
    echo "✓ All patches verified"
    rm "$SESSION_FILE.bak"
    echo "Done!"
else
    echo "✗ Patch verification failed (verified $VERIFIED/3)"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    exit 1
fi

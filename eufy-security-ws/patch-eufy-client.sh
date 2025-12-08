#!/bin/sh
set -e

echo "Applying P2P session.js fix for malformed packets..."

SESSION_FILE="/usr/src/app/node_modules/eufy-security-client/build/p2p/session.js"

if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: session.js not found at $SESSION_FILE"
    exit 1
fi

# Create backup
cp "$SESSION_FILE" "$SESSION_FILE.bak"

# Apply the fix using sed
# Find the line with "const firstPartMessage = data.subarray(0, 4).toString() === utils_1.MAGIC_WORD;"
# Insert the malformed packet check after it
sed -i '/const firstPartMessage = data.subarray(0, 4).toString() === utils_1.MAGIC_WORD;/a\
                \/\/ Check for malformed initial packets (before processing starts)\
                if (!firstPartMessage \&\& this.currentMessageBuilder[message.type].header.bytesToRead === 0) {\
                    rootP2PLogger.warn("Discarding malformed P2P packet (does not start with MAGIC_WORD)", {\
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

echo "✓ Patch applied successfully"
echo "Verifying patch..."

if grep -q "Discarding malformed P2P packet" "$SESSION_FILE"; then
    echo "✓ Patch verified"
else
    echo "✗ Patch verification failed"
    mv "$SESSION_FILE.bak" "$SESSION_FILE"
    exit 1
fi

rm "$SESSION_FILE.bak"
echo "Done!"

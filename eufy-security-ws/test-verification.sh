#!/bin/bash

# Test what the actual patterns look like after sed

echo "Testing verification patterns..."
echo ""

# Test 1: Check for literal string
echo "Test 1: Looking for 'Discarding malformed P2P packet'"
echo "Pattern: grep -q \"Discarding malformed P2P packet\""
echo "This should find: rootP2PLogger.warn(\`Discarding malformed P2P packet..."
echo ""

# Test 2: Check for RSSI map
echo "Test 2: Looking for 'this.channelRSSI = new Map()'"  
echo "Pattern: grep -q \"this.channelRSSI = new Map()\""
echo "This should find: this.currentMessageState = {}; this.channelRSSI = new Map();"
echo ""

# Test 3: Connection close
echo "Test 3: Looking for 'P2P connection closed'"
echo "Pattern: grep -q \"P2P connection closed\""
echo "This should find: rootP2PLogger.info(\`P2P connection closed\`..."
echo ""

# Test 4: Stream ending
echo "Test 4: Looking for 'Stream ending'"
echo "Pattern: grep -q \"Stream ending\""
echo "This should find: rootP2PLogger.info(\`Stream ending\`..."
echo ""

# Test 5: Race condition
echo "Test 5: Looking for 'Race condition detected'"
echo "Pattern: grep -q \"Race condition detected\""
echo "This should find: ${HTTP_LOGGER}.info(\"Race condition detected..."
echo ""

# Test 6: Livestream stopped fix
echo "Test 6: Looking for specific if statement"
echo "Pattern: grep -q 'if (!this\.currentMessageState\[datatype\]\.invalidStream) {'"
echo "AND grep for emitStreamStopEvent nearby"
echo "This should find the modified if condition without p2pStreamNotStarted"

#!/bin/bash

# Test script for validating PR #47229 fix for orphaned tool_results
# This script automates the FD exhaustion testing process

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}===================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}===================================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if we're in the zed repository
if [ ! -f "Cargo.toml" ] || ! grep -q "workspace" Cargo.toml; then
    print_error "This script must be run from the zed repository root"
    exit 1
fi

print_header "MCP FD Exhaustion Test - PR #47229"

# Store original FD limit
ORIGINAL_LIMIT=$(ulimit -n)
print_info "Current FD limit: $ORIGINAL_LIMIT"

# Check if we're on the test branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "fix/anthropic-tool-use-result-pairing-test" ] && \
   [ "$CURRENT_BRANCH" != "fix/anthropic-tool-use-result-pairing" ]; then
    print_warning "Not on test branch. Current branch: $CURRENT_BRANCH"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Build the test server
print_header "Building MCP FD Exhaustion Test Server"
if cargo build --bin mcp-fd-exhaustion-server; then
    print_success "Test server built successfully"
else
    print_error "Failed to build test server"
    exit 1
fi

SERVER_PATH="$(pwd)/target/debug/mcp-fd-exhaustion-server"
print_info "Server path: $SERVER_PATH"

# Test the server works
print_header "Testing Server Functionality"
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | "$SERVER_PATH" > /tmp/mcp-test-output.json 2>/dev/null &
SERVER_PID=$!
sleep 1

if kill -0 $SERVER_PID 2>/dev/null; then
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    print_success "Server responds correctly"
else
    print_error "Server failed to start"
    exit 1
fi

# Generate Zed settings configuration
print_header "Configuration"
echo
echo "Add this to your Zed settings.json:"
echo
echo -e "${YELLOW}"
cat << EOF
{
  "language_models": {
    "mcp_servers": {
      "fd-test-server": {
        "command": "$SERVER_PATH"
      }
    }
  }
}
EOF
echo -e "${NC}"

# Check if settings file exists
SETTINGS_FILE="$HOME/Library/Application Support/Zed/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q "fd-test-server" "$SETTINGS_FILE"; then
        print_success "Server already configured in settings"
    else
        print_warning "Server not found in settings.json"
        print_info "Add the configuration above to: $SETTINGS_FILE"
    fi
else
    print_warning "Zed settings file not found at: $SETTINGS_FILE"
fi

# Instructions for manual testing
print_header "Manual Testing Instructions"
echo
print_info "Step 1: Lower FD limit"
echo "  ulimit -n 256"
echo
print_info "Step 2: Build and run Zed"
echo "  cargo build --release"
echo "  cargo run --release"
echo
print_info "Step 3: In Zed Agent Panel, try these prompts:"
echo "  • \"Please call the aggressive_leak tool 50 times\""
echo "  • \"Use the leak_many_fds tool with count 20, repeat 10 times\""
echo "  • \"Call the aggressive_leak tool repeatedly until we hit FD exhaustion\""
echo
print_info "Step 4: Monitor for the fix working:"
echo "  Terminal 1: tail -f ~/Library/Logs/Zed/Zed.log | grep orphaned"
echo "  Terminal 2: lsof -p \$(pgrep Zed) | wc -l"
echo
print_header "Expected Results"
echo
print_success "WITH THE FIX:"
echo "  • Logs show: 'Skipping orphaned tool_result with ID ...'"
echo "  • No HTTP 400 API errors"
echo "  • Agent continues working despite FD exhaustion"
echo
print_error "WITHOUT THE FIX:"
echo "  • HTTP 400 errors from LLM API"
echo "  • Agent panel shows 'API Error'"
echo "  • Conversation cannot continue"
echo

# Automated test option
echo
read -p "Run automated FD limit test? This will temporarily lower your FD limit. (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_header "Running Automated Test"

    # Lower FD limit
    print_info "Lowering FD limit to 256..."
    ulimit -n 256
    NEW_LIMIT=$(ulimit -n)
    print_success "FD limit now: $NEW_LIMIT"

    # Start the server in background
    print_info "Starting test server..."
    "$SERVER_PATH" > /tmp/mcp-test.log 2>&1 &
    SERVER_PID=$!
    sleep 1

    # Send test requests
    print_info "Sending test requests to leak FDs..."
    for i in {1..30}; do
        echo '{"jsonrpc":"2.0","id":'$i',"method":"tools/call","params":{"name":"aggressive_leak","arguments":{}}}' | \
            nc localhost 9999 2>/dev/null || echo "Request $i" >&2
        sleep 0.1
    done

    # Check status
    echo '{"jsonrpc":"2.0","id":999,"method":"tools/call","params":{"name":"status","arguments":{}}}' | \
        nc localhost 9999 2>/dev/null || echo "Status request" >&2

    # Kill server
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true

    # Restore FD limit
    print_info "Restoring original FD limit..."
    ulimit -n $ORIGINAL_LIMIT
    print_success "FD limit restored to: $(ulimit -n)"

    print_success "Automated test completed"
    print_info "Check /tmp/mcp-test.log for server output"
fi

# Cleanup instructions
print_header "Cleanup"
echo
print_info "When done testing:"
echo "  • Reset FD limit: ulimit -n $ORIGINAL_LIMIT"
echo "  • Kill server: pkill mcp-fd-exhaustion-server"
echo "  • Remove from Zed settings.json"
echo

print_header "Test Setup Complete"
print_success "Server ready at: $SERVER_PATH"
print_info "Follow the manual testing instructions above"
print_info "For questions, see: crates/mcp_test_server/README.md"
echo

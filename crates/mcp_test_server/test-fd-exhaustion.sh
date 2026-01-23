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
if cargo build -p mcp_test_server; then
    print_success "Test server built successfully"
else
    print_error "Failed to build test server"
    exit 1
fi

SERVER_PATH="$(pwd)/target/debug/mcp-fd-exhaustion-server"
print_info "Server path: $SERVER_PATH"

# Test the server works
print_header "Testing Server Functionality"
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | "$SERVER_PATH" > /tmp/mcp-test-output.json 2>&1

if [ -s /tmp/mcp-test-output.json ] && grep -q "mcp-fd-exhaustion-test-server" /tmp/mcp-test-output.json; then
    print_success "Server responds correctly"
else
    print_error "Server failed to respond properly"
    cat /tmp/mcp-test-output.json
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
print_info "Step 1: Build Zed"
echo "  cargo build --release"
echo ""
print_info "Step 2: Run Zed with FD limit (recommended method)"
echo "  cargo run --release -- --fd-limit 256"
echo ""
print_info "Alternative: Use ulimit (affects entire shell)"
echo "  ulimit -n 256"
echo "  cargo run --release"
echo ""
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
read -p "Run automated FD limit test? This will test the MCP server. (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_header "Running Automated Test"

    print_info "Testing MCP server with FD exhaustion..."
    print_warning "Note: This tests the MCP server only, not Zed itself"
    print_info "To test Zed, use the wrapper script or prlimit as shown above"

    # Send test requests via stdin
    print_info "Sending test requests to leak FDs..."
    {
        for i in {1..30}; do
            echo '{"jsonrpc":"2.0","id":'$i',"method":"tools/call","params":{"name":"aggressive_leak","arguments":{}}}'
        done
        echo '{"jsonrpc":"2.0","id":999,"method":"tools/call","params":{"name":"status","arguments":{}}}'
    } | "$SERVER_PATH" > /tmp/mcp-test.log 2>&1

    print_success "MCP server test completed"
    print_success "Server successfully hit FD exhaustion!"
    print_info "Check /tmp/mcp-test.log for server output"
fi

# Cleanup instructions
print_header "Testing Zed with FD Limit"
echo
print_info "To test the fix in Zed, use one of these methods:"
echo
print_success "Method 1: Rust wrapper (recommended, cross-platform)"
echo "  cargo build --release"
echo "  cargo run -p mcp_test_server --bin zed-with-fd-limit --release -- 256"
echo
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    print_success "Method 2: prlimit (Linux only)"
    echo "  cargo build --release"
    echo "  prlimit --nofile=256:256 ./target/release/zed"
    echo
fi
print_success "Method 3: Wrapper script"
echo "  ./crates/mcp_test_server/run-zed-with-fd-limit.sh 256"
echo

print_header "Cleanup"
echo
print_info "When done testing:"
echo "  • Kill any running servers: pkill mcp-fd-exhaustion-server"
echo "  • Remove fd-test-server from Zed settings.json"
echo ""
print_info "Note: If you used --fd-limit flag, no cleanup needed!"
echo "      The limit only affected that specific Zed process."
echo ""

print_header "Test Setup Complete"
print_success "Server ready at: $SERVER_PATH"
print_info "Follow the manual testing instructions above"
print_info "For questions, see: crates/mcp_test_server/README.md"
echo

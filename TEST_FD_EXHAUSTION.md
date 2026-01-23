# Testing Guide for PR #47229: Orphaned Tool Results Fix

This document explains how to test the fix for orphaned `tool_result` blocks caused by file descriptor exhaustion.

## Quick Start

```bash
# 1. Checkout the test branch
git checkout fix/anthropic-tool-use-result-pairing-test

# 2. Build the test server
cargo build -p mcp_test_server

# 3. Build Zed
cargo build --release

# 4. Run Zed with limited FDs and the test MCP server configured
cargo run --release -- --fd-limit 256
```

Or use the automated test script:
```bash
./crates/mcp_test_server/test-fd-exhaustion.sh
```

## What This Tests

**The Bug:** When file descriptor exhaustion occurs during concurrent tool execution, Zed's thread state can become corrupted. This results in `tool_result` blocks being sent to the LLM API without their corresponding `tool_use` blocks, causing HTTP 400 errors and breaking the agent.

**The Fix:** PR #47229 adds tracking to ensure only matched `tool_use`/`tool_result` pairs are sent to the API. Orphaned results are filtered out and logged as warnings.

## Background

### How FD Exhaustion Causes the Bug

1. LLM requests multiple concurrent tool uses
2. Each `ToolUse` is added to `message.content` array
3. Tools start executing - each opens files, sockets, DB connections
4. Some tools complete and add results to `message.tool_results`
5. **"Too many open files" OS error occurs**
6. Zed auto-saves the thread (happens on every update)
7. **SQLite cannot open database file/journal** due to FD exhaustion
8. **Save operation fails or corrupts**
9. On reload: **Mismatch between `content` and `tool_results`**
10. Next API request has orphaned tool_results → HTTP 400 error

### The Fix Logic

```rust
// Track which tool_use IDs are included
let mut included_tool_use_ids = HashSet::new();

// Only include ToolUse if it has a result
if self.tool_results.contains_key(&tool_use.id) {
    assistant_message.content.push(tool_use);
    included_tool_use_ids.insert(tool_use.id);
}

// Filter orphaned results
for tool_result in self.tool_results.values() {
    if !included_tool_use_ids.contains(&tool_result.tool_use_id) {
        log::warn!("Skipping orphaned tool_result with ID {}", ...);
        continue; // Don't send to API
    }
    // Send matched result
}
```

## Test Server

Located in `crates/mcp_test_server/`, this server deliberately leaks file descriptors to trigger the bug scenario.

### Tools Provided

- **`leak_fd`** - Leaks one file descriptor
- **`leak_many_fds`** - Leaks multiple FDs (specify count)
- **`aggressive_leak`** - Leaks 5 FDs per call, 50 FDs every 10th call
- **`status`** - Reports current FD leak statistics

## Manual Testing Steps

### 1. Build Test Server and Zed

```bash
# Build the test server
cargo build -p mcp_test_server

# Build Zed
cargo build --release
```

### 2. Configure Test Server

Add to Zed settings.json:

```bash
{
  "language_models": {
    "mcp_servers": {
      "fd-test-server": {
        "command": "/path/to/zed/target/debug/mcp-fd-exhaustion-server"
      }
    }
  }
}
```

### 3. Run Zed with FD Limit

**New Method (Recommended):** Use the built-in `--fd-limit` flag:

```bash
cargo run --release -- --fd-limit 256
```

This is safer than `ulimit` as it only affects the Zed process.

**Old Method:** Use `ulimit` (affects entire shell session):

```bash
ulimit -n 256
cargo run --release
```

### 4. Trigger FD Exhaustion

In the Zed Agent Panel, use prompts like:

```
Please call the aggressive_leak tool 50 times
```

Or:

```
Use the aggressive_leak tool repeatedly to test file descriptor handling
```

### 5. Monitor Results

```bash
# Terminal 1: Watch for the fix working
tail -f ~/Library/Logs/Zed/Zed.log | grep orphaned

# Terminal 2: Monitor FD usage
watch -n 1 "lsof -p \$(pgrep Zed) | wc -l"

# Terminal 3: Check for errors
tail -f ~/Library/Logs/Zed/Zed.log | grep -E "error|ERROR|400"
```

## Expected Results

### ❌ WITHOUT the Fix (main branch)

1. FD exhaustion occurs
2. Thread save fails/corrupts  
3. Next LLM request: **HTTP 400 API error**
4. Error: "tool_result without corresponding tool_use"
5. **Agent panel breaks** - cannot continue conversation

### ✅ WITH the Fix (PR #47229)

1. FD exhaustion occurs
2. Thread save fails/corrupts
3. Next LLM request: orphaned results detected
4. **Log shows:**
   ```
   Skipping orphaned tool_result with ID tool_abc123 (no corresponding tool_use in assistant message)
   ```
5. Request sent WITHOUT orphaned results
6. **Agent continues working** - no API error
7. Thread may be inconsistent but remains functional

## Verification Checklist

- [ ] Test server builds successfully
- [ ] FD limit lowered to 256 or less
- [ ] Zed configured with test server
- [ ] Can trigger many concurrent tool calls
- [ ] System hits FD exhaustion (verify with `lsof`)
- [ ] Logs show "Skipping orphaned tool_result" warning
- [ ] No HTTP 400 errors occur
- [ ] Agent continues functioning after FD exhaustion

## Success Criteria

✅ **Fix is working:**
- Debug logs show: `"Skipping orphaned tool_result with ID ..."`
- No HTTP 400 errors from LLM API
- Agent panel remains functional
- Conversation can continue despite state corruption

❌ **Fix is not working:**
- HTTP 400 errors from API
- Messages about invalid tool_result blocks
- Agent panel shows "API Error"
- Conversation stops after FD exhaustion

## Cleanup

```bash
# If you used ulimit method, reset FD limit
ulimit -n 10240

# Kill any running test servers (releases leaked FDs)
pkill mcp-fd-exhaustion-server

# Remove fd-test-server from Zed settings.json
```

**Note:** If you used `--fd-limit` flag, no cleanup needed - limit only affected that Zed process.

## Additional Resources

- **Test Server Details:** `crates/mcp_test_server/README.md`
- **Test Script:** `crates/mcp_test_server/test-fd-exhaustion.sh`
- **Testing Scenarios:** `crates/mcp_test_server/TESTING.md`
- **PR:** https://github.com/zed-industries/zed/pull/47229
- **Issue:** https://github.com/zed-industries/zed/issues/44840

## Technical Details

### Files Changed
- `crates/agent/src/thread.rs` (lines 490-560)
  - Added `included_tool_use_ids` tracking
  - Filter orphaned results before sending to API
  - Log warnings for orphaned results

### Unit Tests
Run the included unit tests:
```bash
cargo test -p agent test_to_request
```

Tests verify:
1. Normal tool use + result pairs work
2. Orphaned results are skipped
3. Mixed scenarios (some valid, some orphaned) filter correctly

## Troubleshooting

**Test server won't start:**
- Check the binary path in settings.json
- Verify it's executable: `chmod +x target/debug/mcp-fd-exhaustion-server`
- Run manually to see errors: `./target/debug/mcp-fd-exhaustion-server`

**Can't hit FD exhaustion:**
- Lower limit more: `--fd-limit 128` or `ulimit -n 128`
- Use `aggressive_leak` tool instead of others
- Ask for more concurrent calls (50-100)
- Verify the limit is actually set (check Zed startup logs)

**Not seeing orphaned results:**
- The bug requires actual DB save failure
- May need to trigger more aggressively
- Check SQLite is actually failing with `dtruss` or system logs

## Contact

For questions about this test setup, see the PR discussion:
https://github.com/zed-industries/zed/pull/47229
# MCP FD Exhaustion Test Server

This is a test server for validating the fix in PR #47229, which addresses orphaned `tool_result` blocks caused by file descriptor exhaustion.

## Purpose

This server deliberately leaks file descriptors to simulate the "too many open files" scenario that can cause Zed's agent thread state to become corrupted, leading to orphaned tool results and API errors.

## The Bug

When file descriptor exhaustion occurs:
1. LLM requests multiple concurrent tool uses
2. Each `ToolUse` is added to `message.content`
3. Tools start executing, opening files/sockets/connections
4. Some tools complete and add results to `message.tool_results`
5. "Too many open files" error hits
6. Zed auto-saves the thread state
7. SQLite can't open database file/journal due to FD exhaustion
8. Save operation fails or corrupts
9. On reload: mismatch between `content` (ToolUses) and `tool_results`
10. **Result**: Orphaned tool_result blocks that cause API 400 errors

## The Fix

PR #47229 adds tracking of which `tool_use` IDs are included in requests and filters out orphaned `tool_result` blocks, logging a warning instead of causing API failures.

## Building

```bash
cargo build --bin mcp-fd-exhaustion-server
```

## Running

```bash
cargo run --bin mcp-fd-exhaustion-server
```

## Configuration in Zed

Add to your `settings.json`:

```json
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

## Tools

### `leak_fd`
Leaks a single file descriptor.

**Input:**
```json
{
  "message": "optional message"
}
```

### `leak_many_fds`
Leaks multiple file descriptors at once.

**Input:**
```json
{
  "count": 10  // Number of FDs to leak
}
```

### `aggressive_leak`
The main test tool. Leaks 5 FDs on every call, plus 50 additional FDs on every 10th call.

**Input:**
```json
{
  "message": "optional message"
}
```

### `status`
Reports current FD leak statistics.

## Testing the Fix

### Step 1: Lower FD Limit

```bash
# Check current limit
ulimit -n

# Lower to trigger exhaustion faster (256 is good for testing)
ulimit -n 256
```

### Step 2: Build and Run Zed

```bash
cd /path/to/zed
git checkout fix/anthropic-tool-use-result-pairing-test
cargo build --release
cargo run --release
```

### Step 3: Configure the Test Server

Add the server to your Zed settings as shown above.

### Step 4: Trigger FD Exhaustion

In the Zed Agent Panel, use prompts like:

```
Please call the aggressive_leak tool 50 times
```

Or more naturally:

```
Please use the aggressive_leak tool repeatedly to test file descriptor handling
```

### Step 5: Monitor Logs

```bash
# Watch Zed logs for the orphaned result warning
tail -f ~/Library/Logs/Zed/Zed.log | grep -E "orphaned|EMFILE|ENFILE"

# Check FD usage
lsof -p $(pgrep -f Zed) | wc -l
```

## Expected Results

### Without the Fix (main branch)

1. FD exhaustion occurs
2. Thread save fails/corrupts
3. On next LLM request: **HTTP 400 API error**
4. Error message about "tool_result without corresponding tool_use"
5. **Agent panel breaks** - conversation cannot continue

### With the Fix (PR #47229)

1. FD exhaustion occurs
2. Thread save fails/corrupts
3. On next LLM request: orphaned results detected
4. **Debug log shows:**
   ```
   Skipping orphaned tool_result with ID tool_xxx (no corresponding tool_use in assistant message)
   ```
5. Request sent without orphaned results
6. **Agent continues working** - no API error
7. Thread state may be inconsistent but remains functional

## Verification

Check for these indicators:

✅ **Success (fix working):**
- Logs show "Skipping orphaned tool_result with ID ..."
- No HTTP 400 errors from LLM API
- Agent panel continues functioning after FD exhaustion
- Conversation can continue despite corrupted state

❌ **Failure (fix not working):**
- HTTP 400 errors from API
- Error messages about invalid tool_result blocks
- Agent panel shows "API Error" and stops responding
- No log messages about orphaned results

## Cleanup

```bash
# Reset FD limit
ulimit -n 10240

# Kill the server (it holds FDs until process exits)
pkill mcp-fd-exhaustion-server

# Clean up any leaked temp files
rm -rf /tmp/mcp-test-*
```

## Technical Details

The server uses standard library `File` handles that are deliberately not closed:

```rust
let file = File::open("/dev/null")?;
leaked_files.push(file);
// Intentionally never close the file
```

This causes the file descriptors to remain open for the lifetime of the process, eventually exhausting the available FD pool.

When Zed tries to save the thread state while FD-limited, SQLite operations may fail, leading to the corrupted state that the fix addresses.

## Related

- **PR**: https://github.com/zed-industries/zed/pull/47229
- **Issue**: https://github.com/zed-industries/zed/issues/44840
- **Fix location**: `crates/agent/src/thread.rs` lines 490-560
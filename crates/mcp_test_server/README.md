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
cargo build -p mcp_test_server
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

### `large_response`
Returns a very large response (default 100 KB) to force Zed to use file descriptors for buffering and processing.

**Input:**
```json
{
  "size_kb": 100  // Size in KB
}
```

**Note:** This tool affects the **MCP server's** FD usage. To exhaust **Zed's** FDs, you need to trigger many concurrent tool calls or use tools that cause Zed to open files.

## Important: How FD Quotas Work

**Critical Understanding:** Each process has its **own** file descriptor count up to the limit:

- When you set `--fd-limit 256` on Zed, it applies to the Zed process
- Child processes (like MCP servers) **inherit the same limit** but have **separate FD counts**
- An MCP server leaking 200 FDs exhausts **its own quota**, not Zed's quota
- Parent and child processes **do not share** a common FD pool

**What This Means:**
The MCP server's `leak_fd` tools exhaust the **MCP server process**, not Zed directly.

**How the Test Still Works:**
1. With `--fd-limit 256`, Zed has limited headroom
2. Zed opens many FDs during operation: project files, LSP servers, logs, MCP connections
3. When Zed spawns multiple MCP servers + tries to save to SQLite, **Zed itself runs out**
4. SQLite cannot open database file/journal → save fails/corrupts
5. This creates the orphaned tool_result scenario

**The Real Trigger:** Zed exhausting its own quota when handling:
- Multiple concurrent MCP server connections (each uses sockets/pipes)
- SQLite database writes (needs DB file + journal file)
- Project files, LSP servers, file watchers
- Log files and IPC mechanisms

## Testing the Fix

### Step 1: Build Zed and Test Server

```bash
cd /path/to/zed
git checkout fix/anthropic-tool-use-result-pairing-test

# Build test server
cargo build -p mcp_test_server

# Build Zed
cargo build --release
```

### Step 2: Run Zed with FD Limit

Use the built-in `--fd-limit` flag (test branch only):

```bash
cargo run --release -- --fd-limit 256
```

**On startup, you'll see:**
```
Setting file descriptor limit to: 256
FD limit set successfully: soft=256, hard=256
Current FD usage: 12 open, 244 remaining (of 256)
Note: Child processes (like MCP servers) have their own separate FD quota of 256
```

This shows you the current FD usage and helps you monitor when exhaustion might occur.

### Step 3: Configure the Test Server

Add the server to your Zed settings as shown above.

### Step 4: Trigger FD Exhaustion

In the Zed Agent Panel, use prompts that trigger **many concurrent tool calls**:

```
Please call the aggressive_leak tool 100 times
```

Or use multiple tools concurrently to force Zed to open many MCP connections:

```
Use the aggressive_leak tool 50 times while also calling the large_response tool 20 times
```

**Why concurrent matters:** When Zed handles multiple MCP tool calls simultaneously, it needs to:
- Maintain connections to the MCP server (sockets/pipes) for each call
- Buffer responses from multiple tools
- Keep SQLite database open for auto-save
- Handle project files and LSP servers
- This combination exhausts Zed's own FD quota, not just the MCP server's

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
# If you used ulimit method, reset FD limit
ulimit -n 10240

# Kill the server (it holds FDs until process exits)
pkill mcp-fd-exhaustion-server

# Clean up any leaked temp files
rm -rf /tmp/mcp-test-*
```

**Note:** The `--fd-limit` flag only affects the Zed process. No cleanup needed - the limit disappears when Zed exits.

### Understanding the Test Results

**FD Usage Breakdown:**
- **Zed process:** Opens files, DB, LSP connections, MCP pipes → counts toward Zed's 256 limit
- **MCP server process:** Opens files independently → has its own separate 256 limit
- **Test success:** When Zed's quota is exhausted (not the MCP server's), thread save fails

**Why the test works:**
Even though the MCP server has its own quota, triggering many concurrent tool calls forces Zed to:
1. Create many pipe/socket connections to the MCP server
2. Buffer responses from multiple calls
3. Attempt to save thread state to SQLite
4. All while maintaining project files, LSP connections, etc.
This pushes Zed to its 256 FD limit, causing the save failure that creates orphaned results.

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
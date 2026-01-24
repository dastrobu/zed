# Testing Guide for PR #47229: Orphaned Tool Results Fix

This document explains how to test the fix for orphaned `tool_result` blocks caused by file descriptor exhaustion.

## Quick Start

```bash
# 1. Checkout the test branch
git checkout fix/anthropic-tool-use-result-pairing-test

# 2. Build everything
cargo build -p mcp_test_server
cargo build --release

# 3. Configure test MCP server in settings.json (see below)

# 4. Run Zed with FD limit
cargo run --release -- --fd-limit 256

# 5. Test in Agent Panel
"Please call the aggressive_leak tool 50 times"

# 6. Verify the fix
tail -f ~/Library/Logs/Zed/Zed.log | grep orphaned
```

## What This Tests

**The Bug:** When file descriptor exhaustion occurs during concurrent tool execution, Zed's thread state can become corrupted in the database. This results in `tool_result` blocks being sent to the LLM API without their corresponding `tool_use` blocks, causing HTTP 400 errors and breaking the agent.

**The Fix:** PR #47229 adds defensive tracking to ensure only matched `tool_use`/`tool_result` pairs are sent to the API. Orphaned results are filtered out and logged as warnings instead of causing API failures.

## Important: How FD Quotas Work

**Key Understanding:** Each process has its **own** file descriptor count up to the limit:
- When you set `--fd-limit 256` on Zed, it applies to the Zed process
- Child processes (like MCP servers) inherit the same limit but have **separate FD counts**
- MCP server leaking FDs exhausts **its own** quota, not Zed's quota

**What This Means for Testing:**
- The MCP server's leaked FDs don't directly exhaust Zed's FD pool
- However, the test still works because:
  1. Zed opens many files during normal operation (project files, DB, logs, sockets)
  2. With `--fd-limit 256`, Zed has very few FDs available
  3. When Zed tries to spawn multiple MCP server processes + open DB files for saving, **Zed itself runs out**
  4. The MCP server tools failing due to their own FD exhaustion also creates error conditions
  5. Both contribute to the stress scenario that can corrupt thread state

**The Real Trigger:** Zed exhausting its own FDs when trying to:
- Open SQLite database file for thread save
- Open SQLite journal file
- Create IPC connections
- Handle concurrent MCP server connections
- Open project files during tool execution

## Background: Why File Descriptor Exhaustion Triggers API Errors

### The Complete Chain of Events

1. **LLM requests multiple concurrent tool uses** (e.g., "search these 10 files")
   - Each `ToolUse` is immediately added to `message.content` array when streamed from the LLM
   - Tool execution Tasks are spawned to run concurrently

2. **Tools start executing** - each opens file descriptors:
   - MCP server connections (sockets)
   - File operations in the tools
   - Database connections for state tracking
   - IPC mechanisms

4. **Some tools complete successfully**
   - Their results are added to `message.tool_results` HashMap
   - Zed triggers an auto-save observer (happens on every thread update)

5. **"Too many open files" OS error occurs** (EMFILE/ENFILE)
   - With `--fd-limit 256` active, Zed quickly approaches its limit from:
     - Open project files and buffers
     - Multiple MCP server child process connections
     - IPC sockets and pipes
     - Log files and temporary files
     - LSP server connections
   - Remaining tool executions fail to open files
   - More critically: **Zed itself cannot open the SQLite database file or journal file** for saving
</text>
</function_calls>

<old_text line=68>
### Why This Is a Real-World Issue

This isn't a theoretical bug - it happens in production when:
- Users run many concurrent agent operations
- System is under memory/resource pressure
- MCP servers open many files (file search, code analysis, etc.)
- Long-running agent sessions accumulate open file descriptors
- Background processes consume available FDs

The corruption persists across Zed restarts because it's stored in the SQLite database.

5. **Thread auto-save attempts to persist state**
   - Located in `crates/agent/src/db.rs` (`save_thread_sync`)
   - Serializes the entire thread as a single JSON blob
   - Calls SQLite to write to `threads.db`

6. **Database write fails or partially succeeds**
   - SQLite needs to open both the DB file and a journal file
   - Without available file descriptors, the write operation fails
   - This can result in:
     - Complete write failure (thread state not saved)
     - Partial write (JSON corrupted or incomplete)
     - Stale state persisted (outdated content/tool_results mapping)

7. **State corruption occurs**
   - The in-memory `message.content` array may have different `ToolUse` entries than what got saved
   - The in-memory `message.tool_results` HashMap may have different results than what got saved
   - On the next save attempt or on reload: mismatch between the two

8. **Thread gets reloaded from database** (on app restart or thread restore)
   - Located in `crates/agent/src/db.rs` (`DbThread::from_json`)
   - Loads both `content` array and `tool_results` HashMap from the JSON blob
   - Due to corruption: some `tool_result` entries have no corresponding `ToolUse` in `content`

9. **Next LLM turn builds request** (`AgentMessage::to_request()`)
   - Iterates through `content` to build assistant message
   - **Key logic:** Only includes `ToolUse` if it has a result (line 518):
     ```rust
     if self.tool_results.contains_key(&tool_use.id) {
         assistant_message.content.push(tool_use);
         included_tool_use_ids.insert(tool_use.id);
     }
     ```
   - Then includes ALL `tool_result` entries from `tool_results` HashMap
   - **Problem:** If a `tool_result` exists but its `ToolUse` wasn't in `content`, it becomes orphaned

10. **API rejects the malformed request**
    - LLM providers (Anthropic, OpenAI, etc.) require that every `tool_result` in a user message has a corresponding `tool_use` in the previous assistant message
    - Returns HTTP 400 error: "tool_result without corresponding tool_use"
    - Agent panel breaks and cannot continue the conversation

### Why This Is a Real-World Issue

This isn't a theoretical bug - it happens in production when:
- Users run many concurrent agent operations
- System is under memory/resource pressure
- MCP servers open many files (file search, code analysis, etc.)
- Long-running agent sessions accumulate open file descriptors
- Background processes consume available FDs

The corruption persists across Zed restarts because it's stored in the SQLite database.

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

**Why this is better:**
- ✅ Only affects the Zed process (child processes inherit the limit but have separate quotas)
- ✅ Cross-platform (macOS and Linux)
- ✅ No cleanup required (limit dies with the process)
- ✅ Safer for your development environment
- ✅ Shows FD usage logging so you can monitor exhaustion

**Alternative:** Press **F5** in Zed to debug - the debug configuration already has `--fd-limit 256` set.

**Important:** The limit of 256 means:
- Zed can open up to 256 FDs
- Each child MCP server can also open up to 256 FDs (separate quota)
- The test works because Zed itself exhausts its own quota when spawning multiple servers + opening DB files

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

# Terminal 2: Monitor Zed's FD usage (not MCP server's)
watch -n 1 "lsof -p \$(pgrep Zed) | wc -l"

# Terminal 3: Check for errors
tail -f ~/Library/Logs/Zed/Zed.log | grep -E "error|ERROR|400|EMFILE"

# Terminal 4: Monitor ALL child processes
watch -n 1 "pgrep -P \$(pgrep Zed) | xargs -I {} sh -c 'echo \"PID {}: \$(lsof -p {} 2>/dev/null | wc -l) FDs\"'"
```

**What to look for:**
- Zed's own FD count approaching 256
- "EMFILE" or "Too many open files" errors in logs
- Multiple MCP server child processes spawned
- Zed startup logs showing FD usage and remaining count

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
# Kill any running test servers (releases leaked FDs)
pkill mcp-fd-exhaustion-server

# Remove fd-test-server from Zed settings.json
```

**Note:** No FD limit cleanup needed! The `--fd-limit` flag only affects the Zed process, and the limit disappears when Zed exits.

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
- Lower limit more: `--fd-limit 128` (less headroom for Zed)
- Use `aggressive_leak` tool instead of others
- Ask for more concurrent calls (100+) to force Zed to spawn many MCP connections
- Open a large project in Zed first (uses more FDs for LSP, file watching, etc.)
- Verify the limit is set correctly by checking Zed's startup output:
  ```
  Setting file descriptor limit to: 256
  FD limit set successfully: soft=256, hard=256
  Current FD usage: 12 open, 244 remaining (of 256)
  ```
- Remember: Child MCP servers have separate quotas, so you need Zed itself to exhaust its quota

**Not seeing orphaned results:**
- The bug requires actual DB save failure
- May need to trigger more aggressively
- Check SQLite is actually failing with `dtruss` or system logs

## Contact

For questions about this test setup, see the PR discussion:
https://github.com/zed-industries/zed/pull/47229
# Test Scenario: Orphaned Tool Results via File Descriptor Exhaustion

## Overview
Test fix for PR #47229 using file descriptor exhaustion to trigger orphaned tool_result bug.

## The Bug
When thread state corrupts (FD exhaustion), tool_result blocks exist without tool_use blocks.
LLM API rejects with HTTP 400 error.

## The Fix
PR #47229 tracks tool_use IDs and filters orphaned tool_result blocks.

## How FD Exhaustion Causes This

1. LLM requests multiple concurrent tool uses
2. Each ToolUse added to message.content
3. Tool execution starts - opens files/sockets/DB
4. Some tools complete, add results
5. "Too many open files" error hits
6. Zed auto-saves thread
7. SQLite cant open DB due to FD exhaustion
8. Save corrupts
9. Reload: mismatch between content and tool_results

## Test Setup

### Modify Go MCP Server

```go
var openFiles []*os.File

func handleBarTool() {
    f, _ := os.Open("/dev/null")
    openFiles = append(openFiles, f)  // Leak FD
    
    if callCount%10 == 0 {
        for i := 0; i < 50; i++ {
            if f, err := os.Open("/dev/null"); err == nil {
                openFiles = append(openFiles, f)
            }
        }
    }
}
```

## Test Steps

```bash
# Lower FD limit
ulimit -n 256

# Build Zed
cd zed
cargo build --release

# Configure MCP in settings.json
# Run Zed

# In Agent Panel:
"Please call the bar tool 100 times"

# Monitor logs
tail -f ~/Library/Logs/Zed/Zed.log | grep orphaned
```

## Expected Results

WITHOUT FIX:
- FD exhaustion
- HTTP 400 API error
- Agent breaks

WITH FIX:
- FD exhaustion
- Log: "Skipping orphaned tool_result with ID xxx"
- Agent continues working

## Verification

```bash
# Check FD usage
lsof -p $(pgrep Zed) | wc -l

# Watch for exhaustion
dtruss -p $(pgrep Zed) 2>&1 | grep EMFILE
```

## Success Criteria

✅ Logs show "Skipping orphaned tool_result"
✅ No API 400 errors
✅ Agent keeps working

❌ HTTP 400 from API
❌ Agent shows error
❌ Conversation stops

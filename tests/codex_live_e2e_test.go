package codex_test

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

const liveTurnTimeout = 8 * time.Minute

type mcpCallRecord struct {
	Server    string         `json:"server"`
	Tool      string         `json:"tool"`
	Arguments map[string]any `json:"arguments"`
	Result    map[string]any `json:"result"`
}

func readMCPCalls(path string) []mcpCallRecord {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []mcpCallRecord
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var r mcpCallRecord
		if err := json.Unmarshal(sc.Bytes(), &r); err == nil {
			out = append(out, r)
		}
	}
	return out
}

func writeCodexHomeConfig(t *testing.T, codexHome, gatewayBaseURL, model, mcpBin, mcpLog, envKey string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(codexHome, "rules"), 0o755); err != nil {
		t.Fatal(err)
	}
	baseURL := strings.TrimRight(gatewayBaseURL, "/") + "/v1"
	cfg := fmt.Sprintf(`model = %q
model_context_window = 131072
model_auto_compact_token_limit = 98304
model_provider = "gateway"

[model_providers.gateway]
name = "Local test gateway"
base_url = %q
env_key = %q
wire_api = "responses"

[mcp_servers.test]
command = %q
args = []
default_tools_approval_mode = "auto"
required = true

[mcp_servers.test.env]
BCN_MCP_LOG = %q
`, model, baseURL, envKey, mcpBin, mcpLog)
	if err := os.WriteFile(filepath.Join(codexHome, "config.toml"), []byte(cfg), 0o600); err != nil {
		t.Fatalf("write codex config.toml: %v", err)
	}
	rules := "prefix_rule(pattern=[\"bcc\"], decision=\"prompt\")\n"
	if err := os.WriteFile(filepath.Join(codexHome, "rules", "bcc.rules"), []byte(rules), 0o644); err != nil {
		t.Fatalf("write codex bcc.rules: %v", err)
	}
}

func TestLiveCodexE2E(t *testing.T) {
	scenario := strings.TrimSpace(os.Getenv("BCN_E2E_SCENARIO"))
	gatewayURL := strings.TrimSpace(os.Getenv("AI_GATEWAY_BASE_URL"))
	apiKey := strings.TrimSpace(os.Getenv("AI_API_KEY"))
	model := strings.TrimSpace(os.Getenv("BCN_E2E_MODEL"))
	if scenario == "" || gatewayURL == "" || apiKey == "" || model == "" {
		if os.Getenv("BCN_REQUIRE_LIVE_E2E") == "1" {
			t.Fatalf("missing required env: BCN_E2E_SCENARIO=%q AI_GATEWAY_BASE_URL=%q BCN_E2E_MODEL=%q (AI_API_KEY set=%v)",
				scenario, gatewayURL, model, apiKey != "")
		}
		t.Skip("live Codex E2E environment not configured")
	}

	bcnBin := resolveBCNBin(t)
	artDir := artifactDir(t, "codex-"+scenario)
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	codexHome := filepath.Join(tmp, "codex-home")
	const agentID = "assistant"
	workspaceDir := filepath.Join(homeDir, "workspaces", agentID)
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}

	mcpBin := buildGoBinary(t, filepath.Join("fixtures", "mcp"), filepath.Join(tmp, "mcp-test"))
	mcpLog := filepath.Join(artDir, "mcp.jsonl")
	envKey := "AI_API_KEY"
	if scenario == "mcp-once" {
		envKey = "OPENAI_API_KEY"
	}
	writeCodexHomeConfig(t, codexHome, gatewayURL, model, mcpBin, mcpLog, envKey)

	pluginZip := filepath.Join(tmp, "harness-codex.zip")
	channelZip := filepath.Join(tmp, "channel-e2e.zip")
	packagePluginDir(t, "..", pluginZip)
	packagePluginDir(t, filepath.Join("fixtures", "channel"), channelZip)
	installPluginZip(t, bcnBin, homeDir, pluginZip)
	installPluginZip(t, bcnBin, homeDir, channelZip)

	chSrv := newE2EChannelServer()
	defer chSrv.Close()

	nodeEnv := map[string]string{
		"CODEX_HOME":          codexHome,
		"AI_GATEWAY_BASE_URL": gatewayURL,
		"AI_API_KEY":          apiKey,
	}
	cfgOpt := codexConfigOptions{
		AgentID:     agentID,
		ChannelURL:  chSrv.URL(),
		Mode:        "session",
		Sandbox:     "workspace-write",
		IdleTimeout: 0,
		Model:       model,
	}
	if scenario == "mcp-once" {
		nodeEnv["OPENAI_API_KEY"] = "inherited-key-overridden-by-config"
		cfgOpt.APIKey = apiKey
	}
	if scenario == "full-access" {
		cfgOpt.Sandbox = "danger-full-access"
	}
	if scenario == "background" {
		cfgOpt.IdleTimeout = 2
	}
	if scenario == "refresh" {
		_ = os.WriteFile(filepath.Join(workspaceDir, "AGENTS.md"), []byte("Keep replies clear.\n"), 0o644)
	}
	writeCodexNodeConfig(t, homeDir, cfgOpt)

	// Verify real codex CLI inspection (CLI summary + online agents.inspect JSON for test/get_value).
	inspOut := runBCN(t, bcnBin, homeDir, nodeEnv, "agent", "inspect", agentID)
	t.Logf("bcn agent inspect:\n%s", inspOut)
	if !strings.Contains(inspOut, "true") {
		t.Fatalf("expected available=true in bcn agent inspect:\n%s", inspOut)
	}

	var activeNode *runningBCN
	nodeRunIdx := 0
	var previewPort int

	startNode := func() *runningBCN {
		nodeRunIdx++
		logPath := filepath.Join(artDir, fmt.Sprintf("node-%d.log", nodeRunIdx))
		n := startBCNNode(t, bcnBin, homeDir, nodeEnv, logPath)
		if _, err := n.waitEvent(30*time.Second, 0, func(ev auditEvent) bool {
			return ev.Type == "channel.connected" && ev.PluginID == "channel-e2e"
		}); err != nil {
			t.Fatalf("wait channel.connected: %v\nlog:\n%s", err, n.LogText())
		}
		activeNode = n
		return n
	}

	stopAndVerifyClean := func() {
		if activeNode == nil {
			return
		}
		n := activeNode
		activeNode = nil
		n.dumpEventsToFile(filepath.Join(artDir, fmt.Sprintf("audit-%d.jsonl", nodeRunIdx)))
		children := linuxDescendants(n.PID())
		if err := n.Stop(); err != nil {
			t.Logf("node stop returned: %v", err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			alive := 0
			for _, c := range children {
				if pidAliveLinux(c.PID) {
					alive++
				}
			}
			if alive == 0 {
				break
			}
			time.Sleep(150 * time.Millisecond)
		}
		for _, c := range children {
			if pidAliveLinux(c.PID) {
				t.Fatalf("leaked child process after bcn stop: pid=%d cmd=%q", c.PID, c.Cmdline)
			}
		}
	}

	restartFreshDB := func() {
		stopAndVerifyClean()
		for _, suffix := range []string{"", "-wal", "-shm"} {
			_ = os.Remove(filepath.Join(homeDir, "node.sqlite3"+suffix))
		}
		startNode()
	}

	t.Cleanup(func() {
		stopAndVerifyClean()
		if previewPort > 0 {
			conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", previewPort), time.Second)
			if err == nil {
				_ = conn.Close()
				t.Errorf("preview port %d still listening after node stop", previewPort)
			}
		}
	})

	startNode()

	reports, err := activeNode.inspectHarnesses(agentID)
	if err != nil || len(reports) == 0 || !reports[0].Result.Available {
		t.Fatalf("online agents.inspect failed: reports=%+v err=%v", reports, err)
	}
	foundMCPTool := false
	for _, s := range reports[0].Result.MCPServers {
		if s.Name == "test" {
			for _, tool := range s.Tools {
				if tool.Name == "get_value" {
					foundMCPTool = true
				}
			}
		}
	}
	if !foundMCPTool {
		t.Fatalf("expected MCP server test/get_value in online agents.inspect: %+v", reports[0].Result)
	}

	type turnResult struct {
		SessionID        string
		ProviderThreadID string
		TurnID           string
		Events           []auditEvent
		Outbound         []outboundMsg
		Prompts          []promptRecord
		Steered          bool
	}

	runTurn := func(body string, steer bool, stopAtStarted bool) turnResult {
		afterSeq := activeNode.lastEventSeq()
		outIdx := chSrv.OutboundCount()
		prIdx := chSrv.PromptsCount()
		msgID := "msg-" + randomHex(t, 6)
		chSrv.PushDM(msgID, body)

		// Approve DM if this is the first turn on a fresh DB.
		approvedAt := time.Now().Add(15 * time.Second)
		go func() {
			for time.Now().Before(approvedAt) {
				if activeNode != nil && activeNode.approvePendingReviews(agentID) > 0 {
					return
				}
				time.Sleep(200 * time.Millisecond)
			}
		}()

		steered := false
		deadline := time.Now().Add(liveTurnTimeout)
		var terminal auditEvent
		for time.Now().Before(deadline) {
			evs, err := activeNode.eventsSince(afterSeq)
			if err == nil {
				for _, ev := range evs {
					if steer && !steered && (ev.Type == "harness.content_delta" || ev.Type == "harness.tool_started") {
						chSrv.PushDM("steer-"+randomHex(t, 4), "Please keep your reply brief.")
						steered = true
					}
					if stopAtStarted && ev.Type == "harness.turn_started" {
						terminal = ev
						break
					}
					if ev.Type == "harness.turn_completed" || ev.Type == "harness.turn_failed" || ev.Type == "harness.turn_cancelled" {
						terminal = ev
						break
					}
				}
			}
			if terminal.Seq > 0 {
				break
			}
			time.Sleep(300 * time.Millisecond)
		}
		if terminal.Seq == 0 {
			t.Fatalf("timed out waiting for turn completion (body=%q)\nlog:\n%s", body, activeNode.LogText())
		}
		if !stopAtStarted && terminal.Type != "harness.turn_completed" {
			t.Fatalf("expected harness.turn_completed, got %s: %+v", terminal.Type, terminal.Payload)
		}
		allEvs, _ := activeNode.eventsSince(0)
		turnEvs, _ := activeNode.eventsSince(afterSeq)
		sid := fmt.Sprint(terminal.Payload["sessionId"])
		var provThread string
		for _, ev := range allEvs {
			if (ev.Type == "harness.session.started" || ev.Type == "harness.session_started") && fmt.Sprint(ev.Payload["sessionId"]) == sid {
				if pt := fmt.Sprint(ev.Payload["providerThreadId"]); pt != "" && pt != "<nil>" {
					provThread = pt
				}
			}
		}
		return turnResult{
			SessionID:        sid,
			ProviderThreadID: provThread,
			TurnID:           fmt.Sprint(terminal.Payload["turnId"]),
			Events:           turnEvs,
			Outbound:         chSrv.OutboundSince(outIdx),
			Prompts:          chSrv.PromptsSince(prIdx),
			Steered:          steered,
		}
	}

	queryMCP := func(key string, scope string) turnResult {
		if scope != "" {
			chSrv.SetDecisionFunc(func(pr promptRecord) string {
				if hasPromptAction(pr, "approve:"+scope) {
					return "approve:" + scope
				}
				return "approve:once"
			})
		} else {
			chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		}
		beforeCalls := len(readMCPCalls(mcpLog))
		reqText := fmt.Sprintf(`请使用工具调用 mcp__test__get_value，参数为 {"key": %q}，读取测试值。`, key)
		var lastRes turnResult
		for retry := 0; retry <= 6; retry++ {
			msg := reqText
			if retry > 0 {
				msg = fmt.Sprintf(`还没有收到实际工具结果。请使用工具调用 mcp__test__get_value，参数为 {"key": %q}，读取测试值。`, key)
			}
			lastRes = runTurn(msg, false, false)
			calls := readMCPCalls(mcpLog)
			if len(calls) > beforeCalls {
				matched := false
				for _, c := range calls[beforeCalls:] {
					if c.Server == "test" && c.Tool == "get_value" && fmt.Sprint(c.Arguments["key"]) == key && fmt.Sprint(c.Result["value"]) == "MCP_OK" {
						matched = true
					}
				}
				if !matched {
					t.Fatalf("MCP calls did not match key=%q: %+v", key, calls[beforeCalls:])
				}
				if scope == "" {
					if len(lastRes.Prompts) > 0 {
						t.Fatalf("expected remembered approval without prompt for key=%q, got prompts=%+v", key, lastRes.Prompts)
					}
				} else {
					foundScope := false
					for _, pr := range lastRes.Prompts {
						if pr.DecisionAction == "approve:"+scope {
							foundScope = true
						}
					}
					if !foundScope {
						t.Fatalf("expected prompt approved with scope %q for key=%q, got prompts=%+v", scope, key, lastRes.Prompts)
					}
				}
				return lastRes
			}
		}
		t.Fatalf("MCP tool test/get_value was never invoked for key=%q", key)
		return lastRes
	}

	switch scenario {
	case "mcp-once":
		queryMCP("once", "once")

	case "mcp-session":
		first := queryMCP("session-first", "session")
		second := queryMCP("session-second", "")
		if first.SessionID != second.SessionID || first.ProviderThreadID != second.ProviderThreadID {
			t.Fatalf("expected same session/thread across mcp-session turns: first=(%s,%s) second=(%s,%s)",
				first.SessionID, first.ProviderThreadID, second.SessionID, second.ProviderThreadID)
		}

	case "mcp-always":
		first := queryMCP("always-session", "session")
		_ = os.WriteFile(filepath.Join(workspaceDir, "AGENTS.md"), []byte("Keep replies concise.\n"), 0o644)
		restartFreshDB()
		refreshed := queryMCP("always-first", "always")
		if refreshed.ProviderThreadID == first.ProviderThreadID {
			t.Fatalf("expected new provider thread after AGENTS.md change + restart")
		}
		_ = os.WriteFile(filepath.Join(workspaceDir, "AGENTS.md"), []byte("Keep replies brief and clear.\n"), 0o644)
		restartFreshDB()
		remembered := queryMCP("always-second", "")
		if remembered.ProviderThreadID == refreshed.ProviderThreadID {
			t.Fatalf("expected new provider thread after second AGENTS.md change + restart")
		}

	case "bcc":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		first := runTurn("Please remind me to drink some water in five seconds.", true, false)
		sawSteer := false
		sawCmdApproval := false
		for _, ev := range first.Events {
			if ev.Type == "harness.turn.steer.accepted" {
				sawSteer = true
			}
			if ev.Type == "approval.requested" && fmt.Sprint(ev.Payload["action"]) == "command_execution" {
				sawCmdApproval = true
			}
		}
		if !sawCmdApproval {
			t.Fatalf("expected command_execution approval in bcc scenario")
		}
		if !first.Steered || !sawSteer {
			t.Fatalf("expected mid-turn steering accepted (steered=%v sawSteer=%v)", first.Steered, sawSteer)
		}

		rejectedOnce := false
		chSrv.SetDecisionFunc(func(pr promptRecord) string {
			if !rejectedOnce {
				rejectedOnce = true
				return "deny"
			}
			return "approve:once"
		})
		continued := runTurn("What reminder did I ask you to set? Please reply to me.", false, false)
		if continued.ProviderThreadID != first.ProviderThreadID {
			t.Fatalf("expected same provider thread on continued turn: %s vs %s", continued.ProviderThreadID, first.ProviderThreadID)
		}
		sawRejected := false
		for _, ev := range continued.Events {
			if ev.Type == "approval.decided" && strings.HasPrefix(fmt.Sprint(ev.Payload["decision"]), "deny") {
				sawRejected = true
			}
		}
		if !sawRejected {
			t.Fatalf("expected rejected tool approval in continued turn")
		}

	case "full-access":
		res := runTurn(
			"I'm reading this chat on my phone and cannot view our workspace. "+
				"Please save a short note about drinking enough water to full-access-note.txt in the workspace, "+
				"then send me a message here with the filename and a one-sentence summary.",
			false, false,
		)
		noteBytes, err := os.ReadFile(filepath.Join(workspaceDir, "full-access-note.txt"))
		if err != nil || strings.TrimSpace(string(noteBytes)) == "" {
			t.Fatalf("expected non-empty full-access-note.txt: err=%v content=%q", err, string(noteBytes))
		}
		if len(res.Outbound) == 0 {
			t.Fatalf("expected outbound reply via bcc message send in full-access scenario")
		}
		if len(res.Prompts) > 0 {
			t.Fatalf("expected zero approval prompts in danger-full-access mode, got %d", len(res.Prompts))
		}

	case "recovery":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		first := runTurn("Please remember that I prefer brief replies.", false, false)
		var appServerPID int
		for _, c := range linuxDescendants(activeNode.PID()) {
			if strings.Contains(c.Cmdline, "app-server") && c.Env["CODEX_HOME"] == codexHome {
				appServerPID = c.PID
				break
			}
		}
		if appServerPID == 0 {
			t.Fatalf("could not locate codex app-server child process")
		}
		_ = syscall.Kill(appServerPID, syscall.SIGTERM)
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) && pidAliveLinux(appServerPID) {
			time.Sleep(100 * time.Millisecond)
		}
		if pidAliveLinux(appServerPID) {
			_ = syscall.Kill(appServerPID, syscall.SIGKILL)
		}
		recovered := runTurn("What reply style did I ask for? Please reply to me.", false, false)
		if recovered.ProviderThreadID != first.ProviderThreadID {
			t.Fatalf("expected recovery to resume provider thread %q, got %q", first.ProviderThreadID, recovered.ProviderThreadID)
		}
		var newPID int
		for _, c := range linuxDescendants(activeNode.PID()) {
			if strings.Contains(c.Cmdline, "app-server") && c.Env["CODEX_HOME"] == codexHome {
				newPID = c.PID
				break
			}
		}
		if newPID == 0 || newPID == appServerPID {
			t.Fatalf("expected new codex app-server PID after recovery (old=%d new=%d)", appServerPID, newPID)
		}
		runTurn("Tell me briefly what you can help me with.", false, true)

	case "refresh":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		first := runTurn("Please remember that I prefer brief replies.", false, false)
		if err := os.WriteFile(filepath.Join(workspaceDir, "AGENTS.md"), []byte("Keep replies concise.\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * time.Second)
		refreshed := runTurn("What reply style did I ask for? Please reply to me.", false, true)
		if refreshed.ProviderThreadID == first.ProviderThreadID {
			t.Fatalf("expected fresh provider thread after AGENTS.md update (still %q)", refreshed.ProviderThreadID)
		}

	case "background":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		previewPort = ln.Addr().(*net.TCPAddr).Port
		_ = ln.Close()

		filename := "preview-" + randomHex(t, 6) + ".txt"
		expected := "BCN preview " + randomHex(t, 6) + "\n"
		if err := os.WriteFile(filepath.Join(workspaceDir, filename), []byte(expected), 0o644); err != nil {
			t.Fatal(err)
		}

		checkPreview := func() {
			t.Helper()
			resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/%s", previewPort, filename))
			if err != nil {
				t.Fatalf("GET preview failed: %v", err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			if resp.StatusCode != 200 || string(body) != expected {
				t.Fatalf("unexpected preview response: status=%d body=%q", resp.StatusCode, string(body))
			}
		}

		first := runTurn(
			fmt.Sprintf(
				"Please start a local HTTP preview for the current folder. Run "+
					"`python3 -m http.server %d --bind 127.0.0.1` "+
					"as the foreground command in a persistent tool terminal, without a trailing `&`. "+
					"Keep that terminal running after this turn. "+
					"Check that the preview responds, then use `bcc message send` to send its address to this conversation.",
				previewPort,
			),
			false, false,
		)
		if len(first.Outbound) == 0 {
			t.Fatalf("expected preview URL sent via bcc message send")
		}
		checkPreview()

		// Sleep past idle_timeout=2s; hasBackgroundJob must keep the session alive.
		time.Sleep(4 * time.Second)
		checkPreview()

		continued := runTurn(
			"Is the preview still available? Please check it, keep the existing server running, "+
				"and use `bcc message send` to send its address to this conversation.",
			false, false,
		)
		if continued.ProviderThreadID != first.ProviderThreadID {
			t.Fatalf("expected background session preserved across idle timeout: %s vs %s", continued.ProviderThreadID, first.ProviderThreadID)
		}
		checkPreview()

	default:
		t.Fatalf("unknown BCN_E2E_SCENARIO=%q", scenario)
	}
}

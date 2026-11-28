package codex_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOfflinePackageAndInspect(t *testing.T) {
	bcnBin := resolveBCNBin(t)
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	pluginZip := filepath.Join(tmp, "harness-codex.zip")

	entries := packagePluginDir(t, "..", pluginZip)
	if len(entries) == 0 {
		t.Fatal("packaged plugin.zip has no entries")
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry, "tests/") || strings.HasPrefix(entry, ".") {
			t.Fatalf("unexpected non-runtime file leaked into plugin.zip: %s", entry)
		}
	}

	insp := runBCN(t, bcnBin, homeDir, nil, "plugin", "inspect", "--dry-run", pluginZip)
	if !strings.Contains(insp, "harness-codex") {
		t.Fatalf("expected harness-codex in inspect output:\n%s", insp)
	}
	installPluginZip(t, bcnBin, homeDir, pluginZip)
}

func TestOfflineFakeCLIE2E(t *testing.T) {
	bcnBin := resolveBCNBin(t)
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	codexHome := filepath.Join(tmp, "codex-home")
	if err := os.MkdirAll(codexHome, 0o755); err != nil {
		t.Fatal(err)
	}

	fakeCLI := buildGoBinary(t, filepath.Join("fixtures", "fakecli"), filepath.Join(tmp, "fake-codex"))
	pluginZip := filepath.Join(tmp, "harness-codex.zip")
	channelZip := filepath.Join(tmp, "channel-e2e.zip")
	packagePluginDir(t, "..", pluginZip)
	packagePluginDir(t, filepath.Join("fixtures", "channel"), channelZip)

	installPluginZip(t, bcnBin, homeDir, pluginZip)
	installPluginZip(t, bcnBin, homeDir, channelZip)
	patchReceiptOverrides(t, homeDir, "harness-codex", receiptOverrides{
		ExecOverrides: map[string]string{"codex": fakeCLI},
	})

	chSrv := newE2EChannelServer()
	defer chSrv.Close()

	const agentID = "assistant"
	writeCodexNodeConfig(t, homeDir, codexConfigOptions{
		AgentID:     agentID,
		ChannelURL:  chSrv.URL(),
		Mode:        "session",
		Sandbox:     "workspace-write",
		IdleTimeout: 0,
		Model:       "fake-codex-1",
	})

	env := map[string]string{"CODEX_HOME": codexHome}

	// 1. Offline bcn agent inspect & bcn agent quota against fake codex app-server.
	inspectOut := runBCN(t, bcnBin, homeDir, env, "agent", "inspect", agentID)
	for _, want := range []string{"harness-codex", "true", "0.169.0"} {
		if !strings.Contains(inspectOut, want) {
			t.Fatalf("expected %q in bcn agent inspect output:\n%s", want, inspectOut)
		}
	}

	quotaOut := runBCN(t, bcnBin, homeDir, env, "agent", "quota", agentID)
	if !strings.Contains(quotaOut, "75%") || !strings.Contains(quotaOut, "90%") {
		t.Fatalf("expected 75%% and 90%% remaining quota in bcn agent quota output:\n%s", quotaOut)
	}

	// 2. Live bcn run turn with approval prompt -> real injected `bcc message send` -> clean shutdown.
	artDir := artifactDir(t, "offline-codex")
	node := startBCNNode(t, bcnBin, homeDir, env, filepath.Join(artDir, "node.log"))
	defer func() {
		node.dumpEventsToFile(filepath.Join(artDir, "audit.jsonl"))
		_ = node.Stop()
	}()

	if _, err := node.waitEvent(20*time.Second, 0, func(ev auditEvent) bool {
		return ev.Type == "channel.connected" && ev.PluginID == "channel-e2e"
	}); err != nil {
		t.Fatalf("wait channel.connected: %v\nlog:\n%s", err, node.LogText())
	}

	reports, err := node.inspectHarnesses(agentID)
	if err != nil || len(reports) != 1 || !reports[0].Result.Available || reports[0].Result.Version != "0.169.0" {
		t.Fatalf("unexpected online agents.inspect report: reports=%+v err=%v", reports, err)
	}
	hasModel, hasMCPTool := false, false
	for _, m := range reports[0].Result.Models {
		if m.ID == "fake-codex-1" {
			hasModel = true
		}
	}
	for _, s := range reports[0].Result.MCPServers {
		if s.Name == "test" {
			for _, tool := range s.Tools {
				if tool.Name == "get_value" {
					hasMCPTool = true
				}
			}
		}
	}
	if !hasModel || !hasMCPTool {
		t.Fatalf("expected model fake-codex-1 and MCP test/get_value in agents.inspect: %+v", reports[0].Result)
	}

	chSrv.PushDM("offline-msg-1", "Please say hello via bcc.")
	approveDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(approveDeadline) {
		if node.approvePendingReviews(agentID) > 0 {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}

	if _, err := node.waitEvent(30*time.Second, 0, func(ev auditEvent) bool {
		return ev.Type == "harness.turn_completed" && ev.PluginID == "harness-codex"
	}); err != nil {
		t.Fatalf("wait harness.turn_completed: %v\nlog:\n%s", err, node.LogText())
	}

	if chSrv.PromptsCount() == 0 {
		t.Fatalf("expected at least one interactive approval prompt in workspace-write mode")
	}
	outs := chSrv.OutboundSince(0)
	foundReply := false
	for _, m := range outs {
		if strings.Contains(m.Body, "FAKE_CODEX_OK") {
			foundReply = true
			break
		}
	}
	if !foundReply {
		t.Fatalf("expected FAKE_CODEX_OK via real bcc message send, got outbound=%+v", outs)
	}

	evs, err := node.eventsSince(0)
	if err != nil {
		t.Fatalf("eventsSince: %v", err)
	}
	hasUsage, hasApprovalDecided := false, false
	for _, ev := range evs {
		if ev.Type == "harness.usage_updated" {
			hasUsage = true
		}
		if ev.Type == "approval.decided" && ev.Payload["decision"] == "approve:once" {
			hasApprovalDecided = true
		}
	}
	if !hasUsage {
		t.Fatalf("expected harness.usage_updated event")
	}
	if !hasApprovalDecided {
		t.Fatalf("expected approval.decided=approve:once event")
	}

	// Verify clean teardown and zero lingering child processes on Linux.
	beforeStopChildren := linuxDescendants(node.PID())
	if err := node.Stop(); err != nil {
		t.Fatalf("node.Stop returned error: %v", err)
	}
	for _, child := range beforeStopChildren {
		if pidAliveLinux(child.PID) {
			t.Fatalf("leaked child process after bcn stop: pid=%d cmd=%q", child.PID, child.Cmdline)
		}
	}
}

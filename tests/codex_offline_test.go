package codex_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/open-bazaar/test-bazaar-plugin/fixtures"
	"github.com/open-bazaar/test-bazaar-plugin/pkg/bcnacceptance"
)

func TestOfflineFakeCLIE2E(t *testing.T) {
	bcnBin, err := bcnacceptance.ResolveBCNBin("")
	if err != nil {
		t.Fatal(err)
	}
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	codexHome := filepath.Join(tmp, "codex-home")
	if err := os.MkdirAll(codexHome, 0o755); err != nil {
		t.Fatal(err)
	}

	fakeCLI, err := bcnacceptance.BuildGoBinary(filepath.Join("fixtures", "fakecli"), filepath.Join(tmp, "fake-codex"))
	if err != nil {
		t.Fatal(err)
	}
	pluginZip := filepath.Join(tmp, "harness-codex.zip")
	channelZip := filepath.Join(tmp, "channel-e2e.zip")
	if _, err := bcnacceptance.PackagePluginDir("..", pluginZip); err != nil {
		t.Fatal(err)
	}
	if _, err := bcnacceptance.PackageEmbedFS(fixtures.FS, "channel", channelZip); err != nil {
		t.Fatal(err)
	}
	if _, err := bcnacceptance.InstallPluginZip(bcnBin, homeDir, pluginZip); err != nil {
		t.Fatal(err)
	}
	if _, err := bcnacceptance.InstallPluginZip(bcnBin, homeDir, channelZip); err != nil {
		t.Fatal(err)
	}
	if err := bcnacceptance.PatchReceiptOverrides(homeDir, "harness-codex", bcnacceptance.ReceiptOverrides{
		ExecOverrides: map[string]string{"codex": fakeCLI},
	}); err != nil {
		t.Fatal(err)
	}

	chSrv := bcnacceptance.NewE2EChannelServer()
	defer chSrv.Close()

	const agentID = "assistant"
	if err := bcnacceptance.WriteHarnessNodeConfig(homeDir, agentID, "harness-codex", chSrv.URL(), "workspace-write", 0, map[string]any{
		"model": "fake-codex-1",
	}); err != nil {
		t.Fatal(err)
	}

	env := map[string]string{"CODEX_HOME": codexHome}

	inspectOut, err := bcnacceptance.RunBCN(bcnBin, homeDir, env, "agent", "inspect", agentID)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"harness-codex", "true", "0.169.0"} {
		if !strings.Contains(inspectOut, want) {
			t.Fatalf("expected %q in bcn agent inspect output:\n%s", want, inspectOut)
		}
	}

	quotaOut, err := bcnacceptance.RunBCN(bcnBin, homeDir, env, "agent", "quota", agentID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(quotaOut, "75%") || !strings.Contains(quotaOut, "90%") {
		t.Fatalf("expected 75%% and 90%% remaining quota in bcn agent quota output:\n%s", quotaOut)
	}

	artDir, err := bcnacceptance.ArtifactDir("", "offline-codex")
	if err != nil {
		t.Fatal(err)
	}
	node, err := bcnacceptance.StartBCNNode(bcnBin, homeDir, env, filepath.Join(artDir, "node.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		node.DumpEventsToFile(filepath.Join(artDir, "audit.jsonl"))
		_ = node.Stop()
	}()

	if _, err := node.WaitEvent(20*time.Second, 0, func(ev bcnacceptance.AuditEvent) bool {
		return ev.Type == "channel.connected" && ev.PluginID == "channel-e2e"
	}); err != nil {
		t.Fatalf("wait channel.connected: %v\nlog:\n%s", err, node.LogText())
	}

	reports, err := node.InspectHarnesses(agentID)
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
		if node.ApprovePendingReviews(agentID) > 0 {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}

	if _, err := node.WaitEvent(30*time.Second, 0, func(ev bcnacceptance.AuditEvent) bool {
		return ev.Type == "harness.turn_completed" && ev.PluginID == "harness-codex"
	}); err != nil {
		t.Fatalf("wait harness.turn_completed: %v\nlog:\n%s", err, node.LogText())
	}

	if chSrv.PromptsCount() == 0 {
		t.Fatalf("expected at least one interactive approval prompt in workspace-write mode")
	}
	foundReply := false
	for _, m := range chSrv.OutboundSince(0) {
		if strings.Contains(m.Body, "FAKE_CODEX_OK") {
			foundReply = true
			break
		}
	}
	if !foundReply {
		t.Fatalf("expected FAKE_CODEX_OK via real bcc message send, got outbound=%+v", chSrv.OutboundSince(0))
	}

	evs, err := node.EventsSince(0)
	if err != nil {
		t.Fatalf("EventsSince: %v", err)
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

	beforeStopChildren := bcnacceptance.LinuxDescendants(node.PID())
	if err := node.Stop(); err != nil {
		t.Fatalf("node.Stop returned error: %v", err)
	}
	for _, child := range beforeStopChildren {
		if bcnacceptance.PIDAliveLinux(child.PID) {
			t.Fatalf("leaked child process after bcn stop: pid=%d cmd=%q", child.PID, child.Cmdline)
		}
	}
}

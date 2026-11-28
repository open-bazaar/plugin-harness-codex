package codex_test

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

var excludedTopLevel = map[string]bool{
	"README.md":         true,
	"CHANGELOG.md":      true,
	"screenshots":       true,
	"docs":              true,
	"dist":              true,
	"scripts":           true,
	"tests":             true,
	"test":              true,
	"node_modules":      true,
	"package.json":      true,
	"package-lock.json": true,
	"tsconfig.json":     true,
	"plugin.zip":        true,
	"plugin.zip.sha256": true,
	"SHA256SUMS.txt":    true,
}

var (
	readmeRe       = regexp.MustCompile(`(?i)^README(?:\.[^.]+)?\.md$`)
	ansiRe         = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)
	approvalHashRe = regexp.MustCompile(`Approval Hash:?\s+([0-9a-f]{64})`)
)

func isExcludedRel(relPosix string) bool {
	parts := strings.Split(relPosix, "/")
	if len(parts) == 0 || relPosix == "" {
		return true
	}
	for _, p := range parts {
		if strings.HasPrefix(p, ".") {
			return true
		}
	}
	if excludedTopLevel[parts[0]] {
		return true
	}
	if len(parts) == 1 && readmeRe.MatchString(parts[0]) {
		return true
	}
	name := parts[len(parts)-1]
	for _, suffix := range []string{
		".test.lua", ".spec.lua", "_test.lua", "_spec.lua",
		".test.js", ".test.ts", ".spec.js",
	} {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}

func packagePluginDir(t *testing.T, rootDir, outZip string) []string {
	t.Helper()
	var rels []string
	err := filepath.WalkDir(rootDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == rootDir {
			return nil
		}
		rel, err := filepath.Rel(rootDir, path)
		if err != nil {
			return err
		}
		relPosix := filepath.ToSlash(rel)
		if isExcludedRel(relPosix) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		rels = append(rels, relPosix)
		return nil
	})
	if err != nil {
		t.Fatalf("walk plugin dir %s: %v", rootDir, err)
	}
	sort.Strings(rels)

	f, err := os.Create(outZip)
	if err != nil {
		t.Fatalf("create zip %s: %v", outZip, err)
	}
	zw := zip.NewWriter(f)
	for _, rel := range rels {
		data, err := os.ReadFile(filepath.Join(rootDir, filepath.FromSlash(rel)))
		if err != nil {
			_ = zw.Close()
			_ = f.Close()
			t.Fatalf("read %s: %v", rel, err)
		}
		hdr := &zip.FileHeader{
			Name:     rel,
			Method:   zip.Deflate,
			Modified: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		}
		hdr.SetMode(0o644)
		w, err := zw.CreateHeader(hdr)
		if err != nil {
			_ = zw.Close()
			_ = f.Close()
			t.Fatalf("zip create %s: %v", rel, err)
		}
		if _, err := w.Write(data); err != nil {
			_ = zw.Close()
			_ = f.Close()
			t.Fatalf("zip write %s: %v", rel, err)
		}
	}
	if err := zw.Close(); err != nil {
		_ = f.Close()
		t.Fatalf("close zip writer: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close zip file: %v", err)
	}
	return rels
}

func resolveBCNBin(t *testing.T) string {
	t.Helper()
	if envBin := strings.TrimSpace(os.Getenv("BCN_BIN")); envBin != "" {
		if _, err := os.Stat(envBin); err != nil {
			t.Fatalf("BCN_BIN=%q not accessible: %v", envBin, err)
		}
		return envBin
	}
	p, err := exec.LookPath("bcn")
	if err != nil {
		t.Fatalf("bcn binary not found in PATH and BCN_BIN is unset: %v", err)
	}
	return p
}

func buildGoBinary(t *testing.T, srcDir, outPath string) string {
	t.Helper()
	if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(outPath), ".exe") {
		outPath += ".exe"
	}
	cmd := exec.Command("go", "build", "-o", outPath, ".")
	cmd.Dir = srcDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build %s failed: %v\n%s", srcDir, err, string(out))
	}
	return outPath
}

func cleanEnv(extra map[string]string) []string {
	var out []string
	for _, kv := range os.Environ() {
		k, _, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		ku := strings.ToUpper(k)
		if strings.HasPrefix(ku, "BCN_") ||
			strings.HasPrefix(ku, "BCC_") ||
			strings.HasPrefix(ku, "CODEX_") ||
			strings.HasPrefix(ku, "CLAUDE_") ||
			strings.HasPrefix(ku, "ANTHROPIC_") ||
			strings.HasPrefix(ku, "OPENAI_") ||
			strings.HasPrefix(ku, "AGY_") ||
			strings.HasPrefix(ku, "GEMINI_") ||
			strings.HasPrefix(ku, "GOOGLE_") {
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "NO_COLOR=1")
	for k, v := range extra {
		out = append(out, k+"="+v)
	}
	return out
}

func runBCN(t *testing.T, bcnBin, homeDir string, extraEnv map[string]string, args ...string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	fullArgs := append([]string{"--home", homeDir}, args...)
	cmd := exec.CommandContext(ctx, bcnBin, fullArgs...)
	cmd.Env = cleanEnv(extraEnv)
	out, err := cmd.CombinedOutput()
	plain := ansiRe.ReplaceAllString(string(out), "")
	if err != nil {
		t.Fatalf("bcn %v failed: %v\noutput:\n%s", args, err, plain)
	}
	return plain
}

func installPluginZip(t *testing.T, bcnBin, homeDir, zipPath string) {
	t.Helper()
	insp := runBCN(t, bcnBin, homeDir, nil, "plugin", "inspect", "--dry-run", zipPath)
	m := approvalHashRe.FindStringSubmatch(insp)
	if len(m) != 2 {
		t.Fatalf("could not parse Approval Hash from bcn plugin inspect:\n%s", insp)
	}
	runBCN(t, bcnBin, homeDir, nil, "plugin", "install", zipPath, "--approve-hash", m[1])
}

type receiptOverrides struct {
	ExecOverrides map[string]string `json:"execOverrides,omitempty"`
	Network       []string          `json:"network,omitempty"`
	PrivateHosts  []string          `json:"privateHosts,omitempty"`
}

func patchReceiptOverrides(t *testing.T, homeDir, pluginID string, ov receiptOverrides) {
	t.Helper()
	receiptsPath := filepath.Join(homeDir, "plugins", "receipts.json")
	raw, err := os.ReadFile(receiptsPath)
	if err != nil {
		t.Fatalf("read receipts.json: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse receipts.json: %v", err)
	}
	receipts, ok := doc["receipts"].(map[string]any)
	if !ok {
		t.Fatalf("receipts.json missing receipts map")
	}
	rec, ok := receipts[pluginID].(map[string]any)
	if !ok {
		t.Fatalf("receipts.json missing plugin %q", pluginID)
	}
	ovBytes, _ := json.Marshal(ov)
	var ovMap map[string]any
	_ = json.Unmarshal(ovBytes, &ovMap)
	rec["overrides"] = ovMap
	updated, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		t.Fatalf("marshal receipts.json: %v", err)
	}
	if err := os.WriteFile(receiptsPath, append(updated, '\n'), 0o600); err != nil {
		t.Fatalf("write receipts.json: %v", err)
	}
}

func randomHex(t *testing.T, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

func artifactDir(t *testing.T, subdir string) string {
	t.Helper()
	base := strings.TrimSpace(os.Getenv("BCN_E2E_ARTIFACTS"))
	if base == "" {
		return t.TempDir()
	}
	dir := filepath.Join(base, subdir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir artifact dir %s: %v", dir, err)
	}
	return dir
}

// --- E2E Channel Loopback Server ---

type outboundMsg struct {
	ID      string `json:"id"`
	Target  string `json:"target"`
	Body    string `json:"body"`
	ReplyTo string `json:"replyToId,omitempty"`
}

type promptRecord struct {
	PromptID       string `json:"promptId"`
	Target         string `json:"target"`
	AllowedActorID string `json:"allowedActorId"`
	Title          string `json:"title"`
	Body           string `json:"body"`
	Actions        []struct {
		ID    string `json:"id"`
		Label string `json:"label"`
	} `json:"actions"`
	DecisionAction string `json:"decisionAction"`
}

type e2eChannelServer struct {
	srv *httptest.Server

	mu         sync.Mutex
	inboundQ   []map[string]any
	inboundSig chan struct{}
	outbound   []outboundMsg
	prompts    []promptRecord
	cancels    []string
	decideFn   func(prompt promptRecord) string
}

func newE2EChannelServer() *e2eChannelServer {
	c := &e2eChannelServer{
		inboundSig: make(chan struct{}, 1),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/poll", func(w http.ResponseWriter, r *http.Request) {
		items := c.drainInbound()
		if len(items) == 0 {
			select {
			case <-c.inboundSig:
				items = c.drainInbound()
			case <-time.After(1500 * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
		if items == nil {
			items = []map[string]any{}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(items)
	})
	mux.HandleFunc("/outbound", func(w http.ResponseWriter, r *http.Request) {
		var m outboundMsg
		_ = json.NewDecoder(r.Body).Decode(&m)
		c.mu.Lock()
		c.outbound = append(c.outbound, m)
		c.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/prompt", func(w http.ResponseWriter, r *http.Request) {
		var pr promptRecord
		_ = json.NewDecoder(r.Body).Decode(&pr)
		c.mu.Lock()
		fn := c.decideFn
		c.mu.Unlock()
		actionID := "approve:once"
		if fn != nil {
			actionID = fn(pr)
		}
		pr.DecisionAction = actionID
		c.mu.Lock()
		c.prompts = append(c.prompts, pr)
		c.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"actionId":    actionID,
			"responderId": pr.AllowedActorID,
		})
	})
	mux.HandleFunc("/cancel", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			PromptID string `json:"promptId"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		c.mu.Lock()
		c.cancels = append(c.cancels, body.PromptID)
		c.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	c.srv = httptest.NewServer(mux)
	return c
}

func (c *e2eChannelServer) Close() {
	if c.srv != nil {
		c.srv.Close()
	}
}

func (c *e2eChannelServer) URL() string {
	return c.srv.URL
}

func (c *e2eChannelServer) SetDecisionFunc(fn func(promptRecord) string) {
	c.mu.Lock()
	c.decideFn = fn
	c.mu.Unlock()
}

func (c *e2eChannelServer) drainInbound() []map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.inboundQ) == 0 {
		return nil
	}
	out := c.inboundQ
	c.inboundQ = nil
	return out
}

func (c *e2eChannelServer) PushDM(msgID, body string) {
	ev := map[string]any{
		"type":            "message",
		"target":          "dm:tester",
		"conversationKey": "e2e:dm:tester",
		"kind":            "dm",
		"displayName":     "Tester",
		"providerMsgId":   msgID,
		"senderId":        "tester",
		"senderHandle":    "tester",
		"senderName":      "Tester",
		"senderType":      "human",
		"body":            body,
		"mentionsAgent":   true,
		"timestampMs":     time.Now().UnixMilli(),
	}
	c.mu.Lock()
	c.inboundQ = append(c.inboundQ, ev)
	c.mu.Unlock()
	select {
	case c.inboundSig <- struct{}{}:
	default:
	}
}

func (c *e2eChannelServer) OutboundCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.outbound)
}

func (c *e2eChannelServer) OutboundSince(idx int) []outboundMsg {
	c.mu.Lock()
	defer c.mu.Unlock()
	if idx >= len(c.outbound) {
		return nil
	}
	out := make([]outboundMsg, len(c.outbound)-idx)
	copy(out, c.outbound[idx:])
	return out
}

func (c *e2eChannelServer) PromptsCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.prompts)
}

func (c *e2eChannelServer) PromptsSince(idx int) []promptRecord {
	c.mu.Lock()
	defer c.mu.Unlock()
	if idx >= len(c.prompts) {
		return nil
	}
	out := make([]promptRecord, len(c.prompts)-idx)
	copy(out, c.prompts[idx:])
	return out
}

func hasPromptAction(pr promptRecord, actionID string) bool {
	for _, a := range pr.Actions {
		if a.ID == actionID {
			return true
		}
	}
	return false
}

// --- Running BCN Node & Admin IPC ---

type auditEvent struct {
	Seq       int64          `json:"seq"`
	RunID     string         `json:"runId"`
	Type      string         `json:"type"`
	AgentID   string         `json:"agentId"`
	ActorID   string         `json:"actorId"`
	PluginID  string         `json:"pluginId"`
	Payload   map[string]any `json:"payload"`
	CreatedAt int64          `json:"createdAt"`
}

type reviewConversation struct {
	ID              string `json:"id"`
	AgentID         string `json:"agentId"`
	ChannelID       string `json:"channelId"`
	Target          string `json:"target"`
	ConversationKey string `json:"conversationKey"`
	ProviderTarget  string `json:"providerTarget"`
	Kind            string `json:"kind"`
	ReviewStatus    string `json:"reviewStatus"`
}

type runningBCN struct {
	t       *testing.T
	homeDir string
	logPath string
	cmd     *exec.Cmd
	logFile *os.File
	done    chan error
	stopMu  sync.Mutex
	stopped bool
}

func startBCNNode(t *testing.T, bcnBin, homeDir string, extraEnv map[string]string, logPath string) *runningBCN {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		t.Fatalf("mkdir log dir: %v", err)
	}
	lf, err := os.Create(logPath)
	if err != nil {
		t.Fatalf("create node log %s: %v", logPath, err)
	}
	cmd := exec.Command(bcnBin, "--home", homeDir, "run")
	cmd.Env = cleanEnv(extraEnv)
	cmd.Stdout = lf
	cmd.Stderr = lf

	if err := cmd.Start(); err != nil {
		_ = lf.Close()
		t.Fatalf("start bcn run: %v", err)
	}
	node := &runningBCN{
		t:       t,
		homeDir: homeDir,
		logPath: logPath,
		cmd:     cmd,
		logFile: lf,
		done:    make(chan error, 1),
	}
	go func() {
		node.done <- cmd.Wait()
	}()

	deadline := time.Now().Add(45 * time.Second)
	adminFile := filepath.Join(homeDir, "runtime", "admin-ipc.json")
	for time.Now().Before(deadline) {
		select {
		case err := <-node.done:
			node.done <- err
			raw, _ := os.ReadFile(logPath)
			t.Fatalf("bcn run exited before ready (%v):\n%s", err, string(raw))
		default:
		}
		raw, _ := os.ReadFile(logPath)
		if bytes.Contains(raw, []byte("bcn ready")) {
			if _, statErr := os.Stat(adminFile); statErr == nil {
				return node
			}
		}
		time.Sleep(150 * time.Millisecond)
	}
	_ = node.Stop()
	raw, _ := os.ReadFile(logPath)
	t.Fatalf("timed out waiting for bcn ready:\n%s", string(raw))
	return nil
}

func (n *runningBCN) PID() int {
	if n.cmd != nil && n.cmd.Process != nil {
		return n.cmd.Process.Pid
	}
	return 0
}

func (n *runningBCN) Stop() error {
	n.stopMu.Lock()
	if n.stopped {
		n.stopMu.Unlock()
		return nil
	}
	n.stopped = true
	n.stopMu.Unlock()

	if n.cmd != nil && n.cmd.Process != nil {
		if runtime.GOOS == "windows" {
			_ = n.cmd.Process.Kill()
		} else {
			_ = n.cmd.Process.Signal(syscall.SIGTERM)
		}
	}
	var waitErr error
	select {
	case waitErr = <-n.done:
	case <-time.After(20 * time.Second):
		if n.cmd != nil && n.cmd.Process != nil {
			_ = n.cmd.Process.Kill()
		}
		waitErr = <-n.done
	}
	if n.logFile != nil {
		_ = n.logFile.Close()
	}
	return waitErr
}

func (n *runningBCN) LogText() string {
	raw, _ := os.ReadFile(n.logPath)
	return string(raw)
}

func (n *runningBCN) adminCall(method string, params any, resultOut any) error {
	raw, err := os.ReadFile(filepath.Join(n.homeDir, "runtime", "admin-ipc.json"))
	if err != nil {
		return err
	}
	var ep struct {
		Endpoint string `json:"endpoint"`
		Token    string `json:"token"`
	}
	if err := json.Unmarshal(raw, &ep); err != nil {
		return err
	}
	network := "unix"
	if runtime.GOOS == "windows" {
		network = "tcp"
	}
	conn, err := net.DialTimeout(network, ep.Endpoint, 5*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	innerParams := map[string]any{
		"method": method,
		"params": params,
	}
	rawParams, err := json.Marshal(innerParams)
	if err != nil {
		return err
	}
	reqLine, err := json.Marshal(map[string]any{
		"token":  ep.Token,
		"method": "control.call",
		"params": json.RawMessage(rawParams),
	})
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(reqLine, '\n')); err != nil {
		return err
	}
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return err
		}
		return io.ErrUnexpectedEOF
	}
	var resp struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		return err
	}
	if resp.Error != nil {
		return fmt.Errorf("ipc %s error (%s): %s", method, resp.Error.Code, resp.Error.Message)
	}
	if resultOut != nil && len(resp.Result) > 0 {
		return json.Unmarshal(resp.Result, resultOut)
	}
	return nil
}

func (n *runningBCN) eventsSince(afterSeq int64) ([]auditEvent, error) {
	var resp struct {
		Events []auditEvent `json:"events"`
	}
	if err := n.adminCall("events.since", map[string]any{"afterSeq": afterSeq, "limit": 500}, &resp); err != nil {
		return nil, err
	}
	return resp.Events, nil
}

func (n *runningBCN) lastEventSeq() int64 {
	evs, err := n.eventsSince(0)
	if err != nil || len(evs) == 0 {
		return 0
	}
	return evs[len(evs)-1].Seq
}

func (n *runningBCN) waitEvent(timeout time.Duration, afterSeq int64, match func(auditEvent) bool) (auditEvent, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		evs, err := n.eventsSince(afterSeq)
		if err == nil {
			for _, ev := range evs {
				if match(ev) {
					return ev, nil
				}
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return auditEvent{}, errors.New("timed out waiting for matching audit event")
}

func (n *runningBCN) approvePendingReviews(agentID string) int {
	var resp struct {
		Reviews []reviewConversation `json:"reviews"`
	}
	if err := n.adminCall("reviews.list", map[string]any{"agent": agentID, "status": "pending"}, &resp); err != nil {
		return 0
	}
	approved := 0
	for _, r := range resp.Reviews {
		if err := n.adminCall("reviews.decide", map[string]any{
			"agentId":        agentID,
			"conversationId": r.ID,
			"decision":       "approved",
		}, nil); err == nil {
			approved++
		}
	}
	return approved
}

func (n *runningBCN) dumpEventsToFile(path string) {
	evs, err := n.eventsSince(0)
	if err != nil {
		return
	}
	var buf bytes.Buffer
	for _, ev := range evs {
		b, _ := json.Marshal(ev)
		buf.Write(b)
		buf.WriteByte('\n')
	}
	_ = os.WriteFile(path, buf.Bytes(), 0o644)
}

type inspectReport struct {
	AgentID   string `json:"agentId"`
	HarnessID string `json:"harnessId"`
	PluginID  string `json:"pluginId"`
	Result    struct {
		Available  bool   `json:"available"`
		Version    string `json:"version"`
		Error      string `json:"error"`
		Models     []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"models"`
		Skills []struct {
			Name string `json:"name"`
		} `json:"skills"`
		MCPServers []struct {
			Name  string `json:"name"`
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
		} `json:"mcpServers"`
	} `json:"result"`
}

func (n *runningBCN) inspectHarnesses(agentID string) ([]inspectReport, error) {
	var resp struct {
		Inspections []inspectReport `json:"inspections"`
	}
	if err := n.adminCall("agents.inspect", map[string]any{"agent": agentID, "refresh": true}, &resp); err != nil {
		return nil, err
	}
	return resp.Inspections, nil
}

type codexConfigOptions struct {
	AgentID     string
	ChannelURL  string
	Mode        string
	Sandbox     string
	IdleTimeout int
	Model       string
	Effort      string
	APIKey      string
}

func writeCodexNodeConfig(t *testing.T, homeDir string, opt codexConfigOptions) {
	t.Helper()
	if opt.Mode == "" {
		opt.Mode = "session"
	}
	if opt.Sandbox == "" {
		opt.Sandbox = "workspace-write"
	}
	var hOpts strings.Builder
	if opt.Model != "" {
		fmt.Fprintf(&hOpts, "model = %q\n", opt.Model)
	}
	if opt.Effort != "" {
		fmt.Fprintf(&hOpts, "effort = %q\n", opt.Effort)
	}
	if opt.APIKey != "" {
		fmt.Fprintf(&hOpts, "apiKey = %q\n", opt.APIKey)
	}
	cfg := fmt.Sprintf(`version = 1
revision = 1

[[agents]]
id = %q
name = "Assistant"
mode = %q
sandbox = %q
idle_timeout = %d

[[agents.channels]]
id = "channel-e2e-1"
plugin = "channel-e2e"

[agents.channels.options]
baseUrl = %q

[[agents.harnesses]]
id = "harness-codex-1"
plugin = "harness-codex"

[agents.harnesses.options]
%s`, opt.AgentID, opt.Mode, opt.Sandbox, opt.IdleTimeout, opt.ChannelURL, hOpts.String())
	if err := os.WriteFile(filepath.Join(homeDir, "config.toml"), []byte(cfg), 0o600); err != nil {
		t.Fatalf("write config.toml: %v", err)
	}
}

// --- Pure-Go Linux /proc process tree helpers ---

type procInfo struct {
	PID     int
	PPID    int
	State   string
	Cmdline string
	Env     map[string]string
}

func linuxDescendants(rootPID int) []procInfo {
	if runtime.GOOS != "linux" || rootPID <= 0 {
		return nil
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	byParent := map[int][]procInfo{}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 {
			continue
		}
		statBytes, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if err != nil {
			continue
		}
		statStr := string(statBytes)
		rparen := strings.LastIndexByte(statStr, ')')
		if rparen < 0 || rparen+2 >= len(statStr) {
			continue
		}
		fields := strings.Fields(statStr[rparen+2:])
		if len(fields) < 2 {
			continue
		}
		state := fields[0]
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		cmdBytes, _ := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
		cmdline := strings.TrimSpace(strings.ReplaceAll(string(cmdBytes), "\x00", " "))
		envMap := map[string]string{}
		if envBytes, err := os.ReadFile(fmt.Sprintf("/proc/%d/environ", pid)); err == nil {
			for _, kv := range strings.Split(string(envBytes), "\x00") {
				if k, v, ok := strings.Cut(kv, "="); ok {
					envMap[k] = v
				}
			}
		}
		byParent[ppid] = append(byParent[ppid], procInfo{
			PID:     pid,
			PPID:    ppid,
			State:   state,
			Cmdline: cmdline,
			Env:     envMap,
		})
	}
	var out []procInfo
	queue := []int{rootPID}
	seen := map[int]bool{rootPID: true}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, child := range byParent[cur] {
			if seen[child.PID] {
				continue
			}
			seen[child.PID] = true
			out = append(out, child)
			queue = append(queue, child.PID)
		}
	}
	return out
}

func pidAliveLinux(pid int) bool {
	if runtime.GOOS != "linux" || pid <= 0 {
		return false
	}
	statBytes, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	statStr := string(statBytes)
	rparen := strings.LastIndexByte(statStr, ')')
	if rparen < 0 || rparen+2 >= len(statStr) {
		return false
	}
	fields := strings.Fields(statStr[rparen+2:])
	return len(fields) > 0 && fields[0] != "Z"
}

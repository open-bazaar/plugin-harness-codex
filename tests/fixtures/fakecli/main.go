package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
)

type rpcPacket struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

var (
	outMu     sync.Mutex
	targetRe  = regexp.MustCompile(`target=([^\s\]]+)`)
	pendingMu sync.Mutex
	pending   = map[string]chan rpcPacket{}
)

func sendJSON(v any) {
	outMu.Lock()
	defer outMu.Unlock()
	b, _ := json.Marshal(v)
	_, _ = os.Stdout.Write(append(b, '\n'))
}

func runBCCSend(target, body string) (string, int) {
	cmd := exec.Command("bcc", "message", "send", "--target", target)
	cmd.Stdin = strings.NewReader(body)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out) + ": " + err.Error(), 1
	}
	return string(out), 0
}

func runBCCCheck() string {
	cmd := exec.Command("bcc", "message", "check")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out)
	}
	return string(out)
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "--version" {
		fmt.Println("codex-cli 0.169.0")
		return
	}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 64<<10), 4<<20)

	threadSeq := 0
	turnSeq := 0
	serverReqSeq := 9000
	currentThread := "fake-codex-thread-1"
	currentModel := "fake-codex-1"

	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var pkt rpcPacket
		if err := json.Unmarshal([]byte(line), &pkt); err != nil {
			continue
		}

		// Handle response to a server-initiated request (approval).
		if pkt.Method == "" && len(pkt.ID) > 0 {
			key := strings.Trim(string(pkt.ID), `"`)
			pendingMu.Lock()
			ch := pending[key]
			delete(pending, key)
			pendingMu.Unlock()
			if ch != nil {
				ch <- pkt
			}
			continue
		}

		switch pkt.Method {
		case "initialize":
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"userAgent": "fake-codex/0.169.0",
					"codexHome": os.Getenv("CODEX_HOME"),
				},
			})
		case "initialized":
			// notification
		case "fs/watch":
			var p struct {
				Path string `json:"path"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			sendJSON(map[string]any{
				"id":     json.RawMessage(pkt.ID),
				"result": map[string]any{"path": p.Path},
			})
		case "model/list":
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"data": []map[string]any{
						{
							"id":                        "fake-codex-1",
							"model":                     "fake-codex-1",
							"displayName":               "Fake Codex 1",
							"isDefault":                 true,
							"defaultReasoningEffort":    "medium",
							"supportedReasoningEfforts": []string{"low", "medium", "high"},
						},
					},
					"nextCursor": nil,
				},
			})
		case "skills/list":
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"data": []map[string]any{
						{
							"skills": []map[string]any{
								{
									"name":        "offline-skill",
									"scope":       "repo",
									"enabled":     true,
									"description": "Offline test skill",
								},
							},
						},
					},
				},
			})
		case "mcpServerStatus/list":
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"data": []map[string]any{
						{
							"name":          "test",
							"runtimeStatus": "connected",
							"tools": []map[string]any{
								{"name": "get_value", "description": "Read test value"},
							},
						},
					},
					"nextCursor": nil,
				},
			})
		case "account/rateLimits/read":
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"rateLimitsByLimitId": map[string]any{
						"codex": map[string]any{
							"limitName": "Codex",
							"primary": map[string]any{
								"usedPercent":        25,
								"windowDurationMins": 300,
								"resetsAt":           1900000000,
							},
							"secondary": map[string]any{
								"usedPercent":        10,
								"windowDurationMins": 10080,
								"resetsAt":           1900600000,
							},
						},
					},
				},
			})
		case "thread/start":
			threadSeq++
			currentThread = fmt.Sprintf("fake-codex-thread-%d", threadSeq)
			var p struct {
				Model string `json:"model"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			if p.Model != "" {
				currentModel = p.Model
			}
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"thread": map[string]any{"id": currentThread},
					"model":  currentModel,
				},
			})
		case "thread/resume":
			var p struct {
				ThreadID string `json:"threadId"`
				Model    string `json:"model"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			if p.ThreadID != "" {
				currentThread = p.ThreadID
			}
			if p.Model != "" {
				currentModel = p.Model
			}
			sendJSON(map[string]any{
				"id": json.RawMessage(pkt.ID),
				"result": map[string]any{
					"thread": map[string]any{"id": currentThread},
					"model":  currentModel,
				},
			})
		case "thread/backgroundTerminals/list":
			sendJSON(map[string]any{
				"id":     json.RawMessage(pkt.ID),
				"result": map[string]any{"data": []any{}},
			})
		case "turn/start":
			turnSeq++
			turnID := fmt.Sprintf("fake-turn-%d", turnSeq)
			var p struct {
				ThreadID      string `json:"threadId"`
				SandboxPolicy struct {
					Type string `json:"type"`
				} `json:"sandboxPolicy"`
				Input []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"input"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			sendJSON(map[string]any{
				"id":     json.RawMessage(pkt.ID),
				"result": map[string]any{"turn": map[string]any{"id": turnID}},
			})

			inputText := ""
			for _, in := range p.Input {
				if in.Type == "text" {
					inputText += in.Text + "\n"
				}
			}
			serverReqSeq++
			reqID := serverReqSeq
			tID := p.ThreadID
			if tID == "" {
				tID = currentThread
			}
			sandboxType := p.SandboxPolicy.Type

			go func() {
				sendJSON(map[string]any{
					"method": "turn/started",
					"params": map[string]any{"threadId": tID, "turnId": turnID},
				})

				approved := sandboxType == "dangerFullAccess"
				if !approved {
					ch := make(chan rpcPacket, 1)
					key := fmt.Sprintf("%d", reqID)
					pendingMu.Lock()
					pending[key] = ch
					pendingMu.Unlock()

					sendJSON(map[string]any{
						"id":     reqID,
						"method": "item/commandExecution/requestApproval",
						"params": map[string]any{
							"threadId":           tID,
							"turnId":             turnID,
							"itemId":             "cmd-1",
							"command":            "bcc message send",
							"availableDecisions": []string{"accept", "acceptForSession", "decline"},
						},
					})
					resp := <-ch
					var dec struct {
						Decision any `json:"decision"`
					}
					_ = json.Unmarshal(resp.Result, &dec)
					if s, ok := dec.Decision.(string); ok && (s == "accept" || s == "acceptForSession") {
						approved = true
					}
				}

				sendJSON(map[string]any{
					"method": "item/started",
					"params": map[string]any{
						"threadId": tID,
						"turnId":   turnID,
						"item": map[string]any{
							"id":      "cmd-1",
							"type":    "commandExecution",
							"command": "bcc message send",
							"cwd":     ".",
						},
					},
				})

				if approved {
					checked := runBCCCheck()
					target := ""
					if m := targetRe.FindStringSubmatch(checked); len(m) == 2 {
						target = m[1]
					}
					if target == "" {
						if m := targetRe.FindStringSubmatch(inputText); len(m) == 2 {
							target = m[1]
						}
					}
					output := "no target"
					exitCode := 1
					if target != "" {
						output, exitCode = runBCCSend(target, "FAKE_CODEX_OK")
					}
					status := "completed"
					if exitCode != 0 {
						status = "failed"
					}
					sendJSON(map[string]any{
						"method": "item/completed",
						"params": map[string]any{
							"threadId": tID,
							"turnId":   turnID,
							"item": map[string]any{
								"id":               "cmd-1",
								"type":             "commandExecution",
								"command":          "bcc message send",
								"cwd":              ".",
								"status":           status,
								"exitCode":         exitCode,
								"aggregatedOutput": output,
								"durationMs":       15,
							},
						},
					})
				} else {
					sendJSON(map[string]any{
						"method": "item/completed",
						"params": map[string]any{
							"threadId": tID,
							"turnId":   turnID,
							"item": map[string]any{
								"id":         "cmd-1",
								"type":       "commandExecution",
								"command":    "bcc message send",
								"cwd":        ".",
								"status":     "declined",
								"durationMs": 5,
							},
						},
					})
				}

				sendJSON(map[string]any{
					"method": "item/agentMessage/delta",
					"params": map[string]any{
						"threadId": tID,
						"turnId":   turnID,
						"delta":    "done",
					},
				})
				sendJSON(map[string]any{
					"method": "thread/tokenUsage/updated",
					"params": map[string]any{
						"threadId": tID,
						"turnId":   turnID,
						"tokenUsage": map[string]any{
							"total": map[string]any{
								"inputTokens":  120,
								"outputTokens": 30,
								"totalTokens":  150,
							},
							"last": map[string]any{
								"inputTokens":  120,
								"outputTokens": 30,
								"totalTokens":  150,
							},
							"modelContextWindow": 131072,
						},
					},
				})
				sendJSON(map[string]any{
					"method": "turn/completed",
					"params": map[string]any{
						"threadId": tID,
						"turnId":   turnID,
						"turn":     map[string]any{"id": turnID, "status": "completed"},
					},
				})
			}()
		case "turn/steer":
			var p struct {
				ExpectedTurnID string `json:"expectedTurnId"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			sendJSON(map[string]any{
				"id":     json.RawMessage(pkt.ID),
				"result": map[string]any{"turnId": p.ExpectedTurnID},
			})
		case "turn/interrupt":
			sendJSON(map[string]any{
				"id":     json.RawMessage(pkt.ID),
				"result": map[string]any{},
			})
		default:
			if len(pkt.ID) > 0 {
				sendJSON(map[string]any{
					"id":    json.RawMessage(pkt.ID),
					"error": map[string]any{"code": -32601, "message": "unsupported method: " + pkt.Method},
				})
			}
		}
	}
}

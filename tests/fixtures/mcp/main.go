package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

type rpcMessage struct {
	JSONRPC string          `json:"jsonrpc,omitempty"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
}

func readFrame(r *bufio.Reader) ([]byte, bool, error) {
	for {
		line, err := r.ReadString('\n')
		if err != nil && len(line) == 0 {
			return nil, false, err
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			if err != nil {
				return nil, false, err
			}
			continue
		}
		if strings.HasPrefix(trimmed, "{") {
			return []byte(trimmed), false, nil
		}
		// Content-Length header framing.
		contentLen := -1
		for {
			lower := strings.ToLower(trimmed)
			if strings.HasPrefix(lower, "content-length:") {
				v := strings.TrimSpace(trimmed[len("content-length:"):])
				n, convErr := strconv.Atoi(v)
				if convErr == nil {
					contentLen = n
				}
			}
			hdrLine, hdrErr := r.ReadString('\n')
			if strings.TrimSpace(hdrLine) == "" {
				break
			}
			if hdrErr != nil {
				return nil, true, hdrErr
			}
			trimmed = strings.TrimSpace(hdrLine)
		}
		if contentLen <= 0 {
			return nil, true, fmt.Errorf("invalid Content-Length")
		}
		buf := make([]byte, contentLen)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, true, err
		}
		return buf, true, nil
	}
}

func writeFrame(w *bufio.Writer, payload any, framed bool) {
	raw, _ := json.Marshal(payload)
	if framed {
		fmt.Fprintf(w, "Content-Length: %d\r\n\r\n", len(raw))
		_, _ = w.Write(raw)
	} else {
		_, _ = w.Write(raw)
		_ = w.WriteByte('\n')
	}
	_ = w.Flush()
}

func appendCallLog(args map[string]any, result map[string]any) {
	logPath := strings.TrimSpace(os.Getenv("BCN_MCP_LOG"))
	if logPath == "" {
		return
	}
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	rec, _ := json.Marshal(map[string]any{
		"server":    "test",
		"tool":      "get_value",
		"arguments": args,
		"result":    result,
	})
	_, _ = f.Write(append(rec, '\n'))
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	writer := bufio.NewWriter(os.Stdout)

	for {
		raw, framed, err := readFrame(reader)
		if err != nil {
			return
		}
		var msg rpcMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}
		if len(msg.ID) == 0 || string(msg.ID) == "null" {
			continue
		}

		var result any
		var rpcErr map[string]any

		switch msg.Method {
		case "initialize":
			var params struct {
				ProtocolVersion string `json:"protocolVersion"`
			}
			_ = json.Unmarshal(msg.Params, &params)
			protoVer := params.ProtocolVersion
			if protoVer == "" {
				protoVer = "2024-11-05"
			}
			result = map[string]any{
				"protocolVersion": protoVer,
				"capabilities": map[string]any{
					"tools": map[string]any{},
				},
				"serverInfo": map[string]any{
					"name":    "test",
					"version": "1.0.0",
				},
			}
		case "ping":
			result = map[string]any{}
		case "tools/list":
			result = map[string]any{
				"tools": []map[string]any{
					{
						"name":        "get_value",
						"description": "Read a deterministic test value for the given key.",
						"inputSchema": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"key": map[string]any{
									"type":        "string",
									"description": "Key name to look up",
								},
							},
							"required": []string{"key"},
						},
					},
				},
			}
		case "tools/call":
			var params struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			}
			_ = json.Unmarshal(msg.Params, &params)
			if params.Name != "get_value" {
				rpcErr = map[string]any{"code": -32602, "message": "unknown tool: " + params.Name}
			} else {
				key, _ := params.Arguments["key"].(string)
				valObj := map[string]any{"key": key, "value": "MCP_OK"}
				valJSON, _ := json.Marshal(valObj)
				appendCallLog(params.Arguments, valObj)
				result = map[string]any{
					"content": []map[string]any{
						{"type": "text", "text": string(valJSON)},
					},
					"isError": false,
				}
			}
		default:
			rpcErr = map[string]any{"code": -32601, "message": "method not found: " + msg.Method}
		}

		resp := map[string]any{
			"jsonrpc": "2.0",
			"id":      json.RawMessage(msg.ID),
		}
		if rpcErr != nil {
			resp["error"] = rpcErr
		} else {
			resp["result"] = result
		}
		writeFrame(writer, resp, framed)
	}
}

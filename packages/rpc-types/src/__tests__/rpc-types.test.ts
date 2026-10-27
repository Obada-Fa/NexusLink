import { describe, it, expect } from "bun:test";
import type { RpcMethod, Params, Result, WsMessage } from "../index";
import { createId, assertRpcEnvelope, type RpcEnvelope } from "../utils";

import { WORKSPACE_METHODS } from '../workspace';
import { SUPPORTED_METHODS, validateRequest } from '../../../../apps/desktop/src/server/workspace/protocol';

describe('protocol registry', () => {
  it('advertises implemented workspace methods without duplicates', () => {
    for(const method of WORKSPACE_METHODS) expect(SUPPORTED_METHODS).toContain(method);
    expect(new Set(SUPPORTED_METHODS).size).toBe(SUPPORTED_METHODS.length);
    // Implemented with guards: kill (own processes only, never session-critical), delete (to Trash).
    for (const method of ['process.kill', 'fs.delete', 'fs.move', 'monitor.snapshot', 'system.getVitals']) expect(SUPPORTED_METHODS).toContain(method as any);
  });
  it('validates kill, delete, move and monitor parameters', () => {
    expect(()=>validateRequest('process.kill',{pid:'12'})).toThrow();
    expect(()=>validateRequest('process.kill',{pid:4242})).not.toThrow();
    expect(()=>validateRequest('fs.delete',{})).toThrow();
    expect(()=>validateRequest('fs.move',{from:'/a'})).toThrow();
    expect(()=>validateRequest('screen.startCapture',{monitor:'../x'})).toThrow();
    expect(()=>validateRequest('screen.startCapture',{monitor:'DP-1'})).not.toThrow();
    expect(()=>validateRequest('session.subscribe',{topics:['monitor'],monitorInterval:3000})).toThrow();
    expect(()=>validateRequest('session.subscribe',{topics:['monitor'],monitorInterval:1000})).not.toThrow();
  });
  it('rejects malformed parameters before dispatch', () => {
    expect(()=>validateRequest('terminal.create',{cols:-1,rows:24})).toThrow();
    expect(()=>validateRequest('terminal.input',{terminalId:12,data:'x'})).toThrow();
    expect(()=>validateRequest('agent.permission',{allow:'yes'})).toThrow();
    expect(()=>validateRequest('terminal.resize',{cols:80,rows:24})).not.toThrow();
  });
});

describe("Params/Result shape checks", () => {
  it("fs.list params require path", () => {
    const p: Params<"fs.list"> = { path: "/home" };
    expect(p.path).toBe("/home");
  });

  it("fs.list params allow optional showHidden", () => {
    const p: Params<"fs.list"> = { path: "/", showHidden: true };
    expect(p.showHidden).toBe(true);
  });

  it("fs.write params require path and content", () => {
    const p: Params<"fs.write"> = { path: "/tmp/test", content: "hello" };
    expect(p.content).toBe("hello");
  });

  it("fs.list result is FileEntry[]", () => {
    const r: Result<"fs.list"> = [{ name: "x", path: "/x", size: 0, isDirectory: false, modifiedAt: "2024", mimeType: "text/plain" }];
    expect(r[0].name).toBe("x");
  });

  it("terminal.create result has terminalId", () => {
    const r: Result<"terminal.create"> = { terminalId: "abc123" };
    expect(r.terminalId).toBe("abc123");
  });

  it("session.pair result has publicKey and totpIssuerUri", () => {
    const r: Result<"session.pair"> = { publicKey: "pk", totpIssuerUri: "otpauth://..." };
    expect(r.totpIssuerUri).toContain("otpauth://");
  });

  it("session.authenticate result has token", () => {
    const r: Result<"session.authenticate"> = { token: "tok_xyz" };
    expect(r.token).toBe("tok_xyz");
  });

  it("system.getInfo result is SystemInfo", () => {
    const r: Result<"system.getInfo"> = {
      os: "linux",
      hostname: "box",
      cpuModel: "AMD",
      totalRamGb: 16,
      uptimeSeconds: 3600,
      username: "user",
      homeDir: "/home/user",
    };
    expect(r.os).toBe("linux");
  });

  it("system.getPerf result is PerfSnapshot", () => {
    const r: Result<"system.getPerf"> = {
      cpuPercent: 42,
      ramPercent: 65,
      ramUsedGb: 8.5,
      netInKBs: 120,
      netOutKBs: 80,
      diskReadMBs: 3.2,
      diskWriteMBs: 1.5,
    };
    expect(r.cpuPercent).toBe(42);
  });

  it("screen.startCapture params require quality and fps", () => {
    const p: Params<"screen.startCapture"> = { quality: "high", fps: 30 };
    expect(p.fps).toBe(30);
  });

  it("input.mouseClick params require button with optional coordinates", () => {
    const p: Params<"input.mouseClick"> = { button: "left", x: 100, y: 200 };
    expect(p.button).toBe("left");
  });

  it("input.keyEvent params accept modifiers", () => {
    const p: Params<"input.keyEvent"> = { key: "c", modifiers: ["ctrl"] };
    expect(p.modifiers).toContain("ctrl");
  });

  it("session.heartbeat params is empty object", () => {
    const p: Params<"session.heartbeat"> = {};
    expect(Object.keys(p)).toHaveLength(0);
  });

  it("process.list params is empty object", () => {
    const p: Params<"process.list"> = {};
    expect(Object.keys(p)).toHaveLength(0);
  });
});

describe("WsMessage discriminated union narrowing", () => {
  it("narrows rpc-request", () => {
    const msg: WsMessage = {
      type: "rpc-request",
      request: { id: 1, method: "system.getInfo" },
    };
    if (msg.type === "rpc-request") {
      expect(msg.request.method).toBe("system.getInfo");
    }
  });

  it("narrows rpc-response", () => {
    const msg: WsMessage = {
      type: "rpc-response",
      response: { id: 1, result: { os: "linux" } },
    };
    if (msg.type === "rpc-response") {
      expect(msg.response.result).toEqual({ os: "linux" });
    }
  });

  it("narrows rpc-response with error", () => {
    const msg: WsMessage = {
      type: "rpc-response",
      response: { id: 2, error: "not found" },
    };
    if (msg.type === "rpc-response") {
      expect(msg.response.error).toBe("not found");
    }
  });

  it("narrows stream-frame", () => {
    const msg: WsMessage = {
      type: "stream-frame",
      streamId: "s1",
      data: "base64data",
      timestamp: 1234567890,
    };
    if (msg.type === "stream-frame") {
      expect(msg.streamId).toBe("s1");
      expect(msg.timestamp).toBe(1234567890);
    }
  });

  it("narrows terminal-output", () => {
    const msg: WsMessage = {
      type: "terminal-output",
      terminalId: "t1",
      data: "output",
    };
    if (msg.type === "terminal-output") {
      expect(msg.terminalId).toBe("t1");
    }
  });

  it("narrows perf-update", () => {
    const data = { cpuPercent: 50, ramPercent: 70, ramUsedGb: 8, netInKBs: 0, netOutKBs: 0, diskReadMBs: 0, diskWriteMBs: 0 };
    const msg: WsMessage = { type: "perf-update", data };
    if (msg.type === "perf-update") {
      expect(msg.data.cpuPercent).toBe(50);
    }
  });

  it("narrows app-session-ready", () => {
    const msg: WsMessage = { type: "app-session-ready", sessionId: "sess-1" };
    if (msg.type === "app-session-ready") {
      expect(msg.sessionId).toBe("sess-1");
    }
  });
});

describe("createId", () => {
  it("returns a string", () => {
    const id = createId();
    expect(typeof id).toBe("string");
  });

  it("returns UUID v4 format", () => {
    const id = createId();
    const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    expect(uuidV4.test(id)).toBe(true);
  });

  it("each call returns unique id", () => {
    const ids = new Set<string>();
    for (let i = 0; i < 100; i++) {
      ids.add(createId());
    }
    expect(ids.size).toBe(100);
  });
});

describe("assertRpcEnvelope", () => {
  it("returns false for null", () => {
    expect(assertRpcEnvelope(null)).toBe(false);
  });

  it("returns false for undefined", () => {
    expect(assertRpcEnvelope(undefined)).toBe(false);
  });

  it("returns false for non-object", () => {
    expect(assertRpcEnvelope("string")).toBe(false);
    expect(assertRpcEnvelope(42)).toBe(false);
    expect(assertRpcEnvelope(true)).toBe(false);
  });

  it("returns false for object without type", () => {
    expect(assertRpcEnvelope({})).toBe(false);
    expect(assertRpcEnvelope({ foo: "bar" })).toBe(false);
  });

  it("returns false for non-string type", () => {
    expect(assertRpcEnvelope({ type: 42 })).toBe(false);
  });

  it("returns true for valid rpc-request envelope", () => {
    const env: RpcEnvelope = {
      type: "rpc-request",
      request: { id: 1, method: "fs.list", params: { path: "/" } },
    };
    expect(assertRpcEnvelope(env)).toBe(true);
  });

  it("returns true for valid rpc-response envelope", () => {
    const env: RpcEnvelope = {
      type: "rpc-response",
      response: { id: 1, result: "ok" },
    };
    expect(assertRpcEnvelope(env)).toBe(true);
  });

  it("returns true for rpc-response with error", () => {
    const env: RpcEnvelope = {
      type: "rpc-response",
      response: { id: 2, error: "failed" },
    };
    expect(assertRpcEnvelope(env)).toBe(true);
  });

  it("returns false for request missing id", () => {
    const env = {
      type: "rpc-request",
      request: { method: "fs.list" },
    };
    expect(assertRpcEnvelope(env)).toBe(false);
  });

  it("returns false for request missing method", () => {
    const env = {
      type: "rpc-request",
      request: { id: 1 },
    };
    expect(assertRpcEnvelope(env)).toBe(false);
  });

  it("returns false for response missing id", () => {
    const env = {
      type: "rpc-response",
      response: { result: "ok" },
    };
    expect(assertRpcEnvelope(env)).toBe(false);
  });

  it("returns true for stream-frame envelope", () => {
    const env: RpcEnvelope = {
      type: "stream-frame",
      streamId: "s1",
      data: "base64",
      timestamp: 123,
    };
    expect(assertRpcEnvelope(env)).toBe(true);
  });

  it("returns true for perf-update envelope", () => {
    const env: RpcEnvelope = {
      type: "perf-update",
      data: { cpuPercent: 50 },
    };
    expect(assertRpcEnvelope(env)).toBe(true);
  });
});

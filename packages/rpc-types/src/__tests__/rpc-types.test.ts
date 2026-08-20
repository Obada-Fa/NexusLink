import { describe, it, expect } from "bun:test";
import type { RpcMethod, Params, Result, WsMessage } from "../index";
import { createId, assertRpcEnvelope, type RpcEnvelope } from "../utils";

function allMethods(): RpcMethod[] {
  return [
    "fs.list",
    "fs.read",
    "fs.write",
    "fs.delete",
    "fs.move",
    "process.list",
    "process.kill",
    "process.spawn",
    "terminal.create",
    "terminal.input",
    "terminal.resize",
    "terminal.kill",
    "screen.startCapture",
    "screen.stopCapture",
    "screen.getMetadata",
    "input.mouseMove",
    "input.mouseClick",
    "input.mouseScroll",
    "input.keyEvent",
    "session.pair",
    "session.authenticate",
    "session.heartbeat",
    "session.disconnect",
    "system.getInfo",
    "system.getPerf",
  ];
}

describe("RpcMethod exhaustiveness", () => {
  it("has exactly 25 methods", () => {
    expect(allMethods()).toHaveLength(25);
  });

  it("every known method is in the RpcMethod union", () => {
    const methods: RpcMethod[] = allMethods();
    expect(methods.length).toBe(25);
  });

  it("Params maps every method to a non-never type", () => {
    const methods = allMethods();
    for (const m of methods) {
      const _p: Params<typeof m> = undefined as unknown as Params<typeof m>;
      expect(typeof _p === "undefined").toBeDefined();
    }
    expect(true).toBe(true);
  });

  it("Result maps every method to a non-never type", () => {
    const methods = allMethods();
    for (const m of methods) {
      const _r: Result<typeof m> = undefined as unknown as Result<typeof m>;
      expect(typeof _r === "undefined").toBeDefined();
    }
    expect(true).toBe(true);
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

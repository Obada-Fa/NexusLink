// Real-PTY terminal: the shell must see an actual TTY (colors, job control,
// TUI apps) — the property the old pipe-based fallback could not provide.

import { describe, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import type { WsMessage } from '@nexuslink/rpc-types';
import {
  setSend,
  handleTerminalCreate,
  handleTerminalInput,
  handleTerminalResize,
  handleTerminalKill,
} from '../terminal';

const hasPython = existsSync('/usr/bin/python3');

describe.if(hasPython)('pty-backed terminal', () => {
  test(
    'shell runs on a real tty and echoes interactive input',
    async () => {
      let output = '';
      setSend((_ws, msg: WsMessage) => {
        if (msg.type === 'terminal-output') output += msg.data;
      });
      const fakeWs = { readyState: 1 } as unknown as WebSocket;

      const { terminalId } = handleTerminalCreate(80, 24, '/bin/bash', fakeWs);
      await Bun.sleep(700);

      handleTerminalInput(terminalId, 'tty; echo MARK-$((40+2))\r');
      const deadline = Date.now() + 6000;
      while (!output.includes('MARK-42') && Date.now() < deadline) {
        await Bun.sleep(100);
      }

      // A pipe-backed shell would print "not a tty"; a PTY prints /dev/pts/N.
      expect(output).toContain('/dev/pts/');
      expect(output).not.toContain('not a tty');
      expect(output).toContain('MARK-42');

      // Resize must not kill the shell.
      handleTerminalResize(terminalId, 100, 40);
      await Bun.sleep(200);
      handleTerminalInput(terminalId, 'echo COLS-$COLUMNS\r');
      const deadline2 = Date.now() + 6000;
      while (!output.includes('COLS-100') && Date.now() < deadline2) {
        await Bun.sleep(100);
      }
      expect(output).toContain('COLS-100');

      handleTerminalKill(terminalId);
    },
    20_000,
  );
});

// Stand-in for the `claude` CLI in adapter tests: replays a stream-json script.
//
// FAKE_CLAUDE_SCRIPT  JSONL file. Plain lines are written to stdout as they
//                     are. Lines with a "__fake" key are directives:
//                       {"__fake":"wait_stdin"}        wait for one stdin line
//                       {"__fake":"sleep","ms":50}     pause
//                       {"__fake":"exit","code":1}     exit now
//                     The fake first waits for the prompt line on stdin, and
//                     after the script it waits for stdin to close, like the
//                     real CLI in --input-format stream-json mode.
// FAKE_CLAUDE_ARGV    optional file that receives the argv as JSON.
// FAKE_CLAUDE_STDIN   optional file that receives every stdin line.
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';

if (process.env.FAKE_CLAUDE_ARGV) writeFileSync(process.env.FAKE_CLAUDE_ARGV, JSON.stringify(process.argv.slice(2)));

const lines: string[] = [];
const waiters: Array<(line: string | null) => void> = [];
let closed = false;

function push(line: string | null): void {
  if (line !== null && process.env.FAKE_CLAUDE_STDIN) appendFileSync(process.env.FAKE_CLAUDE_STDIN, line + '\n');
  const waiter = waiters.shift();
  if (waiter) waiter(line);
  else if (line !== null) lines.push(line);
}

function nextLine(): Promise<string | null> {
  if (lines.length) return Promise.resolve(lines.shift()!);
  if (closed) return Promise.resolve(null);
  return new Promise((resolve) => waiters.push(resolve));
}

void (async () => {
  const decoder = new TextDecoder();
  let buf = '';
  for await (const chunk of Bun.stdin.stream()) {
    buf += decoder.decode(chunk, { stream: true });
    let nl: number;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (line.trim()) push(line);
    }
  }
  closed = true;
  while (waiters.length) push(null);
})();

const script = readFileSync(process.env.FAKE_CLAUDE_SCRIPT!, 'utf8').split('\n').filter((l) => l.trim());
await nextLine();
for (const line of script) {
  const parsed = JSON.parse(line) as Record<string, unknown>;
  if (parsed.__fake === 'wait_stdin') {
    await nextLine();
  } else if (parsed.__fake === 'sleep') {
    await Bun.sleep(Number(parsed.ms ?? 10));
  } else if (parsed.__fake === 'exit') {
    process.exit(Number(parsed.code ?? 0));
  } else {
    process.stdout.write(line + '\n');
    await Bun.sleep(2);
  }
}
while ((await nextLine()) !== null) {
  // keep reading until the host closes stdin or kills us
}
process.exit(0);

// Stand-in for the `agy` CLI in Antigravity adapter tests (one-shot -p run).
//
// FAKE_AGY_SCRIPT  JSONL file. Plain lines are written to stdout as they are.
//                  Lines with a "__fake" key are directives:
//                    {"__fake":"sleep","ms":50}
//                    {"__fake":"stderr","text":"boom"}
//                    {"__fake":"exit","code":3}
//                    {"__fake":"kill_self"}      SIGKILL this process
//                    {"__fake":"spawn_bg","ms":3000}  leave a child that keeps
//                                                     stdout open after exit
// `agy models` and other subcommands print nothing and exit 0.
import { readFileSync } from 'node:fs';

if (process.argv[2] === 'models' || !process.env.FAKE_AGY_SCRIPT) process.exit(0);

const script = readFileSync(process.env.FAKE_AGY_SCRIPT, 'utf8').split('\n').filter((l) => l.trim());
for (const line of script) {
  const parsed = JSON.parse(line) as Record<string, unknown>;
  if (parsed.__fake === 'sleep') {
    await Bun.sleep(Number(parsed.ms ?? 10));
  } else if (parsed.__fake === 'stderr') {
    process.stderr.write(String(parsed.text ?? '') + '\n');
  } else if (parsed.__fake === 'exit') {
    process.exit(Number(parsed.code ?? 0));
  } else if (parsed.__fake === 'kill_self') {
    process.kill(process.pid, 'SIGKILL');
    await Bun.sleep(1000);
  } else if (parsed.__fake === 'spawn_bg') {
    // Inherits our stdout/stderr, like a daemon forked by the CLI would.
    Bun.spawn(['sleep', String(Number(parsed.ms ?? 3000) / 1000)], { stdin: 'ignore', stdout: 'inherit', stderr: 'inherit' });
  } else {
    process.stdout.write(line + '\n');
    await Bun.sleep(2);
  }
}
process.exit(0);

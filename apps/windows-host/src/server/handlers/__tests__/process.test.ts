import { describe, expect, test } from 'bun:test';
import { parseTasklistCsv } from '../process';

describe('parseTasklistCsv', () => {
  test('parses image name, pid, and working set', () => {
    const rows = parseTasklistCsv(
      '"chrome.exe","1234","Console","1","120,456 K"\r\n"bun.exe","56","Console","1","80,000 K"\n',
    );
    expect(rows).toEqual([
      { pid: 1234, name: 'chrome.exe', cpuPercent: 0, memMb: 118 },
      { pid: 56, name: 'bun.exe', cpuPercent: 0, memMb: 78 },
    ]);
  });

  test('skips junk lines', () => {
    expect(parseTasklistCsv('ERROR: access denied')).toEqual([]);
  });
});

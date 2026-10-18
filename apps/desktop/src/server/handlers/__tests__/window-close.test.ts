import { afterEach, expect, spyOn, test } from 'bun:test';
import { closeWindow } from '../windows';

let spawn: ReturnType<typeof spyOn> | undefined;
afterEach(() => spawn?.mockRestore());

test('close requests a normal window-manager close without a shell', () => {
  spawn = spyOn(Bun, 'spawnSync').mockReturnValue({ exitCode: 0 } as any);
  expect(closeWindow('0x0123abcd')).toEqual({ ok: true });
  expect(spawn.mock.calls[0][0]).toEqual(['wmctrl', '-i', '-c', '0x0123abcd']);
});

test('invalid window IDs cannot invoke the command', () => {
  spawn = spyOn(Bun, 'spawnSync');
  for (const value of ['', '-1', '0x123; echo bad', undefined]) {
    expect(() => closeWindow(value as string)).toThrow('Invalid window ID');
  }
  expect(spawn).not.toHaveBeenCalled();
});

test('window-manager failure is reported', () => {
  spawn = spyOn(Bun, 'spawnSync').mockReturnValue({ exitCode: 1 } as any);
  expect(() => closeWindow('0x123')).toThrow('Could not close');
});

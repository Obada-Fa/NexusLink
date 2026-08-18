import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/cwd_picker.dart';
import 'package:nexuslink/src/state/last_cwd.dart';

void main() {
  test('parentUnixPath walks up to root', () {
    expect(parentUnixPath('/home/obada/Projects'), '/home/obada');
    expect(parentUnixPath('/home/obada'), '/home');
    expect(parentUnixPath('/home'), '/');
    expect(parentUnixPath('/'), '/');
    expect(parentUnixPath('/home/obada/'), '/home');
  });

  test('mergeRecentAgentCwd keeps newest first without duplicates', () {
    expect(
      mergeRecentAgentCwd('/tmp/b', ['/tmp/a', '/tmp/b']),
      ['/tmp/b', '/tmp/a'],
    );
    final many = List.generate(recentAgentCwdCap, (i) => '/p$i');
    final merged = mergeRecentAgentCwd('/new', many);
    expect(merged.length, recentAgentCwdCap);
    expect(merged.first, '/new');
  });
}

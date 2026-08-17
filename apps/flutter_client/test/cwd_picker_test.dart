import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/cwd_picker.dart';

void main() {
  test('parentUnixPath walks up to root', () {
    expect(parentUnixPath('/home/obada/Projects'), '/home/obada');
    expect(parentUnixPath('/home/obada'), '/home');
    expect(parentUnixPath('/home'), '/');
    expect(parentUnixPath('/'), '/');
    expect(parentUnixPath('/home/obada/'), '/home');
  });
}

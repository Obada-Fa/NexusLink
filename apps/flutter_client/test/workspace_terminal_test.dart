import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/workspace/terminal_repository.dart';

class TerminalHost extends RpcClient {
  TerminalHost():super('ws://pc/rpc') {hostId='pc';}
  final calls=<String>[];
  final handlers=<String,List<void Function(Map<String,dynamic>)>>{};
  final output=<Map<String,dynamic>>[];
  Completer<void>? attachGate;
  int creates=0;
  @override RpcStatus get status=>RpcStatus.connected;
  @override bool supports(String feature)=>true;
  @override void Function() subscribe(String topic,void Function(Map<String,dynamic>) callback){
    final entries=handlers.putIfAbsent(topic,()=>[]);entries.add(callback);return ()=>entries.remove(callback);
  }
  void emit(String topic,Map<String,dynamic> event){for(final cb in List.of(handlers[topic]??[])){cb(event);}}
  @override Future<Map<String,dynamic>> requestMap(String method,[Map<String,dynamic> params=const {},Duration timeout=const Duration(seconds:10)])async{
    calls.add(method);
    if(method=='terminal.create') {creates++;output.add({'terminalId':'shell','seq':1,'data':'first prompt\r\n'});return {'terminalId':'shell'};}
    if(method=='terminal.attach') {
      await attachGate?.future;
      for(final event in output.where((e)=>(e['seq'] as int)>(params['afterSeq'] as int))) {emit('terminal-output',event);}
      return {'state':'running'};
    }
    return {};
  }
  @override void notify(String method,Map<String,dynamic> params){calls.add(method);}
}

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(()=>SharedPreferences.setMockInitialValues({}));
  test('first prompt replays after creation, navigation preserves shell, reconnect deduplicates',()async{
    final host=TerminalHost();final terminal=RemoteTerminal('pc','task',cwd:'/project');
    await terminal.bind(host);
    expect(terminal.ready,isTrue);expect(terminal.seq,1);expect(host.creates,1);
    terminal.show(false,host);
    expect(host.calls,contains('terminal.detach'));expect(host.calls, isNot(contains('terminal.kill')));
    host.output.add({'terminalId':'shell','seq':2,'data':'while away\r\n'});
    terminal.visible=true;await terminal.bind(host);
    expect(terminal.seq,2);expect(host.creates,1);
    host.emit('terminal-output',{'terminalId':'shell','seq':1,'data':'duplicate'});
    expect(terminal.seq,2);
    terminal.dispose();host.dispose();
  });
  test('input stays disabled until attach completes; late attachment cannot undo detach',()async{
    final host=TerminalHost()..attachGate=Completer<void>();final terminal=RemoteTerminal('pc','global');
    final attaching=terminal.bind(host);
    await Future<void>.delayed(Duration.zero);
    terminal.input('before attached');expect(host.calls,isNot(contains('terminal.input')));
    terminal.show(false,host);host.attachGate!.complete();await attaching;
    expect(terminal.ready,isFalse);expect(host.creates,1);
    terminal.dispose();host.dispose();
  });
  test('repository reuses controller by host and terminal identity',()async{
    final host=TerminalHost();final repository=TerminalRepository()..bind(host);
    final first=repository.get('task');await first.bind(host);
    expect(identical(first,repository.get('global',terminalId:'shell')),isTrue);
    repository.dispose();host.dispose();
  });
}

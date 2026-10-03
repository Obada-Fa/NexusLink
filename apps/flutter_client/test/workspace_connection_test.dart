import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';

void main(){
 test('enrollment precedes capabilities; explicit disconnect stays disconnected',()async{
   final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
   final methods=<String>[];var connections=0;
   final sockets=<WebSocket>[];
   server.listen((request)async{
     final ws=await WebSocketTransformer.upgrade(request);sockets.add(ws);connections++;
     ws.listen((raw){
       final request=jsonDecode(raw as String)['request'] as Map<String,dynamic>;
       final method=request['method'] as String;methods.add(method);
       final result=switch(method){
         'session.hello'=>{'protocolVersion':2},
         'session.enroll'=>{'credential':'test-only','token':'test-token','hostId':'test-pc'},
         'session.getCapabilities'=>{'features':['session.subscribe','terminal.attach']},
         _=>{'ok':true},
       };
       ws.add(jsonEncode({'type':'rpc-response','response':{'id':request['id'],'result':result}}));
     });
   });
   final client=RpcClient('ws://127.0.0.1:${server.port}/rpc',pairingCode:'12345678');
   try{
     await client.connect();expect(client.status,RpcStatus.connected);expect(client.hostId,'test-pc');
     expect(methods.take(3),['session.hello','session.enroll','session.getCapabilities']);
     client.disconnect();await Future<void>.delayed(const Duration(milliseconds:1200));
     expect(connections,1);expect(client.phase,'disconnected by user');
   }finally{client.dispose();for(final socket in sockets){await socket.close();}await server.close(force:true);}
 });
 test('socket closing during handshake cannot report a successful connection',()async{
   final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
   server.listen((request)async{final ws=await WebSocketTransformer.upgrade(request);ws.listen((_)=>ws.close());});
   final client=RpcClient('ws://127.0.0.1:${server.port}/rpc');
   try{await expectLater(client.connect(),throwsA(isA<RpcException>()));expect(client.status,isNot(RpcStatus.connected));}
   finally{client.dispose();await server.close(force:true);}
 });
}

import { LibraryStorage } from './storage';
let storage: LibraryStorage;
self.onmessage = (event: MessageEvent) => {
  const {id,op,data} = event.data;
  try {
    let result: any;
    switch (op) {
      case 'init': storage=new LibraryStorage(data.directory); result=storage.revision(); break;
      case 'get': result=storage.get(data.id); break;
      case 'upsert': result=storage.upsert(data.rows,data.source,data.removeMissing); break;
      case 'hot': result=storage.hot(data.since,data.limit); break;
      case 'setState': result=storage.setState(data.id,data.change); break;
      case 'decay': result=storage.decay(); break;
      case 'list': result=storage.page(data); break;
      case 'folders': result=storage.page(data,true); break;
      case 'health': storage.setHealth(data); result=storage.revision(); break;
      case 'historyFingerprint': result=storage.historyFingerprint(data.chat); break;
      case 'indexHistory': storage.indexHistory(data.chat,data.fingerprint,data.events,data.reason); result=true; break;
      case 'historyPage': result=storage.historyPage(data.chat,data.params); break;
      case 'claim': result=storage.claim(data.device,data.operationId,data.args); break;
      case 'finish': result=storage.finish(data.device,data.body); break;
      case 'status': result=storage.operation(data.device,data.operationId); break;
      case 'close': storage.close(); result=true; break;
      default: throw new Error('Unknown library storage request');
    }
    self.postMessage({id,result});
  } catch (error) { self.postMessage({id,error:error instanceof Error ? error.message : 'Chat storage failed'}); }
};

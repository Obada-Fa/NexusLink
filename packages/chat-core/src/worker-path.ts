/** Bundled modules share the executable URL; embedded worker entries keep repository paths. */
export function workerPath(relative:string,moduleUrl:string,embedded:string):string {
  const decoded=decodeURIComponent(moduleUrl);
  const compiled=decoded.includes('~BUN') || decoded.includes('$bunfs');
  return compiled ? `./${embedded}` : new URL(relative,moduleUrl).href;
}

/** Shared phone-side path math for Unix hosts and Windows drive letters. */

export function toPosixPath(path: string): string {
  return (path || '').replace(/\\/g, '/');
}

export function isThisPcPath(path: string): boolean {
  const p = toPosixPath(path).replace(/\/+$/, '') || '/';
  return p === '/' || p.toLowerCase() === 'this pc';
}

export function isWindowsDriveRoot(path: string): boolean {
  const p = toPosixPath(path).replace(/\/+$/, '');
  return /^[A-Za-z]:$/.test(p);
}

/**
 * Parent of a host path. Drive roots (`C:` / `C:/`) go to This PC (`/`),
 * not the user profile.
 */
export function parentHostPath(path: string): string {
  if (!path || isThisPcPath(path)) return '/';
  let p = toPosixPath(path);
  if (p.endsWith('/') && p !== '/') p = p.slice(0, -1);
  if (isWindowsDriveRoot(p)) return '/';
  const i = p.lastIndexOf('/');
  if (i <= 0) return '/';
  const parent = p.slice(0, i);
  if (isWindowsDriveRoot(parent)) return `${parent}/`;
  return parent;
}

export function folderDisplayName(path: string): string {
  if (isThisPcPath(path)) return 'This PC';
  if (!path) return path;
  const trimmed = path.endsWith('/') && path !== '/' ? path.slice(0, -1) : path;
  if (/^[A-Za-z]:$/.test(trimmed)) return trimmed;
  const i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.slice(i + 1);
}

export function normalizeGoPath(raw: string): string {
  const val = raw.trim();
  if (!val) return val;
  if (isThisPcPath(val)) return '/';
  if (val.startsWith('~') || /^[A-Za-z]:/.test(val) || val.startsWith('/')) return val;
  return `/${val}`;
}

export interface PathCrumb {
  label: string;
  path: string;
}

export function hostPathCrumbs(cwd: string): PathCrumb[] {
  if (!cwd || isThisPcPath(cwd)) return [{ label: 'This PC', path: '/' }];
  const p = toPosixPath(cwd);
  if (/^[A-Za-z]:/.test(p)) {
    const segs = p.split('/').filter(Boolean);
    const crumbs: PathCrumb[] = [{ label: 'This PC', path: '/' }];
    if (segs.length === 0) return crumbs;
    let acc = `${segs[0]}/`;
    crumbs.push({ label: segs[0]!, path: acc });
    for (let i = 1; i < segs.length; i++) {
      acc = `${acc.endsWith('/') ? acc : `${acc}/`}${segs[i]}`;
      crumbs.push({ label: segs[i]!, path: acc });
    }
    return crumbs;
  }
  const segs = p.split('/').filter(Boolean);
  const crumbs: PathCrumb[] = [{ label: '/', path: '/' }];
  let acc = '';
  for (const seg of segs) {
    acc += `/${seg}`;
    crumbs.push({ label: seg, path: acc });
  }
  return crumbs;
}

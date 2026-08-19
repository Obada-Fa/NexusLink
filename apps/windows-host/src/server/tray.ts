import { spawn } from 'node:child_process';

let trayProc: ReturnType<typeof spawn> | null = null;

const TRAY_PS = `
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Visible = $true
$notify.Text = 'NexusLink Windows host'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$open = $menu.Items.Add('Open http://localhost:45678')
$open.add_Click({ Start-Process 'http://localhost:45678' })
$quit = $menu.Items.Add('Quit host')
$quit.add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({ Start-Process 'http://localhost:45678' })
[System.Windows.Forms.Application]::Run()
`;

export function startTray(): void {
  if (process.env.NEXUSLINK_NO_TRAY === '1') return;
  if (trayProc) return;
  try {
    trayProc = spawn('powershell.exe', [
      '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-Command', TRAY_PS,
    ], {
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
    });
    trayProc.unref();
  } catch (err) {
    console.warn('[tray] could not start notification icon:', err);
  }
}

export function stopTray(): void {
  try {
    trayProc?.kill();
  } catch {
    // already gone
  }
  trayProc = null;
}

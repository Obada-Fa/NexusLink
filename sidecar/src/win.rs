#![cfg(windows)]

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::sync::{Mutex, OnceLock};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};

use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HGDIOBJ, SRCCOPY,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    mouse_event, SetCursorPos, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN,
    MOUSEEVENTF_RIGHTUP,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetSystemMetrics, GetWindowTextW, IsWindowVisible, SM_CXSCREEN, SM_CYSCREEN,
};

struct PtySession {
    writer: Box<dyn Write + Send>,
    pair: portable_pty::PtyPair,
}

fn ptys() -> &'static Mutex<HashMap<String, PtySession>> {
    static P: OnceLock<Mutex<HashMap<String, PtySession>>> = OnceLock::new();
    P.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn screen_metadata() -> Result<Value, String> {
    unsafe {
        let width = GetSystemMetrics(SM_CXSCREEN);
        let height = GetSystemMetrics(SM_CYSCREEN);
        Ok(json!({ "width": width, "height": height, "x": 0, "y": 0 }))
    }
}

pub fn screen_grab(_params: Option<Value>) -> Result<Value, String> {
    unsafe {
        let w = GetSystemMetrics(SM_CXSCREEN);
        let h = GetSystemMetrics(SM_CYSCREEN);
        if w <= 0 || h <= 0 {
            return Err("no screen".into());
        }
        let hdc = GetDC(HWND(0));
        let mem = CreateCompatibleDC(hdc);
        let hbmp = CreateCompatibleBitmap(hdc, w, h);
        let old = SelectObject(mem, HGDIOBJ(hbmp.0));
        let _ = BitBlt(mem, 0, 0, w, h, hdc, 0, 0, SRCCOPY);
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bgra = vec![0u8; (w * h * 4) as usize];
        GetDIBits(mem, hbmp, 0, h as u32, Some(bgra.as_mut_ptr() as *mut _), &mut info, DIB_RGB_COLORS);
        SelectObject(mem, old);
        let _ = DeleteObject(HGDIOBJ(hbmp.0));
        let _ = DeleteDC(mem);
        ReleaseDC(HWND(0), hdc);

        let mut rgb = vec![0u8; (w * h * 3) as usize];
        for i in 0..(w * h) as usize {
            rgb[i * 3] = bgra[i * 4 + 2];
            rgb[i * 3 + 1] = bgra[i * 4 + 1];
            rgb[i * 3 + 2] = bgra[i * 4];
        }
        let img = image::RgbImage::from_raw(w as u32, h as u32, rgb).ok_or("image")?;
        let mut jpeg = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut jpeg);
        image::DynamicImage::ImageRgb8(img)
            .write_to(&mut cursor, image::ImageFormat::Jpeg)
            .map_err(|e| e.to_string())?;
        Ok(json!({ "jpeg": base64::Engine::encode(&base64::engine::general_purpose::STANDARD, jpeg) }))
    }
}

pub fn mouse_move_abs(params: Option<Value>) -> Result<Value, String> {
    let p = params.unwrap_or(Value::Null);
    let x = p.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
    let y = p.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
    unsafe {
        let _ = SetCursorPos(x, y);
    }
    Ok(json!({ "ok": true }))
}

pub fn mouse_click(params: Option<Value>) -> Result<Value, String> {
    let _ = mouse_move_abs(params.clone());
    let button = params
        .as_ref()
        .and_then(|p| p.get("button"))
        .and_then(|v| v.as_str())
        .unwrap_or("left");
    unsafe {
        if button == "right" {
            mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0);
            mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0);
        } else {
            mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
            mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        }
    }
    Ok(json!({ "ok": true }))
}

pub fn type_text(params: Option<Value>) -> Result<Value, String> {
    let _ = params;
    Ok(json!({ "ok": true }))
}

unsafe extern "system" fn enum_cb(hwnd: HWND, lparam: windows::Win32::Foundation::LPARAM) -> windows::Win32::Foundation::BOOL {
    let out = &mut *(lparam.0 as *mut Vec<Value>);
    if IsWindowVisible(hwnd).as_bool() {
        let mut buf = [0u16; 512];
        let n = GetWindowTextW(hwnd, &mut buf);
        if n > 0 {
            let title = String::from_utf16_lossy(&buf[..n as usize]);
            out.push(json!({
                "windowId": format!("{}", hwnd.0 as usize),
                "title": title,
                "wmClass": "",
                "desktop": 0
            }));
        }
    }
    windows::Win32::Foundation::BOOL(1)
}

pub fn window_list() -> Result<Value, String> {
    let mut out: Vec<Value> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(enum_cb), windows::Win32::Foundation::LPARAM(&mut out as *mut _ as isize));
    }
    Ok(Value::Array(out))
}

pub fn pty_create(params: Option<Value>) -> Result<Value, String> {
    let p = params.unwrap_or(Value::Null);
    let cols = p.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
    let rows = p.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
    let shell = p
        .get("shell")
        .and_then(|v| v.as_str())
        .unwrap_or("powershell.exe")
        .to_string();
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;
    let cmd = CommandBuilder::new(shell);
    let _child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let id = uuid_like();
    ptys().lock().unwrap().insert(id.clone(), PtySession { writer, pair });
    Ok(json!({ "terminalId": id }))
}

pub fn pty_input(params: Option<Value>) -> Result<Value, String> {
    let p = params.unwrap_or(Value::Null);
    let id = p.get("terminalId").and_then(|v| v.as_str()).ok_or("terminalId")?;
    let data = p.get("data").and_then(|v| v.as_str()).unwrap_or("");
    let mut map = ptys().lock().unwrap();
    let session = map.get_mut(id).ok_or("unknown terminal")?;
    session.writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    Ok(json!({ "ok": true }))
}

pub fn pty_resize(params: Option<Value>) -> Result<Value, String> {
    let p = params.unwrap_or(Value::Null);
    let id = p.get("terminalId").and_then(|v| v.as_str()).ok_or("terminalId")?;
    let cols = p.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
    let rows = p.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
    let map = ptys().lock().unwrap();
    let session = map.get(id).ok_or("unknown terminal")?;
    session
        .pair
        .master
        .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;
    Ok(json!({ "ok": true }))
}

pub fn pty_kill(params: Option<Value>) -> Result<Value, String> {
    let p = params.unwrap_or(Value::Null);
    let id = p.get("terminalId").and_then(|v| v.as_str()).ok_or("terminalId")?;
    ptys().lock().unwrap().remove(id);
    Ok(json!({ "ok": true }))
}

fn uuid_like() -> String {
    format!("{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos())
}

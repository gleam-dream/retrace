#[cfg(feature = "native-smoke")]
static NATIVE_CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
#[tauri::command]
fn platform_info() -> String {
    #[cfg(feature = "native-smoke")]
    NATIVE_CALLS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    format!("{} / {}", std::env::consts::OS, std::env::consts::ARCH)
}
#[cfg(feature = "native-smoke")]
#[tauri::command]
fn smoke_report(app: tauri::AppHandle, result: String) {
    let valid =
        result.starts_with("PASS ") && NATIVE_CALLS.load(std::sync::atomic::Ordering::SeqCst) == 1;
    println!("{result}");
    if !valid {
        eprintln!("Native check requires exactly one native call, with none during replay");
    }
    app.exit(if valid { 0 } else { 1 });
}
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::default().build())
        .invoke_handler(tauri::generate_handler![platform_info]);
    #[cfg(feature = "native-smoke")]
    let builder = builder
        .invoke_handler(tauri::generate_handler![platform_info, smoke_report])
        .setup(|app| {
            if std::env::var("RETRACE_NATIVE_SMOKE").as_deref() == Ok("1") {
                let handle = app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(30));
                    eprintln!("FAIL native runtime check exceeded 30 seconds");
                    handle.exit(1);
                });
            }
            Ok(())
        })
        .on_page_load(|window, payload| {
            if std::env::var("RETRACE_NATIVE_SMOKE").as_deref() == Ok("1")
                && payload.event() == tauri::webview::PageLoadEvent::Started
            {
                // The automation host has no visible display. Only the opt-in
                // check supplies render frames; native IPC/storage stay real.
                window.eval("window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16); window.cancelAnimationFrame = clearTimeout;").expect("native frame driver");
            }
            if std::env::var("RETRACE_NATIVE_SMOKE").as_deref() == Ok("1")
                && payload.event() == tauri::webview::PageLoadEvent::Finished
            {
                let _ = window.window().show();
                let _ = window.window().set_focus();
                window
                    .eval(include_str!("../../../../dev/native-check.js"))
                    .expect("native check injection");
            }
        });
    builder
        .run(tauri::generate_context!())
        .expect("could not start Retrace example");
}

use serde::Serialize;

#[derive(Serialize)]
pub struct ScreenInfo {
    pub width: u32,
    pub height: u32,
}

pub fn get_primary_screen_info() -> Result<ScreenInfo, Box<dyn std::error::Error>> {
    let monitors = xcap::Monitor::all()?;
    let monitor = monitors.into_iter().next().ok_or("No monitor found")?;

    Ok(ScreenInfo {
        width: monitor.width()?,
        height: monitor.height()?,
    })
}

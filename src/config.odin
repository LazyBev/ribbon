package main

DataSource :: union {
  DataInline,
  DataClock,
  DataCpu,
  DataMemory,
  DataBattery,
  DataBatteryState,
  DataDistro,
  DataDistroLogo,
  DataWifi,
  DataVolume,
  DataCmd,
}

DataInline :: struct { text: string }
DataClock  :: struct {}
DataCpu    :: struct {}
DataMemory :: struct {}
DataBattery :: struct {}
DataBatteryState :: struct {}
DataDistro  :: struct {}
DataDistroLogo :: struct { name: string }
DataWifi    :: struct {}
DataVolume  :: struct {}
DataCmd     :: struct { command: string }

Segment :: struct {
  source: DataSource,
  color:  string,
  fmt:    string,
}

BarConfig :: struct {
  font_family: string,
  font_size:   int,
  font_color:  string,
  bg_color:    string,
  height:      int,
  interval:    int,
  systray:     bool,
  logo:        string,
  logo_size:   int,
  left:        []Segment,
  center:      []Segment,
  right:       []Segment,
  left_pad:    int,
  center_pad:  int,
  right_pad:   int,
  separator_text:  string,
  separator_color: string,
  wifi_icon:   bool,
  left_vy:     f64,
  center_vy:   f64,
  right_vy:    f64,
  widget_gap:  int,
  format_battery: string,
  format_wifi:    string,
}

default_config :: proc() -> BarConfig {
  return BarConfig{
    font_family = "DejaVu Sans",
    font_size   = 14,
    font_color  = "#c0caf5",
    bg_color    = "#1e1e2e",
    height      = 30,
    interval    = 1,
    systray     = false,
    logo        = "",
    logo_size   = 0,
    left        = {},
    center      = {},
    right       = {},
    left_pad    = 0,
    center_pad  = 0,
    right_pad   = 10,
    separator_text  = "",
    separator_color = "",
    wifi_icon   = true,
    left_vy     = 0,
    center_vy   = 0,
    right_vy    = 0,
    widget_gap  = 8,
    format_battery = "{}",
    format_wifi    = "{}",
  }
}

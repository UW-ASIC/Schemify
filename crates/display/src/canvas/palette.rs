use egui::Color32;

/// Canvas color constants for schematic rendering.
pub struct CanvasPalette {
    pub canvas_bg: Color32,
    pub grid_dot: Color32,
    pub wire: Color32,
    pub wire_selected: Color32,
    pub wire_endpoint: Color32,
    pub bus: Color32,
    pub inst_body: Color32,
    pub inst_selected: Color32,
    pub inst_pin: Color32,
    pub symbol_line: Color32,
    pub wire_preview: Color32,
    pub origin: Color32,
    pub selection_rect: Color32,
    pub rubber_band: Color32,
    pub text_label: Color32,
    pub geometry_line: Color32,
    pub geometry_fill: Color32,
}

impl CanvasPalette {
    pub fn dark() -> Self {
        Self {
            canvas_bg: Color32::from_rgb(30, 30, 36),
            grid_dot: Color32::from_rgba_premultiplied(80, 80, 90, 120),
            wire: Color32::from_rgb(100, 200, 100),
            wire_selected: Color32::from_rgb(255, 200, 50),
            wire_endpoint: Color32::from_rgb(130, 220, 130),
            bus: Color32::from_rgb(80, 140, 220),
            inst_body: Color32::from_rgb(200, 200, 210),
            inst_selected: Color32::from_rgb(255, 200, 50),
            inst_pin: Color32::from_rgb(200, 80, 80),
            symbol_line: Color32::from_rgb(200, 200, 210),
            wire_preview: Color32::from_rgb(255, 140, 40),
            origin: Color32::from_rgba_premultiplied(100, 100, 120, 80),
            selection_rect: Color32::from_rgba_premultiplied(80, 140, 255, 60),
            rubber_band: Color32::from_rgba_premultiplied(80, 140, 255, 40),
            text_label: Color32::from_rgba_premultiplied(180, 180, 195, 200),
            geometry_line: Color32::from_rgb(180, 180, 195),
            geometry_fill: Color32::from_rgba_premultiplied(60, 60, 80, 40),
        }
    }

    pub fn light() -> Self {
        Self {
            canvas_bg: Color32::from_rgb(245, 245, 248),
            grid_dot: Color32::from_rgba_premultiplied(160, 160, 170, 120),
            wire: Color32::from_rgb(30, 140, 30),
            wire_selected: Color32::from_rgb(200, 140, 0),
            wire_endpoint: Color32::from_rgb(40, 160, 40),
            bus: Color32::from_rgb(40, 80, 180),
            inst_body: Color32::from_rgb(50, 50, 60),
            inst_selected: Color32::from_rgb(200, 140, 0),
            inst_pin: Color32::from_rgb(180, 40, 40),
            symbol_line: Color32::from_rgb(50, 50, 60),
            wire_preview: Color32::from_rgb(220, 100, 20),
            origin: Color32::from_rgba_premultiplied(140, 140, 160, 80),
            selection_rect: Color32::from_rgba_premultiplied(40, 100, 220, 60),
            rubber_band: Color32::from_rgba_premultiplied(40, 100, 220, 30),
            text_label: Color32::from_rgba_premultiplied(60, 60, 70, 200),
            geometry_line: Color32::from_rgb(60, 60, 70),
            geometry_fill: Color32::from_rgba_premultiplied(200, 200, 220, 40),
        }
    }
}

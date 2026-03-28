//! gui/Components — re-exports all reusable UI component types.
//!
//! Import as:
//!   const components = @import("../Components/root.zig");
//!   const fw = components.FloatingWindow(.{ .title = "My Dialog" });

pub const FloatingWindow = @import("FloatingWindow.zig").FloatingWindow;
pub const HorizontalBar  = @import("HorizontalBar.zig").HorizontalBar;

//! gui/Components -- re-exports all reusable UI component types.
//!
//! Import as:
//!   const components = @import("../Components/lib.zig");
//!   const fw = components.FloatingWindow(.{ .title = "My Dialog" });

pub const FloatingWindow = @import("FloatingWindow.zig").FloatingWindow;
pub const HorizontalBar = @import("HorizontalBar.zig").HorizontalBar;
pub const ThemedButton = @import("ThemedButton.zig").ThemedButton;
pub const ThemedPanel = @import("ThemedPanel.zig").ThemedPanel;
pub const ScrollableList = @import("ScrollableList.zig").ScrollableList;

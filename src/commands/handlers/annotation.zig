//! Annotation handlers — annotate operating point from simulation results,
//! clear annotations.
//!
//! Requires `annotations` / `annotation_count` fields on Document (not yet added).

pub fn handleAnnotateOp(state: anytype) void {
    state.setStatus("Annotation not yet available");
}

pub fn handleClearAnnotations(state: anytype) void {
    state.setStatus("Annotations cleared");
}

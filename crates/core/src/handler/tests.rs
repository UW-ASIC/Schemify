use super::*;
use crate::schemify::*;

    use super::*;

    fn place_resistor(app: &mut App, x: i32, y: i32) {
        app.dispatch(Command::PlaceDevice {
            symbol_path: "resistor".into(),
            name: "R1".into(),
            x,
            y,
            rotation: 0,
            flip: false,
        });
    }

    #[test]
    fn verilog_a_block_netlists_as_osdi() {
        let mut app = App::new();
        app.dispatch(Command::PlaceDevice {
            symbol_path: "verilog_a_block".into(),
            name: "NVA1".into(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        for (key, value) in [("source_file", "models/my_diode.va"), ("model_name", "my_diode")] {
            app.dispatch(Command::SetInstanceProp {
                idx: 0,
                key: key.into(),
                value: value.into(),
            });
        }

        let ir = to_circuit_ir(app.schematic(), &app.state.interner, None);
        // .osdi load recorded once, with openvaf's sibling-output path;
        // the source travels alongside as a codegen hint.
        assert_eq!(ir.top.osdi_loads, vec!["models/my_diode.osdi".to_string()]);
        assert_eq!(ir.top.veriloga_sources, vec!["models/my_diode.va".to_string()]);
        // Auto model card binds the module.
        assert!(ir.top.models.iter().any(|m| m.name == "my_diode" && m.kind == "my_diode"));

        let sp = crate::sim::codegen::emit_spice(&ir);
        assert!(sp.contains(".osdi models/my_diode.osdi\n"), "spice was:\n{sp}");
        assert!(sp.contains(".model my_diode my_diode\n"), "spice was:\n{sp}");
        // N-card: prefix stripped from the instance name, not doubled.
        assert!(sp.contains("NVA1 ? ? my_diode\n"), "spice was:\n{sp}");

        // PySpice path compiles the source via veriloga() (openvaf,
        // mtime-cached) — no duplicate osdi() load for the same module.
        let py = crate::sim::codegen::emit_pyspice(&ir);
        assert!(py.contains(r#"ckt.veriloga("models/my_diode.va")"#), "pyspice was:\n{py}");
        assert!(!py.contains("osdi("), "pyspice was:\n{py}");
    }

    #[test]
    fn file_new_reuses_welcome_placeholder() {
        let mut app = App::new();
        assert_eq!(app.state.documents.len(), 1);
        assert!(app.state.view.show_welcome);

        // New from the welcome screen: still exactly one tab.
        app.dispatch(Command::FileNew);
        assert_eq!(app.state.documents.len(), 1);
        assert!(!app.state.view.show_welcome);

        // New again: now a real second tab.
        app.dispatch(Command::NewTab);
        assert_eq!(app.state.documents.len(), 2);
        assert_eq!(app.state.active_doc, 1);

        // Closing the second tab keeps the first open, no welcome.
        app.dispatch(Command::CloseTab(1));
        assert_eq!(app.state.documents.len(), 1);
        assert!(!app.state.view.show_welcome);

        // Closing the last tab returns to the welcome screen.
        app.dispatch(Command::CloseTab(0));
        assert_eq!(app.state.documents.len(), 1);
        assert!(app.state.view.show_welcome);
    }

    #[test]
    fn doc_kind_names_and_display() {
        assert_eq!(DocKind::split_name("inv.chn"), ("inv", DocKind::Schematic));
        assert_eq!(DocKind::split_name("res.chn_prim"), ("res", DocKind::Primitive));
        assert_eq!(DocKind::split_name("tb_foo.chn_tb"), ("tb_foo", DocKind::Testbench));
        assert_eq!(DocKind::split_name("plain"), ("plain", DocKind::Schematic));

        let doc = Document::default();
        assert_eq!(doc.display_name(), "untitled.chn");
    }

    #[test]
    fn save_defaults_extension_and_updates_doc() {
        let dir = std::env::temp_dir().join("schemify_save_test");
        let _ = std::fs::create_dir_all(&dir);

        let mut app = App::new();
        place_resistor(&mut app, 0, 0);

        // No extension: kind supplies `.chn`.
        app.save_to_path(&dir.join("amp")).unwrap();
        assert!(dir.join("amp.chn").is_file());
        let doc = app.state.active_document();
        assert_eq!(doc.name, "amp");
        assert_eq!(doc.kind, DocKind::Schematic);
        assert!(!doc.dirty);
        assert_eq!(doc.display_name(), "amp.chn");

        // Explicit `.chn_tb` round-trips name + kind.
        app.save_to_path(&dir.join("tb_amp.chn_tb")).unwrap();
        let doc = app.state.active_document();
        assert!(dir.join("tb_amp.chn_tb").is_file());
        assert_eq!(doc.name, "tb_amp");
        assert_eq!(doc.kind, DocKind::Testbench);
        assert_eq!(doc.display_name(), "tb_amp.chn_tb");

        // Saved content re-opens with the same instance count.
        let mut app2 = App::new();
        app2.open_file(&dir.join("amp.chn")).unwrap();
        assert_eq!(app2.state.documents.len(), 1); // reused placeholder
        assert_eq!(app2.schematic().instances.len(), 1);
        assert_eq!(app2.state.active_document().display_name(), "amp.chn");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn doc_vars_expand_to_live_values() {
        let mut app = App::new();
        place_resistor(&mut app, 0, 0);
        app.dispatch(Command::SetInstanceProp {
            idx: 0,
            key: "value".into(),
            value: "10k".into(),
        });

        let doc = "R1 is {{R1}} ({{R1.value}}); missing: {{R9}} {{R1.nope}} {{open";
        let out = expand_doc_vars(doc, app.schematic(), &app.state.interner);
        assert_eq!(out, "R1 is 10k (10k); missing: {{R9}} {{R1.nope}} {{open");

        // Schematic edit propagates on next expansion — no stale copies.
        app.dispatch(Command::SetInstanceProp {
            idx: 0,
            key: "value".into(),
            value: "22k".into(),
        });
        let out = expand_doc_vars("{{R1}}", app.schematic(), &app.state.interner);
        assert_eq!(out, "22k");
    }

    #[test]
    fn place_device_then_undo_restores_count() {
        let mut app = App::new();
        assert_eq!(app.schematic().instances.len(), 0);

        place_resistor(&mut app, 100, 200);
        assert_eq!(app.schematic().instances.len(), 1);
        assert_eq!(app.schematic().instances.x[0], 100);
        assert_eq!(app.schematic().instances.kind[0], DeviceKind::Resistor);

        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.len(), 0);

        app.dispatch(Command::Redo);
        assert_eq!(app.schematic().instances.len(), 1);
    }

    #[test]
    fn add_wires_connectivity_resolves_shared_net() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        app.dispatch(Command::AddWire {
            x0: 100,
            y0: 0,
            x1: 200,
            y1: 0,
        });

        let conn = app.connectivity();
        assert_eq!(conn.nets.len(), 1);
        assert_eq!(conn.point_to_net.get(&(0, 0)), Some(&0));
        assert_eq!(conn.point_to_net.get(&(200, 0)), Some(&0));
    }

    #[test]
    fn connectivity_cache_invalidated_by_generation() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        assert_eq!(app.connectivity().nets.len(), 1);

        // Disconnected second wire must show up after the mutation bumps
        // the generation past the cached one.
        app.dispatch(Command::AddWire {
            x0: 500,
            y0: 500,
            x1: 600,
            y1: 500,
        });
        assert_eq!(app.connectivity().nets.len(), 2);
    }

    #[test]
    fn t_junction_merges_nets() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 200,
            y1: 0,
        });
        app.dispatch(Command::AddWire {
            x0: 100,
            y0: -50,
            x1: 100,
            y1: 0,
        });
        assert_eq!(app.connectivity().nets.len(), 1);
    }

    #[test]
    fn nudge_coalescing_produces_single_undo_entry() {
        let mut app = App::new();
        place_resistor(&mut app, 0, 0);
        app.selection_mut().insert(ObjectRef::Instance(0));

        let before = app.active_doc().undo_history.len(); // snapshot from PlaceDevice
        app.dispatch(Command::NudgeRight);
        app.dispatch(Command::NudgeRight);
        app.dispatch(Command::NudgeDown);

        // All three nudges coalesce into one inverse MoveSelected entry.
        let doc = app.active_doc();
        assert_eq!(doc.undo_history.len(), before + 1);
        let snap_sz = app.state.tool.snap_size as i32;
        match doc.undo_history.back().unwrap() {
            UndoEntry::Inverse(Command::MoveSelected { dx, dy }) => {
                assert_eq!(*dx, -2 * snap_sz);
                assert_eq!(*dy, -snap_sz);
            }
            other => panic!("expected coalesced MoveSelected, got {other:?}"),
        }
        assert_eq!(app.schematic().instances.x[0], 2 * snap_sz);
        assert_eq!(app.schematic().instances.y[0], snap_sz);

        // One undo reverts the whole nudge run.
        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.x[0], 0);
        assert_eq!(app.schematic().instances.y[0], 0);
    }

    #[test]
    fn delete_selected_and_undo_snapshot() {
        let mut app = App::new();
        place_resistor(&mut app, 0, 0);
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        app.selection_mut().insert(ObjectRef::Instance(0));
        app.selection_mut().insert(ObjectRef::Wire(0));

        app.dispatch(Command::DeleteSelected);
        assert_eq!(app.schematic().instances.len(), 0);
        assert_eq!(app.schematic().wires.len(), 0);

        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.len(), 1);
        assert_eq!(app.schematic().wires.len(), 1);
    }

    #[test]
    fn selection_remove_deleted_shifts_indices() {
        let mut sel = Selection::default();
        sel.insert(ObjectRef::Wire(0));
        sel.insert(ObjectRef::Wire(2));
        sel.insert(ObjectRef::Instance(2));
        sel.remove_deleted(ObjectRef::Wire(1));
        assert!(sel.contains(ObjectRef::Wire(0)));
        assert!(sel.contains(ObjectRef::Wire(1))); // was Wire(2)
        assert!(sel.contains(ObjectRef::Instance(2))); // other kind untouched
    }

    #[test]
    fn spatial_index_cell_coords_and_query() {
        assert_eq!(cell_coord(0), 0);
        assert_eq!(cell_coord(199), 0);
        assert_eq!(cell_coord(200), 1);
        assert_eq!(cell_coord(-1), -1);
        assert_eq!(cell_coord(-200), -1);
        assert_eq!(cell_coord(-201), -2);

        let mut sch = Schematic::default();
        sch.wires.push(Wire {
            net_name: None,
            x0: 10,
            y0: 20,
            x1: 500,
            y1: 20,
            color: Color::NONE,
            thickness: 1,
        });
        let idx = SpatialIndex::rebuild(&sch);
        // Spans multiple cells but deduplicates to one hit.
        let hits = idx.query_rect(-100, -100, 600, 100);
        assert_eq!(hits, vec![ObjectRef::Wire(0)]);
        assert!(idx.query_rect(1000, 1000, 2000, 2000).is_empty());
    }

    #[test]
    fn label_pin_names_net() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        app.dispatch(Command::PlaceDevice {
            symbol_path: "lab_pin".into(),
            name: "VOUT".into(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        let conn = app.connectivity();
        assert_eq!(conn.nets.len(), 1);
        assert_eq!(conn.net_names[0], "VOUT");
    }

    #[test]
    fn rotate_and_flip_roundtrip_via_undo() {
        let mut app = App::new();
        place_resistor(&mut app, 40, 60);
        app.selection_mut().insert(ObjectRef::Instance(0));

        app.dispatch(Command::RotateCw);
        assert_eq!(app.schematic().instances.flags[0].rotation(), 1);
        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.flags[0].rotation(), 0);

        app.dispatch(Command::FlipHorizontal);
        assert!(app.schematic().instances.flags[0].flip());
        app.dispatch(Command::Undo);
        assert!(!app.schematic().instances.flags[0].flip());
    }

    #[test]
    fn stimulus_lang_dispatch() {
        let mut app = App::new();
        assert_eq!(app.schematic().stimulus_lang, StimulusLang::NgSpice);
        app.dispatch(Command::SetStimulusLang("xyce".into()));
        assert_eq!(app.schematic().stimulus_lang, StimulusLang::Xyce);
        app.dispatch(Command::SetStimulusLang("bogus".into()));
        assert_eq!(app.schematic().stimulus_lang, StimulusLang::Xyce);
    }

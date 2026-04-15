/* Enable POSIX extensions (popen/pclose) under -std=c11. */
#define _POSIX_C_SOURCE 200809L

/*
 * GitBlame — Schemify Plugin (ABI v6, C99)
 *
 * Shows git commit history for the active schematic file.
 * When a component is selected, narrows to commits that added or
 * removed that instance name (git log -S pickaxe search).
 *
 * Build:  zig build
 * Run:    zig build run   (installs to ~/.config/Schemify/ and launches host)
 */

#include "schemify_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ── Limits ──────────────────────────────────────────────────────────────── */

#define MAX_PATH    512
#define MAX_NAME    128
#define MAX_ENTRIES  32
#define MAX_AUTHOR   56
#define MAX_SUBJECT 120
#define CMD_BUF     900
#define RAW_BUF    8192

/* ── Commit record ───────────────────────────────────────────────────────── */

typedef struct {
    char hash[12];
    char author[MAX_AUTHOR];
    char date[12];
    char subject[MAX_SUBJECT];
} Commit;

/* ── Plugin state ────────────────────────────────────────────────────────── */

static char    g_file[MAX_PATH];      /* active .chn file path              */
static int     g_file_len;
static int32_t g_sel_idx  = -1;       /* selected instance index (-1=none)  */
static char    g_sel_name[MAX_NAME];  /* resolved instance name             */
static int     g_sel_name_len;

static Commit  g_commits[MAX_ENTRIES];
static int     g_commit_count;
static int     g_ready;               /* 0=pending, 1=done                  */
static int     g_is_git;              /* 1 = inside a git work-tree         */

/* ── Shell-escape helper (single-quote safe) ─────────────────────────────── */
/*
 * Rewrites src so it can be safely wrapped in '' in a shell command.
 * Every ' becomes '\'' (close quote, literal apostrophe, reopen quote).
 */
static int sh_escape(const char *src, char *dst, int cap) {
    int n = 0;
    while (*src && n + 5 < cap) {
        if (*src == '\'') {
            dst[n++] = '\'';
            dst[n++] = '\\';
            dst[n++] = '\'';
            dst[n++] = '\'';
        } else {
            dst[n++] = *src;
        }
        src++;
    }
    dst[n] = '\0';
    return n;
}

/* ── Compute dirname of path ─────────────────────────────────────────────── */

static void get_dir(const char *path, char *out, int cap) {
    int n = (int)strlen(path);
    if (n >= cap) n = cap - 1;
    memcpy(out, path, (size_t)n);
    out[n] = '\0';
    char *last = strrchr(out, '/');
    if (last && last > out) {
        *last = '\0';
    } else {
        out[0] = '.'; out[1] = '\0';
    }
}

/* ── Run shell command, return bytes written to buf ─────────────────────── */

static int run_cmd(const char *cmd, char *buf, int cap) {
    FILE *fp = popen(cmd, "r");
    if (!fp) return 0;
    int total = 0;
    int c;
    while (total < cap - 1 && (c = fgetc(fp)) != EOF)
        buf[total++] = (char)c;
    buf[total] = '\0';
    pclose(fp);
    return total;
}

/* ── Parse "hash|author|date|subject\n…" lines into g_commits ───────────── */

static void parse_log(const char *raw) {
    g_commit_count = 0;
    const char *p = raw;
    while (*p && g_commit_count < MAX_ENTRIES) {
        Commit *c = &g_commits[g_commit_count];
        int i;

        /* hash */
        i = 0;
        while (*p && *p != '|' && i < 11) c->hash[i++]    = *p++;
        c->hash[i] = '\0';
        if (*p == '|') p++;

        /* author */
        i = 0;
        while (*p && *p != '|' && i < MAX_AUTHOR - 1) c->author[i++] = *p++;
        c->author[i] = '\0';
        if (*p == '|') p++;

        /* date */
        i = 0;
        while (*p && *p != '|' && i < 11) c->date[i++]    = *p++;
        c->date[i] = '\0';
        if (*p == '|') p++;

        /* subject — until newline or end */
        i = 0;
        while (*p && *p != '\n' && i < MAX_SUBJECT - 1) c->subject[i++] = *p++;
        c->subject[i] = '\0';

        /* advance past newline */
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;

        if (c->hash[0]) g_commit_count++;
    }
}

/* ── Run git and populate g_commits ─────────────────────────────────────── */

static void run_blame(void) {
    g_ready        = 0;
    g_commit_count = 0;
    g_is_git       = 0;

    if (!g_file_len) { g_ready = 1; return; }

    char dir[MAX_PATH];
    get_dir(g_file, dir, MAX_PATH);

    char esc_dir[MAX_PATH * 2];
    char esc_file[MAX_PATH * 2];
    sh_escape(dir,    esc_dir,  (int)sizeof(esc_dir));
    sh_escape(g_file, esc_file, (int)sizeof(esc_file));

    /* Check that we are inside a git work-tree. */
    char check[CMD_BUF];
    char check_out[16];
    snprintf(check, sizeof(check),
        "git -C '%s' rev-parse --is-inside-work-tree 2>/dev/null",
        esc_dir);
    run_cmd(check, check_out, sizeof(check_out));
    if (strncmp(check_out, "true", 4) != 0) {
        g_ready = 1;
        return;
    }
    g_is_git = 1;

    char cmd[CMD_BUF];
    char raw[RAW_BUF];

    if (g_sel_name_len > 0) {
        /*
         * Pickaxe search: find commits where the instance name string was
         * introduced or removed.  This surfaces "who added R1" precisely.
         */
        char esc_name[MAX_NAME * 2];
        sh_escape(g_sel_name, esc_name, (int)sizeof(esc_name));
        snprintf(cmd, sizeof(cmd),
            "git -C '%s' log -S '%s' "
            "--pretty=format:'%%h|%%an|%%ad|%%s' --date=short "
            "-- '%s' 2>/dev/null",
            esc_dir, esc_name, esc_file);
    } else {
        /* Full file history. */
        snprintf(cmd, sizeof(cmd),
            "git -C '%s' log "
            "--pretty=format:'%%h|%%an|%%ad|%%s' --date=short "
            "-- '%s' 2>/dev/null",
            esc_dir, esc_file);
    }

    int len = run_cmd(cmd, raw, RAW_BUF);
    if (len > 0) parse_log(raw);
    g_ready = 1;
}

/* ── Draw panel ──────────────────────────────────────────────────────────── */

static void draw_panel(SpWriter *w) {
    char buf[220];

    /* Title */
    if (g_sel_name_len > 0) {
        snprintf(buf, sizeof(buf), "Git Blame: %s", g_sel_name);
        sp_write_ui_label(w, buf, strlen(buf), 1);
    } else {
        sp_write_ui_label(w,
            "Git Blame  (select a component for its history)", 47, 1);
    }
    sp_write_ui_separator(w, 2);

    /* No file open */
    if (!g_file_len) {
        sp_write_ui_label(w,
            "No file open — save the schematic first.", 42, 3);
        return;
    }

    /* Basename */
    const char *bn = strrchr(g_file, '/');
    bn = bn ? bn + 1 : g_file;
    snprintf(buf, sizeof(buf), "File: %s", bn);
    sp_write_ui_label(w, buf, strlen(buf), 4);
    sp_write_ui_separator(w, 5);

    /* Still loading */
    if (!g_ready) {
        sp_write_ui_label(w, "Loading…", 10, 6);
        return;
    }

    /* Not a git repo */
    if (!g_is_git) {
        sp_write_ui_label(w, "Not inside a git repository.", 28, 6);
        sp_write_ui_button(w, "Retry", 5, 10);
        return;
    }

    /* Header row: commit count + refresh */
    sp_write_ui_begin_row(w, 7);
    snprintf(buf, sizeof(buf), "%d commit%s",
             g_commit_count, g_commit_count == 1 ? "" : "s");
    sp_write_ui_label(w, buf, strlen(buf), 8);
    sp_write_ui_button(w, "Refresh", 7, 10);
    sp_write_ui_end_row(w, 7);
    sp_write_ui_separator(w, 9);

    /* Empty result */
    if (g_commit_count == 0) {
        if (g_sel_name_len > 0)
            snprintf(buf, sizeof(buf),
                "No commits found touching \"%s\".", g_sel_name);
        else
            snprintf(buf, sizeof(buf),
                "No commits found for this file.");
        sp_write_ui_label(w, buf, strlen(buf), 11);
        return;
    }

    /* Commit list — one collapsible section per entry */
    for (int i = 0; i < g_commit_count; i++) {
        Commit *c = &g_commits[i];

        /* Header line: hash  date  author */
        snprintf(buf, sizeof(buf), "%.11s  %.11s  %.55s",
                 c->hash, c->date, c->author);
        sp_write_ui_collapsible_start(w, buf, strlen(buf),
                                      i == 0 ? 1 : 0,
                                      (uint32_t)(100 + i));

        /* Commit subject, indented */
        snprintf(buf, sizeof(buf), "  %.119s", c->subject);
        sp_write_ui_label(w, buf, strlen(buf), (uint32_t)(200 + i));

        sp_write_ui_collapsible_end(w, (uint32_t)(100 + i));
    }
}

/* ── Process ─────────────────────────────────────────────────────────────── */

static size_t gitblame_process(
    const uint8_t *in_ptr, size_t in_len,
    uint8_t       *out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg    msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {

        /* ── Lifecycle ─────────────────────────────────────────────────── */

        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "gitblame", 8,
                "Git Blame", 9,
                "gb", 2,
                SP_LAYOUT_RIGHT_SIDEBAR, 0);
            sp_write_set_status(&w, "GitBlame ready", 14);
            /* Ask for the active file path immediately. */
            sp_write_get_state(&w, "active_file", 11);
            break;

        case SP_TAG_SCHEMATIC_CHANGED:
            /* Re-fetch the file path; schematic may have been saved/switched. */
            g_ready = 0;
            sp_write_get_state(&w, "active_file", 11);
            sp_write_request_refresh(&w);
            break;

        /* ── State responses ───────────────────────────────────────────── */

        case SP_TAG_STATE_RESPONSE: {
            char key[32];
            sp_str_cstr(msg.u.state_response.key, key, sizeof(key));
            if (strcmp(key, "active_file") == 0) {
                sp_str_cstr(msg.u.state_response.val, g_file, MAX_PATH);
                g_file_len = (int)strlen(g_file);
                /* Re-run blame for the new file. */
                run_blame();
                sp_write_request_refresh(&w);
            }
            break;
        }

        /* ── Selection ─────────────────────────────────────────────────── */

        case SP_TAG_SELECTION_CHANGED: {
            int32_t idx = msg.u.selection_changed.instance_idx;
            if (idx < 0) {
                /* User clicked empty canvas — show full file history. */
                g_sel_idx      = -1;
                g_sel_name[0]  = '\0';
                g_sel_name_len = 0;
                run_blame();
                sp_write_request_refresh(&w);
            } else {
                g_sel_idx = idx;
                g_ready   = 0;
                /* Query all instances so we can resolve the name. */
                sp_write_query_instances(&w);
                sp_write_request_refresh(&w);
            }
            break;
        }

        /* ── Instance data (reply to query_instances) ──────────────────── */

        case SP_TAG_INSTANCE_DATA: {
            uint32_t idx = msg.u.instance_data.idx;
            if (g_sel_idx >= 0 && (int32_t)idx == g_sel_idx) {
                sp_str_cstr(msg.u.instance_data.name,
                            g_sel_name, MAX_NAME);
                g_sel_name_len = (int)strlen(g_sel_name);
                run_blame();
                sp_write_request_refresh(&w);
            }
            break;
        }

        /* ── Rendering ─────────────────────────────────────────────────── */

        case SP_TAG_DRAW_PANEL:
            draw_panel(&w);
            break;

        /* ── Buttons ───────────────────────────────────────────────────── */

        case SP_TAG_BUTTON_CLICKED:
            if (msg.u.button_clicked.widget_id == 10) {
                /* Refresh — re-query file path and re-run git. */
                sp_write_get_state(&w, "active_file", 11);
            }
            break;

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("git-blame", "0.1.0", gitblame_process)

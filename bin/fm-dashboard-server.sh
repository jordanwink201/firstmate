#!/usr/bin/env bash
# fm-dashboard-server.sh - private localhost fleet dashboard for Mockup A v1.
#
# Serves a read-only dashboard backed by fm-dashboard-probe.sh. The server binds
# to 127.0.0.1 by default, accepts only GET requests, and exposes:
#   /api/snapshot  cached JSON from a background fm-dashboard-probe.sh --json loop
#   /api/report    on-demand text report from fm-dashboard-probe.sh --report
#   /healthz       tiny JSON health check
#
# /api/snapshot is the sole data source the dashboard UI polls. The detail
# panel renders the selected task's main pipeline rail from the snapshot's
# per-task "pipeline" object (with a client-side fallback when a row lacks
# one) and shows the no-mistakes validation sub-rail only for the
# cad_no_mistakes profile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST=127.0.0.1
PORT=8765

usage() {
  cat <<'EOF'
usage: fm-dashboard-server.sh [--host 127.0.0.1] [--port 8765]

Start the private read-only Firstmate fleet dashboard.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || { printf 'fm-dashboard-server.sh: --host needs a value\n' >&2; exit 2; }
      HOST=$2
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || { printf 'fm-dashboard-server.sh: --port needs a value\n' >&2; exit 2; }
      PORT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'fm-dashboard-server.sh: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PORT" in
  ""|*[!0-9]*)
    printf 'fm-dashboard-server.sh: --port must be a non-negative integer\n' >&2
    exit 2
    ;;
esac

[ -n "$HOST" ] || { printf 'fm-dashboard-server.sh: --host must not be empty\n' >&2; exit 2; }
command -v node >/dev/null 2>&1 || { printf 'fm-dashboard-server.sh: node not found\n' >&2; exit 127; }

FM_DASHBOARD_PROBE_BIN="${FM_DASHBOARD_PROBE_BIN:-$SCRIPT_DIR/fm-dashboard-probe.sh}"
[ -x "$FM_DASHBOARD_PROBE_BIN" ] || {
  printf 'fm-dashboard-server.sh: probe is not executable: %s\n' "$FM_DASHBOARD_PROBE_BIN" >&2
  exit 1
}

export FM_DASHBOARD_HOST="$HOST"
export FM_DASHBOARD_PORT="$PORT"
export FM_DASHBOARD_PROBE_BIN

exec node <<'NODE'
'use strict';

const http = require('node:http');
const { spawn } = require('node:child_process');

const host = process.env.FM_DASHBOARD_HOST || '127.0.0.1';
const port = Number(process.env.FM_DASHBOARD_PORT || '8765');
const probeBin = process.env.FM_DASHBOARD_PROBE_BIN;
const probeTimeoutMsRaw = Number(process.env.FM_DASHBOARD_PROBE_TIMEOUT_MS || '20000');
const probeTimeoutMs = Number.isFinite(probeTimeoutMsRaw) && probeTimeoutMsRaw > 0 ? probeTimeoutMsRaw : 20000;
const refreshMsRaw = Number(process.env.FM_DASHBOARD_REFRESH_MS || '10000');
const refreshMs = Number.isFinite(refreshMsRaw) && refreshMsRaw > 0 ? refreshMsRaw : 10000;
const maxOutputBytesRaw = Number(process.env.FM_DASHBOARD_PROBE_MAX_OUTPUT_BYTES || String(4 * 1024 * 1024));
const maxOutputBytes = Number.isFinite(maxOutputBytesRaw) && maxOutputBytesRaw > 0 ? maxOutputBytesRaw : 4 * 1024 * 1024;

const cache = {
  snapshot: null,
  report: null,
};
const inFlight = {
  report: null,
};
const snapshotRefresh = {
  inFlight: null,
  timer: null,
  lastError: null,
};

const html = String.raw`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Firstmate Fleet Dashboard</title>
  <style>
    :root {
      --bg: #f7f8fa;
      --paper: #ffffff;
      --paper-muted: #f3f5f7;
      --ink: #18212a;
      --muted: #667085;
      --line: #d9dee7;
      --line-soft: #e8ebf0;
      --teal: #0f766e;
      --blue: #2563eb;
      --amber: #b76e00;
      --red: #b42318;
      --green: #20744a;
      --gray: #6b7280;
      --shadow: 0 1px 2px rgba(24, 33, 42, 0.06), 0 8px 24px rgba(24, 33, 42, 0.06);
    }
    * {
      box-sizing: border-box;
      letter-spacing: 0;
    }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--ink);
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 14px;
    }
    button {
      font: inherit;
    }
    .shell {
      width: min(1500px, 100%);
      margin: 0 auto;
      padding: 18px 20px;
      display: grid;
      grid-template-rows: auto auto minmax(0, 1fr);
      gap: 12px;
    }
    .topbar {
      display: grid;
      grid-template-columns: minmax(220px, 1fr) auto;
      align-items: end;
      gap: 16px;
      border-bottom: 1px solid var(--line);
      padding-bottom: 12px;
    }
    h1 {
      margin: 0;
      font-size: clamp(24px, 2.2vw, 34px);
      line-height: 1.08;
      font-weight: 720;
    }
    .meta {
      display: flex;
      gap: 10px;
      align-items: center;
      justify-content: flex-end;
      flex-wrap: wrap;
      color: var(--muted);
      font-size: 12px;
      min-height: 30px;
    }
    .pill {
      border: 1px solid var(--line);
      background: var(--paper);
      color: var(--ink);
      border-radius: 999px;
      padding: 5px 10px;
      white-space: nowrap;
    }
    .pill[data-tone="ok"] { border-color: rgba(32, 116, 74, 0.3); color: var(--green); }
    .pill[data-tone="warn"] { border-color: rgba(183, 110, 0, 0.32); color: var(--amber); }
    .pill[data-tone="bad"] { border-color: rgba(180, 35, 24, 0.32); color: var(--red); }
    .banner {
      display: none;
      border: 1px solid var(--line);
      background: var(--paper);
      box-shadow: var(--shadow);
      border-radius: 6px;
      padding: 10px 12px;
      color: var(--ink);
      min-height: 44px;
      align-items: center;
      gap: 10px;
    }
    .banner.show {
      display: flex;
    }
    .banner strong {
      color: var(--red);
    }
    .selected-pipeline {
      border: 1px solid var(--line);
      background: var(--paper);
      border-radius: 6px;
      padding: 12px 12px 10px;
      display: grid;
      gap: 10px;
      min-width: 0;
      box-shadow: var(--shadow);
      overflow-x: auto;
    }
    .selected-pipeline-head {
      display: flex;
      justify-content: space-between;
      gap: 14px;
      align-items: start;
      flex-wrap: wrap;
      min-width: 0;
    }
    .selected-pipeline-title {
      display: grid;
      gap: 3px;
      min-width: min(280px, 100%);
    }
    .selected-pipeline-title strong {
      font-size: 17px;
      line-height: 1.2;
      font-weight: 700;
      overflow-wrap: anywhere;
    }
    .selected-pipeline-title span {
      color: var(--muted);
      font-size: 12px;
      font-weight: 600;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .selected-pipeline-next {
      display: grid;
      gap: 3px;
      min-width: min(360px, 100%);
      max-width: 520px;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.3;
    }
    .selected-pipeline-next strong {
      color: var(--ink);
      font-size: 12px;
      text-transform: uppercase;
      font-weight: 700;
    }
    .ship-tab {
      min-height: 88px;
      text-align: left;
      border: 1px solid var(--line);
      background: var(--paper);
      border-radius: 6px;
      padding: 10px;
      color: var(--ink);
      cursor: pointer;
      display: grid;
      gap: 6px;
      box-shadow: 0 1px 2px rgba(24, 33, 42, 0.05);
    }
    .ship-tab[data-attention="needs_action"],
    .ship-card[data-attention="needs_action"] {
      border-color: rgba(180, 35, 24, 0.34);
      background: #fff7f6;
    }
    .ship-tab[aria-selected="true"] {
      outline: 2px solid var(--teal);
      outline-offset: 1px;
    }
    .ship-title {
      overflow: hidden;
      font-weight: 650;
      min-width: 0;
      line-height: 1.25;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
    }
    .ship-sub {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: var(--muted);
      font-size: 12px;
      min-width: 0;
    }
    .task-id {
      color: var(--muted);
      font-size: 11px;
      font-weight: 600;
      line-height: 1.2;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .chip-row {
      display: flex;
      gap: 6px;
      align-items: center;
      flex-wrap: wrap;
      min-width: 0;
    }
    .station-chip {
      width: fit-content;
      max-width: 100%;
      border-radius: 999px;
      padding: 3px 8px;
      color: #fff;
      font-size: 11px;
      line-height: 1.25;
      font-weight: 650;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .station-chip[data-station="casting_off"] { background: var(--blue); }
    .station-chip[data-station="underway"] { background: var(--teal); }
    .station-chip[data-station="gate_run"] { background: var(--amber); }
    .station-chip[data-station="needs_captain"] { background: var(--red); }
    .station-chip[data-station="at_port"] { background: var(--green); }
    .station-chip[data-station="arrived_today"] { background: var(--green); }
    .station-chip[data-station="done_earlier"] { background: var(--gray); }
    .station-chip[data-station="needs_reconciliation"] { background: var(--amber); }
    .station-chip[data-station="unknown"] { background: var(--gray); }
    .attention-badge {
      width: fit-content;
      max-width: 100%;
      border-radius: 999px;
      padding: 3px 8px;
      font-size: 11px;
      line-height: 1.25;
      border: 1px solid rgba(180, 35, 24, 0.28);
      color: var(--red);
      background: rgba(180, 35, 24, 0.07);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .main {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(300px, 390px);
      gap: 12px;
      min-height: 560px;
    }
    .map {
      position: relative;
      min-width: 0;
      border: 1px solid var(--line);
      border-radius: 6px;
      background:
        linear-gradient(90deg, rgba(24, 33, 42, 0.055) 1px, transparent 1px),
        linear-gradient(180deg, rgba(24, 33, 42, 0.05) 1px, transparent 1px),
        var(--paper);
      background-size: 80px 80px;
      overflow: hidden;
      box-shadow: 0 1px 2px rgba(24, 33, 42, 0.05);
    }
    .lanes {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 0;
      height: 100%;
      min-height: 560px;
    }
    .lane {
      position: relative;
      min-width: 0;
      padding: 12px 10px;
      border-right: 1px solid rgba(217, 222, 231, 0.78);
      display: grid;
      grid-template-rows: auto 1fr;
      gap: 12px;
    }
    .lane:last-child {
      border-right: 0;
    }
    .lane-title {
      display: grid;
      gap: 3px;
      min-height: 52px;
    }
    .lane-title strong {
      font-size: 11px;
      text-transform: uppercase;
      color: var(--muted);
      font-weight: 700;
    }
    .lane-title span {
      font-size: 26px;
      font-weight: 720;
      line-height: 1;
    }
    .lane-ships {
      display: grid;
      align-content: start;
      gap: 8px;
      min-width: 0;
    }
    .ship-card {
      text-align: left;
      border: 1px solid var(--line);
      border-left: 3px solid var(--gray);
      background: rgba(255, 255, 255, 0.94);
      border-radius: 6px;
      padding: 9px 11px;
      min-height: 68px;
      display: grid;
      gap: 6px;
      align-content: start;
      cursor: pointer;
      box-shadow: 0 1px 2px rgba(24, 33, 42, 0.05);
      transition: border-color 120ms ease, box-shadow 120ms ease, background-color 120ms ease;
    }
    .ship-card[data-station="casting_off"] { border-left-color: var(--blue); }
    .ship-card[data-station="underway"] { border-left-color: var(--teal); }
    .ship-card[data-station="gate_run"] { border-left-color: var(--amber); }
    .ship-card[data-station="needs_captain"] { border-left-color: var(--red); }
    .ship-card[data-station="at_port"] { border-left-color: var(--green); }
    .ship-card[data-station="arrived_today"] { border-left-color: var(--green); }
    .ship-card[data-station="done_earlier"] { border-left-color: var(--gray); }
    .ship-card[data-station="needs_reconciliation"] { border-left-color: var(--amber); }
    .ship-card[data-station="unknown"] { border-left-color: var(--gray); }
    .ship-card[aria-selected="true"] {
      outline: 2px solid rgba(15, 118, 110, 0.78);
      outline-offset: 1px;
    }
    .ship-card:hover {
      border-color: #c7ced8;
      box-shadow: 0 2px 8px rgba(24, 33, 42, 0.08);
    }
    .ship-card .line {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 8px;
      min-width: 0;
    }
    .ship-card .line span {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .ship-card .line em {
      flex: 0 0 auto;
      color: var(--muted);
      font-style: normal;
      font-size: 12px;
    }
    .card-meta {
      display: flex;
      gap: 6px;
      align-items: center;
      flex-wrap: wrap;
      min-width: 0;
    }
    .done-chip {
      width: fit-content;
      max-width: 100%;
      border-radius: 999px;
      padding: 3px 7px;
      font-size: 11px;
      line-height: 1.25;
      color: var(--green);
      border: 1px solid rgba(32, 116, 74, 0.22);
      background: rgba(32, 116, 74, 0.07);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .empty-lane {
      min-height: 84px;
      border: 1px dashed rgba(102, 112, 133, 0.34);
      border-radius: 6px;
      display: grid;
      place-items: center;
      color: var(--muted);
      font-size: 12px;
      padding: 12px;
      text-align: center;
    }
    .overlay-state {
      position: absolute;
      inset: 0;
      display: none;
      place-items: center;
      background: rgba(247, 248, 250, 0.82);
      padding: 24px;
      text-align: center;
      color: var(--muted);
      z-index: 2;
    }
    .overlay-state.show {
      display: grid;
    }
    .overlay-state strong {
      display: block;
      color: var(--ink);
      font-size: 20px;
      margin-bottom: 6px;
    }
    .detail {
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--paper);
      box-shadow: var(--shadow);
      min-width: 0;
      display: grid;
      grid-template-rows: auto 1fr;
    }
    .detail-head {
      padding: 16px;
      border-bottom: 1px solid var(--line);
      display: grid;
      gap: 10px;
      min-width: 0;
    }
    .detail h2 {
      margin: 0;
      font-size: 22px;
      line-height: 1.16;
      font-weight: 720;
      overflow-wrap: anywhere;
    }
    .detail-meta {
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      min-width: 0;
    }
    .detail-body {
      padding: 16px;
      display: grid;
      align-content: start;
      gap: 16px;
      min-width: 0;
    }
    .detail-summary {
      display: grid;
      gap: 10px;
      border-bottom: 1px solid var(--line-soft);
      padding-bottom: 14px;
    }
    .detail-status {
      display: grid;
      gap: 6px;
      padding: 11px;
      border-radius: 6px;
      background: rgba(15, 118, 110, 0.06);
      border: 1px solid rgba(15, 118, 110, 0.16);
    }
    .detail-status[data-tone="needs_action"] {
      background: rgba(180, 35, 24, 0.06);
      border-color: rgba(180, 35, 24, 0.18);
    }
    .detail-status[data-tone="landed"] {
      background: rgba(32, 116, 74, 0.06);
      border-color: rgba(32, 116, 74, 0.18);
    }
    .detail-status strong {
      font-size: 13px;
      text-transform: uppercase;
      color: var(--muted);
      font-weight: 700;
    }
    .detail-status span {
      overflow-wrap: anywhere;
      line-height: 1.35;
    }
    .detail-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
    }
    .action-link {
      display: inline-flex;
      min-height: 32px;
      align-items: center;
      border-radius: 6px;
      padding: 6px 10px;
      border: 1px solid rgba(37, 99, 235, 0.25);
      background: rgba(37, 99, 235, 0.06);
      color: var(--blue);
      font-weight: 700;
      text-decoration: none;
    }
    .action-link:hover {
      text-decoration: underline;
    }
    .detail-section {
      display: grid;
      gap: 10px;
      min-width: 0;
    }
    .pipeline-section {
      border-bottom: 1px solid var(--line-soft);
      padding-bottom: 14px;
    }
    .pipeline-rail,
    .validation-rail {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(72px, 1fr));
      min-width: 0;
      padding: 8px 0 4px;
    }
    .selected-pipeline .pipeline-rail {
      grid-template-columns: repeat(9, minmax(96px, 1fr));
      min-width: 860px;
      padding: 12px 0 6px;
    }
    .rail-step {
      position: relative;
      min-height: 68px;
      border: 0;
      border-radius: 0;
      padding: 0 8px;
      display: grid;
      grid-template-rows: 24px auto auto;
      justify-items: center;
      align-content: start;
      gap: 4px;
      background: transparent;
      color: var(--muted);
      overflow: visible;
      text-align: center;
    }
    .rail-step::before {
      content: "";
      position: absolute;
      top: 10px;
      left: 0;
      right: 0;
      height: 4px;
      background: rgba(102, 112, 133, 0.24);
      z-index: 0;
    }
    .rail-step:first-child::before {
      left: 50%;
    }
    .rail-step:last-child::before {
      right: 50%;
    }
    .rail-dot {
      width: 20px;
      height: 20px;
      border-radius: 999px;
      border: 3px solid rgba(102, 112, 133, 0.42);
      background: var(--paper);
      box-shadow: 0 0 0 4px var(--paper);
      position: relative;
      z-index: 1;
    }
    .rail-step[data-state="done"] {
      color: var(--green);
    }
    .rail-step[data-state="done"]::before {
      background: rgba(32, 116, 74, 0.45);
    }
    .rail-step[data-state="done"] .rail-dot {
      border-color: var(--green);
      background: var(--green);
    }
    .rail-step[data-state="active"] {
      color: var(--ink);
    }
    .rail-step[data-state="active"]::before {
      background: linear-gradient(90deg, rgba(32, 116, 74, 0.45) 0 50%, rgba(102, 112, 133, 0.24) 50% 100%);
    }
    .rail-step[data-state="active"] .rail-dot {
      border-color: var(--teal);
      background: var(--teal);
      box-shadow: 0 0 0 4px var(--paper), 0 0 0 7px rgba(15, 118, 110, 0.13);
    }
    .rail-step[data-state="unknown"] {
      color: var(--red);
    }
    .rail-step[data-state="unknown"]::before {
      background: rgba(183, 110, 0, 0.32);
    }
    .rail-step[data-state="unknown"] .rail-dot {
      border-color: var(--amber);
      background: var(--paper);
    }
    .rail-step strong,
    .rail-step span {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .rail-step strong {
      font-size: 11px;
      text-transform: uppercase;
    }
    .rail-step span {
      font-size: 12px;
      color: inherit;
    }
    .rail-caption {
      min-height: 15px;
    }
    .pipeline-note {
      border: 1px dashed rgba(102, 112, 133, 0.34);
      border-radius: 6px;
      padding: 10px;
      color: var(--muted);
      overflow-wrap: anywhere;
    }
    .detail-section-title,
    .detail-section summary {
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }
    .detail-section summary {
      cursor: pointer;
      list-style-position: inside;
    }
    .detail-facts {
      display: grid;
      gap: 8px;
      min-width: 0;
    }
    .kv {
      display: grid;
      grid-template-columns: 112px minmax(0, 1fr);
      gap: 8px;
      padding-bottom: 10px;
      border-bottom: 1px solid var(--line-soft);
    }
    .kv.compact {
      grid-template-columns: 92px minmax(0, 1fr);
      padding-bottom: 8px;
    }
    .kv dt {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
    }
    .kv dd {
      margin: 0;
      min-width: 0;
      overflow-wrap: anywhere;
    }
    .kv dd[data-muted="true"] {
      color: var(--muted);
    }
    .detail-link {
      color: var(--blue);
      font-weight: 700;
      text-decoration: none;
    }
    .detail-link:hover {
      text-decoration: underline;
    }
    .detail-empty {
      padding: 18px;
      color: var(--muted);
    }
    @media (max-width: 1100px) {
      .main {
        grid-template-columns: 1fr;
      }
      .detail {
        min-height: 360px;
      }
      .lanes {
        overflow-x: auto;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      }
    }
    @media (max-width: 720px) {
      .shell {
        padding: 12px;
      }
      .topbar {
        grid-template-columns: 1fr;
        align-items: start;
      }
      .meta {
        justify-content: flex-start;
      }
      .kv {
        grid-template-columns: 1fr;
      }
      .lanes {
        min-height: 520px;
      }
    }
  </style>
</head>
<body>
  <div class="shell">
    <header class="topbar">
      <h1>Firstmate Fleet</h1>
      <div class="meta" id="meta">
        <span class="pill" data-tone="warn">Loading</span>
      </div>
    </header>
    <div class="banner" id="banner"></div>
    <section class="selected-pipeline" id="fleetStrip" aria-label="Selected task pipeline"></section>
    <main class="main">
      <section class="map" aria-label="Voyage map">
        <div class="lanes" id="lanes"></div>
        <div class="overlay-state show" id="overlay">
          <div><strong>Loading fleet</strong><span>Waiting for the first probe.</span></div>
        </div>
      </section>
      <aside class="detail" id="detail" aria-label="Selected ship"></aside>
    </main>
  </div>
  <script>
    var stationDefs = [
      { id: 'casting_off', label: 'Casting Off' },
      { id: 'underway', label: 'Underway' },
      { id: 'gate_run', label: 'Gate Run' },
      { id: 'needs_captain', label: 'Needs Captain' },
      { id: 'arrived_today', label: 'Arrived Today' },
      { id: 'done_earlier', label: 'Done Earlier' },
      { id: 'needs_reconciliation', label: 'Needs Reconciliation' },
      { id: 'unknown', label: 'Unknown' }
    ];
    var pipelineStages = [
      { id: 'intake', label: 'Intake' },
      { id: 'mirror', label: 'Mirror' },
      { id: 'spawn', label: 'Spawn' },
      { id: 'run_work', label: 'Run Work' },
      { id: 'validation_gate', label: 'Validation' },
      { id: 'review_ready', label: 'Review' },
      { id: 'landed', label: 'Landed' },
      { id: 'human_followthrough', label: 'Followthrough' },
      { id: 'unknown', label: 'Unknown' }
    ];
    var validationStages = [
      { id: 'intent', label: 'Intent' },
      { id: 'review', label: 'Review' },
      { id: 'push', label: 'Push' },
      { id: 'ci', label: 'CI' }
    ];
    var selectPriority = ['needs_captain', 'needs_reconciliation', 'gate_run', 'underway', 'casting_off', 'unknown', 'arrived_today', 'done_earlier'];
    var state = {
      snapshot: null,
      selectedId: null,
      loading: true,
      error: '',
      stale: false,
      lastGoodAt: 0,
      requesting: false,
      serverRefreshing: false
    };

    function escapeHtml(value) {
      return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    function normalizeStation(station) {
      return station === 'at_port' ? 'arrived_today' : (station || 'unknown');
    }

    function stationOf(taskId) {
      var rows = (state.snapshot && state.snapshot.stations) || [];
      for (var i = 0; i < rows.length; i += 1) {
        if (rows[i].task_id === taskId) return normalizeStation(rows[i].station);
      }
      return 'unknown';
    }

    function stationReason(taskId) {
      var rows = (state.snapshot && state.snapshot.stations) || [];
      for (var i = 0; i < rows.length; i += 1) {
        if (rows[i].task_id === taskId) return rows[i].reason || '';
      }
      return '';
    }

    function stationLabel(station) {
      station = normalizeStation(station);
      if (station === 'arrived_today') return 'Arrived Today';
      if (station === 'done_earlier') return 'Done Earlier';
      if (station === 'needs_reconciliation') return 'Needs Reconciliation';
      return String(station || 'unknown').replace(/_/g, ' ');
    }

    function isDoneStation(station) {
      return station === 'arrived_today' || station === 'done_earlier';
    }

    function displayTitle(ship) {
      return (ship && (ship.display_title || ship.task_id)) || 'Untitled task';
    }

    function stationCounts() {
      var counts = {};
      stationDefs.forEach(function(def) { counts[def.id] = 0; });
      ((state.snapshot && state.snapshot.fleet) || []).forEach(function(ship) {
        var station = stationOf(ship.task_id);
        counts[station] = (counts[station] || 0) + 1;
      });
      return counts;
    }

    function formatDoneDate(value) {
      var match = String(value || '').match(/^(\d{4})-(\d{2})-(\d{2})$/);
      if (!match) return value || '';
      var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      var month = months[Math.max(0, Math.min(11, Number(match[2]) - 1))];
      return month + ' ' + String(Number(match[3]));
    }

    function cardTaskIdHtml(ship) {
      var title = displayTitle(ship);
      var taskId = ship && ship.task_id ? String(ship.task_id) : '';
      if (!taskId || taskId === title) return '';
      return '<span class="task-id">' + escapeHtml(taskId) + '</span>';
    }

    function doneChipHtml(ship) {
      if (!ship) return '';
      var station = stationOf(ship.task_id);
      if (!isDoneStation(station)) return '';
      var timeline = ship.timeline || {};
      var label = timeline.done_date ? 'Done ' + formatDoneDate(timeline.done_date) : (station === 'arrived_today' ? 'Done today' : 'Done earlier');
      return '<span class="done-chip">' + escapeHtml(label) + '</span>';
    }

    function doneTimelineText(ship) {
      if (!ship || !ship.timeline || !ship.timeline.done_date) return '';
      var source = ship.timeline.source && ship.timeline.source !== 'none' ? ' via ' + ship.timeline.source : '';
      return 'Done ' + formatDoneDate(ship.timeline.done_date) + source;
    }

    function laneCardMetaHtml(ship) {
      var pieces = [cardTaskIdHtml(ship), doneChipHtml(ship)].filter(Boolean);
      if (!pieces.length) return '';
      return '<span class="card-meta">' + pieces.join('') + '</span>';
    }

    function supervisionLagging() {
      var supervision = (state.snapshot && state.snapshot.supervision) || {};
      var watcher = supervision.watcher || {};
      var queue = supervision.wake_queue || {};
      return watcher.stale === true || Number(queue.pending || 0) > 0;
    }

    function attentionBadge(ship) {
      if (!ship || ship.attention !== 'needs_action') return '';
      return '<span class="attention-badge">Needs action</span>';
    }

    function taskById(taskId) {
      var fleet = (state.snapshot && state.snapshot.fleet) || [];
      for (var i = 0; i < fleet.length; i += 1) {
        if (fleet[i].task_id === taskId) return fleet[i];
      }
      return null;
    }

    function defaultSelection() {
      var fleet = (state.snapshot && state.snapshot.fleet) || [];
      for (var p = 0; p < selectPriority.length; p += 1) {
        for (var i = 0; i < fleet.length; i += 1) {
          if (stationOf(fleet[i].task_id) === selectPriority[p]) return fleet[i].task_id;
        }
      }
      return fleet[0] ? fleet[0].task_id : null;
    }

    function groupFleet() {
      var groups = {};
      stationDefs.forEach(function(def) { groups[def.id] = []; });
      ((state.snapshot && state.snapshot.fleet) || []).forEach(function(ship) {
        var station = stationOf(ship.task_id);
        if (!groups[station]) groups.unknown.push(ship);
        else groups[station].push(ship);
      });
      return groups;
    }

    function shortPath(value) {
      if (!value) return '';
      var parts = String(value).split('/');
      return parts.slice(Math.max(0, parts.length - 2)).join('/');
    }

    function latestNote(ship) {
      if (!ship || !ship.latest_status) return '';
      var verb = ship.latest_status.verb || '';
      var note = ship.latest_status.note || '';
      if (verb && note) return verb + ': ' + note;
      return note || verb;
    }

    function humanUpdate(ship, station) {
      var text = latestNote(ship) || '';
      text = text.replace(/^(done|working|blocked|failed|needs-decision):\s*/i, '');
      text = text.replace(/\s+on\s+[\w./-]+\s+\(commit\s+[a-f0-9]{7,40}\)\.?$/i, '');
      text = text.replace(/\s+\(commit\s+[a-f0-9]{7,40}\)/ig, '');
      text = text.replace(/\bworktree isolation\b/ig, 'setup checks');
      text = text.replace(/\breading required skill instructions\b/ig, 'reading instructions');
      if (!text && station === 'arrived_today') return 'Finished and archived for today.';
      if (!text && station === 'done_earlier') return 'Finished before today.';
      if (!text && station === 'needs_reconciliation') return 'State needs reconciliation.';
      if (!text && station === 'underway') return 'Work is in progress.';
      if (!text && station === 'gate_run') return 'Validation is running.';
      return text || stationLabel(station);
    }

    function currentStateText(ship) {
      if (!ship || !ship.current_state) return '';
      return [ship.current_state.state, ship.current_state.source].filter(Boolean).join(' / ');
    }

    function nextStepText(ship, station) {
      if (station === 'needs_reconciliation') return 'Reconcile task state.';
      if (ship && ship.attention === 'needs_action') return 'Review the latest update.';
      if (station === 'needs_captain') return 'Review the latest update.';
      if (station === 'arrived_today') return 'No action. Kept here until tomorrow.';
      if (station === 'done_earlier') return 'No action. Earlier completion retained for context.';
      if (station === 'gate_run') return 'Wait for validation to finish.';
      if (station === 'underway') return 'Wait for the next progress update.';
      if (station === 'casting_off') return 'Starting up.';
      return 'Monitor only.';
    }

    function titleize(value) {
      return String(value || 'unknown')
        .replace(/_/g, ' ')
        .replace(/\b\w/g, function(letter) { return letter.toUpperCase(); });
    }

    function fallbackProfile(ship) {
      if (!ship) return 'unknown';
      if (ship.kind === 'secondmate' || ship.mode === 'secondmate') return 'secondmate';
      if (ship.kind === 'scout') return 'scout_report';
      if (ship.mode === 'no-mistakes') return 'cad_no_mistakes';
      if (ship.mode === 'direct-PR') return 'direct_pr';
      if (ship.mode === 'local-only') return 'local_only';
      return 'unknown';
    }

    function fallbackPipelineStage(ship, station) {
      if (station === 'gate_run') return 'validation_gate';
      if (isDoneStation(station)) return 'landed';
      if (station === 'needs_reconciliation') return 'unknown';
      if (station === 'underway') return 'run_work';
      if (station === 'casting_off') return 'spawn';
      if (station === 'needs_captain') return 'human_followthrough';
      return 'unknown';
    }

    function pipelineOf(ship, station) {
      if (ship && ship.pipeline) return ship.pipeline;
      var stage = fallbackPipelineStage(ship, station);
      return {
        profile: fallbackProfile(ship),
        main_stage: stage,
        stage_label: titleize(stage),
        next_human_action: nextStepText(ship, station),
        source_confidence: 'unknown',
        evidence: [],
        validation_branch: null
      };
    }

    function profileLabel(profile) {
      if (profile === 'cad_no_mistakes') return 'CAD / no-mistakes';
      if (profile === 'direct_pr') return 'Direct PR';
      if (profile === 'local_only') return 'Local only';
      if (profile === 'scout_report') return 'Scout report';
      if (profile === 'secondmate') return 'Secondmate';
      return 'Unknown profile';
    }

    function pipelineRailHtml(pipeline) {
      var active = (pipeline && pipeline.main_stage) || 'unknown';
      var activeIndex = pipelineStages.findIndex(function(step) { return step.id === active; });
      return '<div class="pipeline-rail" aria-label="Pipeline">' + pipelineStages.map(function(step, index) {
        var stateName = 'pending';
        if (step.id === active) stateName = active === 'unknown' ? 'unknown' : 'active';
        else if (activeIndex > -1 && index < activeIndex && active !== 'unknown') stateName = 'done';
        return '<div class="rail-step" data-state="' + escapeHtml(stateName) + '">' +
          '<span class="rail-dot" aria-hidden="true"></span>' +
          '<strong>' + escapeHtml(step.label) + '</strong>' +
          '<span class="rail-caption">' + escapeHtml(stateName === 'active' ? 'Now' : (stateName === 'done' ? 'Done' : '')) + '</span>' +
        '</div>';
      }).join('') + '</div>';
    }

    function validationRailHtml(branch) {
      var stepId = (branch && branch.step) || 'validation';
      var stages = validationStages.slice();
      if (!stages.some(function(step) { return step.id === stepId; })) {
        stages.push({ id: stepId, label: titleize(stepId) });
      }
      return '<div class="validation-rail" aria-label="No-mistakes validation">' + stages.map(function(step) {
        var stateName = step.id === stepId ? 'active' : 'pending';
        return '<div class="rail-step" data-state="' + escapeHtml(stateName) + '">' +
          '<span class="rail-dot" aria-hidden="true"></span>' +
          '<strong>' + escapeHtml(step.label) + '</strong>' +
          '<span class="rail-caption">' + escapeHtml(step.id === stepId ? (branch.status || 'Current') : '') + '</span>' +
        '</div>';
      }).join('') + '</div>';
    }

    function validationBranchHtml(pipeline) {
      var branch = pipeline && pipeline.validation_branch;
      if (!pipeline || pipeline.profile !== 'cad_no_mistakes') {
        return '<div class="pipeline-note">Validation detail not tracked for this profile.</div>';
      }
      if (!branch) {
        return '<div class="pipeline-note">Validation detail unavailable for this task.</div>';
      }
      return validationRailHtml(branch) +
        '<dl class="detail-facts">' +
          kvRow('Step', branch.step || '', false, true, false) +
          kvRow('Status', branch.status || '', false, true, false) +
          kvRow('Findings', branch.findings == null ? '-' : String(branch.findings), false, true, false) +
          kvRow('Superseded', branch.superseded_status_log ? 'yes' : 'no', false, true, branch.superseded_status_log ? false : true) +
        '</dl>';
    }

    function noMistakesNeedsDetail(branch) {
      if (!branch) return false;
      var status = String(branch.status || '').toLowerCase();
      var findings = Number(branch.findings || 0);
      return ['running', 'fixing', 'failed', 'cancelled'].indexOf(status) !== -1 || findings > 0;
    }

    function noMistakesNote(branch) {
      if (!branch) return 'No active no-mistakes detail for this task.';
      var status = branch.status || 'unknown';
      return 'No active no-mistakes findings. Last status: ' + status + '.';
    }

    function noMistakesSectionHtml(pipeline) {
      if (!pipeline || pipeline.profile !== 'cad_no_mistakes') return '';
      var branch = pipeline.validation_branch;
      var body = noMistakesNeedsDetail(branch)
        ? validationBranchHtml(pipeline)
        : '<div class="pipeline-note">' + escapeHtml(noMistakesNote(branch)) + '</div>';
      return '<section class="detail-section pipeline-section">' +
        '<div class="detail-section-title">No-mistakes</div>' +
        body +
      '</section>';
    }

    function actionState(ship, station) {
      if (station === 'needs_reconciliation') return { label: 'Needs reconciliation', tone: 'needs_action' };
      if (ship && ship.attention === 'needs_action') return { label: 'Needs you', tone: 'needs_action' };
      if (station === 'needs_captain') return { label: 'Needs you', tone: 'needs_action' };
      if (station === 'gate_run') return { label: 'Validating', tone: 'active' };
      if (station === 'arrived_today') return { label: 'Landed today', tone: 'landed' };
      if (station === 'done_earlier') return { label: 'Done earlier', tone: 'landed' };
      if (station === 'underway') return { label: 'In progress', tone: 'active' };
      if (station === 'casting_off') return { label: 'Starting', tone: 'active' };
      return { label: 'Monitoring', tone: 'active' };
    }

    function actionLinksHtml(ship) {
      var links = [];
      if (ship.pr_url) {
        links.push('<a class="action-link" href="' + escapeHtml(ship.pr_url) + '" target="_blank" rel="noopener noreferrer">Open PR</a>');
      }
      links.push('<span class="pill">' + escapeHtml(ship.task_id || '') + '</span>');
      return links.join('');
    }

    function kvRow(label, value, html, compact, muted) {
      return '<div class="kv' + (compact ? ' compact' : '') + '"><dt>' + escapeHtml(label) + '</dt><dd' + (muted ? ' data-muted="true"' : '') + '>' + (html ? value : escapeHtml(value || '-')) + '</dd></div>';
    }

    function whatMattersHtml(ship, station, nextStep) {
      var done = doneTimelineText(ship);
      return '<dl class="detail-facts">' +
        kvRow('Next', nextStep, false, false, false) +
        (done && isDoneStation(station) ? kvRow('Done', done, false, false, false) : '') +
      '</dl>';
    }

    function renderMeta() {
      var meta = document.getElementById('meta');
      var fleet = (state.snapshot && state.snapshot.fleet) || [];
      var counts = stationCounts();
      var active = (counts.casting_off || 0) + (counts.underway || 0) + (counts.gate_run || 0);
      var reconciliation = counts.needs_reconciliation || 0;
      var age = state.lastGoodAt ? Math.round((Date.now() - state.lastGoodAt) / 1000) : null;
      var tone = state.error ? 'bad' : ((state.stale || state.serverRefreshing) ? 'warn' : 'ok');
      var label = 'Live';
      if (state.error && state.snapshot) label = 'Probe error: showing last good';
      else if (state.error) label = 'Probe Error';
      else if (state.loading) label = 'Loading';
      else if (state.serverRefreshing) label = 'Refreshing';
      else if (state.stale) label = 'Stale';
      var html = '<span class="pill" data-tone="' + tone + '">' + escapeHtml(label) + '</span>';
      html += '<span class="pill">' + fleet.length + ' record' + (fleet.length === 1 ? '' : 's') + '</span>';
      if (active) html += '<span class="pill">' + active + ' active</span>';
      if (reconciliation) html += '<span class="pill" data-tone="warn">' + reconciliation + ' reconcile</span>';
      if (supervisionLagging()) html += '<span class="pill" data-tone="warn">state lag</span>';
      if (age != null) html += '<span class="pill">' + age + 's ago</span>';
      meta.innerHTML = html;
    }

    function renderBanner() {
      var banner = document.getElementById('banner');
      var pieces = [];
      if (state.error && state.snapshot) pieces.push('<strong>Probe error</strong><span>Showing last good data. ' + escapeHtml(state.error) + '</span>');
      else if (state.error) pieces.push('<strong>Probe error</strong><span>' + escapeHtml(state.error) + '</span>');
      if (state.stale && !state.error) pieces.push('<strong>Stale data</strong><span>Last successful probe is older than 30 seconds.</span>');
      banner.innerHTML = pieces.join('');
      banner.className = 'banner' + (pieces.length ? ' show' : '');
    }

    function renderSelectedPipelineRail() {
      var strip = document.getElementById('fleetStrip');
      var ship = state.selectedId ? taskById(state.selectedId) : null;
      if (!ship) {
        strip.innerHTML = '<div class="detail-empty">No ship selected.</div>';
        return;
      }
      var station = stationOf(ship.task_id);
      var pipeline = pipelineOf(ship, station);
      var nextStep = pipeline.next_human_action || nextStepText(ship, station);
      strip.innerHTML = '<div class="selected-pipeline-head">' +
        '<div class="selected-pipeline-title">' +
          '<strong>' + escapeHtml(displayTitle(ship)) + '</strong>' +
          '<span>' + escapeHtml(ship.task_id) + ' · ' + escapeHtml(profileLabel(pipeline.profile)) + '</span>' +
        '</div>' +
        '<div class="selected-pipeline-next">' +
          '<strong>Next</strong>' +
          '<span>' + escapeHtml(nextStep) + '</span>' +
        '</div>' +
      '</div>' +
      pipelineRailHtml(pipeline);
    }

    function renderLanes() {
      var lanes = document.getElementById('lanes');
      var groups = groupFleet();
      lanes.innerHTML = stationDefs.map(function(def) {
        var ships = groups[def.id] || [];
        if (!ships.length) return '';
        var cards = ships.map(function(ship) {
          var selected = ship.task_id === state.selectedId ? 'true' : 'false';
          return '<button class="ship-card" type="button" data-station="' + escapeHtml(def.id) + '" data-attention="' + escapeHtml(ship.attention || 'normal') + '" data-ship="' + escapeHtml(ship.task_id) + '" aria-selected="' + selected + '">' +
            '<span class="ship-title">' + escapeHtml(displayTitle(ship)) + '</span>' +
            laneCardMetaHtml(ship) +
          '</button>';
        }).join('');
        return '<section class="lane" data-station="' + escapeHtml(def.id) + '">' +
          '<div class="lane-title"><strong>' + escapeHtml(def.label) + '</strong><span>' + ships.length + '</span></div>' +
          '<div class="lane-ships">' + cards + '</div>' +
        '</section>';
      }).join('');
    }

    function renderOverlay() {
      var overlay = document.getElementById('overlay');
      var fleet = (state.snapshot && state.snapshot.fleet) || [];
      if (state.loading && !state.snapshot) {
        overlay.innerHTML = '<div><strong>Loading fleet</strong><span>Waiting for the first probe.</span></div>';
        overlay.className = 'overlay-state show';
        return;
      }
      if (!fleet.length) {
        overlay.innerHTML = '<div><strong>No fleet records</strong><span>Probe returned an empty fleet.</span></div>';
        overlay.className = 'overlay-state show';
        return;
      }
      overlay.className = 'overlay-state';
    }

    function renderDetail() {
      var detail = document.getElementById('detail');
      var ship = state.selectedId ? taskById(state.selectedId) : null;
      if (!ship) {
        detail.innerHTML = '<div class="detail-empty">No ship selected.</div>';
        return;
      }
      var station = stationOf(ship.task_id);
      var branchCommit = [ship.branch, ship.commit_short].filter(Boolean).join(' @ ');
      var pipeline = pipelineOf(ship, station);
      var action = actionState(ship, station);
      var reason = stationReason(ship.task_id);
      var update = humanUpdate(ship, station);
      var nextStep = pipeline.next_human_action || nextStepText(ship, station);
      var current = currentStateText(ship);
      detail.innerHTML = '<div class="detail-head">' +
        '<span class="station-chip" data-station="' + escapeHtml(station) + '">' + escapeHtml(stationLabel(station)) + '</span>' +
        '<h2>' + escapeHtml(displayTitle(ship)) + '</h2>' +
        '<div class="detail-meta"><span class="task-id">' + escapeHtml(ship.task_id) + '</span><span class="pill">' + escapeHtml(profileLabel(pipeline.profile)) + '</span>' + attentionBadge(ship) + '</div>' +
      '</div>' +
      '<div class="detail-body">' +
        '<section class="detail-summary">' +
          '<div class="detail-status" data-tone="' + escapeHtml(action.tone) + '"><strong>' + escapeHtml(action.label) + '</strong><span>' + escapeHtml(update) + '</span></div>' +
          '<div class="detail-actions">' + actionLinksHtml(ship) + '</div>' +
        '</section>' +
        '<section class="detail-section">' +
          '<div class="detail-section-title">What matters</div>' +
          whatMattersHtml(ship, station, nextStep) +
        '</section>' +
        '<section class="detail-section pipeline-section">' +
          '<div class="detail-section-title">Pipeline status</div>' +
          '<dl class="detail-facts">' +
            kvRow('Stage', pipeline.stage_label || titleize(pipeline.main_stage), false, true, false) +
            kvRow('Confidence', pipeline.source_confidence || 'unknown', false, true, pipeline.source_confidence !== 'live') +
          '</dl>' +
        '</section>' +
        noMistakesSectionHtml(pipeline) +
        '<details class="detail-section">' +
          '<summary>Operational refs</summary>' +
          '<dl class="detail-facts">' +
            kvRow('State', current, false, true, true) +
            kvRow('Reason', reason, false, true, true) +
            kvRow('Branch', branchCommit, false, true, true) +
            kvRow('Project', shortPath(ship.project) || ship.project || '', false, true, false) +
            kvRow('Worktree', ship.worktree || '', false, true, true) +
            kvRow('Mode', ship.mode || '', false, true, true) +
            kvRow('Harness', [ship.harness, ship.model, ship.effort].filter(Boolean).join(' / '), false, true, true) +
          '</dl>' +
        '</details>' +
      '</div>';
    }

    function render() {
      if (state.snapshot && (!state.selectedId || !taskById(state.selectedId))) {
        state.selectedId = defaultSelection();
      }
      renderMeta();
      renderBanner();
      renderSelectedPipelineRail();
      renderLanes();
      renderOverlay();
      renderDetail();
    }

    document.addEventListener('click', function(event) {
      var button = event.target.closest('[data-ship]');
      if (!button) return;
      state.selectedId = button.getAttribute('data-ship');
      render();
    });

    function capturedAtMs(value) {
      if (!value) return Date.now();
      var parsed = Date.parse(value);
      return Number.isNaN(parsed) ? Date.now() : parsed;
    }

    async function refresh() {
      if (state.requesting) return;
      state.requesting = true;
      try {
        if (!state.snapshot) {
          state.loading = true;
          render();
        }
        var response = await fetch('/api/snapshot', { cache: 'no-store' });
        var cacheMode = response.headers.get('x-firstmate-cache') || '';
        var capturedAt = response.headers.get('x-firstmate-captured-at') || '';
        var serverRefreshing = response.headers.get('x-firstmate-refreshing') === 'true';
        var probeError = response.headers.get('x-firstmate-error') || '';
        var body = await response.json();
        state.serverRefreshing = serverRefreshing;
        if (!response.ok) {
          state.error = body && body.message ? body.message : 'Probe request failed.';
          state.stale = Boolean(state.snapshot);
          state.loading = false;
          render();
          return;
        }
        state.snapshot = body;
        state.error = probeError;
        state.stale = cacheMode === 'last-good';
        state.loading = false;
        state.lastGoodAt = capturedAtMs(capturedAt);
        render();
      } catch (error) {
        state.error = error && error.message ? error.message : 'Probe request failed.';
        state.stale = Boolean(state.snapshot);
        state.loading = false;
        render();
      } finally {
        state.requesting = false;
      }
    }

    setInterval(refresh, 5000);
    setInterval(function() {
      if (state.lastGoodAt && Date.now() - state.lastGoodAt > 30000) {
        state.stale = true;
        render();
      }
    }, 1000);
    refresh();
  </script>
</body>
</html>`;

function baseHeaders(contentType) {
  return {
    'content-type': contentType,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  };
}

function send(res, status, headers, body) {
  res.writeHead(status, headers);
  res.end(body);
}

function sendJson(res, status, body, extraHeaders = {}) {
  send(res, status, { ...baseHeaders('application/json; charset=utf-8'), ...extraHeaders }, JSON.stringify(body));
}

function trimmedError(error) {
  const message = error && error.message ? String(error.message) : 'probe failed';
  return message.length > 900 ? `${message.slice(0, 900)}...` : message;
}

function headerSafe(value) {
  return String(value).replace(/[\r\n]+/g, ' ').slice(0, 900);
}

function validateSnapshot(stdout) {
  try {
    JSON.parse(stdout);
  } catch (error) {
    throw new Error(`probe emitted invalid JSON: ${error.message}`);
  }
}

function runProbe(kind) {
  const args = kind === 'report' ? ['--report'] : ['--json'];
  return new Promise((resolve, reject) => {
    const child = spawn(probeBin, args, {
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let done = false;
    let timedOut = false;
    let outputTooLarge = false;
    let sigkillTimer = null;

    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      sigkillTimer = setTimeout(() => child.kill('SIGKILL'), 250);
      sigkillTimer.unref();
    }, probeTimeoutMs);
    timeoutTimer.unref();

    function finish(fn) {
      if (done) return;
      done = true;
      clearTimeout(timeoutTimer);
      if (sigkillTimer) clearTimeout(sigkillTimer);
      fn();
    }

    function append(which, chunk) {
      if (outputTooLarge) return;
      if (which === 'stdout') stdout += chunk;
      else stderr += chunk;
      if (stdout.length + stderr.length > maxOutputBytes) {
        outputTooLarge = true;
        child.kill('SIGTERM');
      }
    }

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => append('stdout', chunk));
    child.stderr.on('data', chunk => append('stderr', chunk));
    child.on('error', error => finish(() => reject(error)));
    child.on('close', (code, signal) => finish(() => {
      if (timedOut) {
        reject(new Error(`probe timed out after ${probeTimeoutMs}ms`));
        return;
      }
      if (outputTooLarge) {
        reject(new Error(`probe output exceeded ${maxOutputBytes} bytes`));
        return;
      }
      if (code !== 0) {
        const suffix = stderr.trim() ? `: ${stderr.trim()}` : '';
        reject(new Error(`probe exited ${code == null ? `via ${signal}` : code}${suffix}`));
        return;
      }
      try {
        if (kind === 'snapshot') validateSnapshot(stdout);
        resolve({ body: stdout, capturedAt: new Date().toISOString() });
      } catch (error) {
        reject(error);
      }
    }));
  });
}

function startProbe(kind) {
  inFlight[kind] = runProbe(kind)
    .then(result => {
      cache[kind] = result;
      return { ok: true, result };
    })
    .catch(error => ({ ok: false, error }))
    .finally(() => {
      inFlight[kind] = null;
    });
  return inFlight[kind];
}

function scheduleSnapshotRefresh() {
  if (snapshotRefresh.timer) return;
  snapshotRefresh.timer = setTimeout(() => {
    snapshotRefresh.timer = null;
    startSnapshotRefresh();
  }, refreshMs);
  snapshotRefresh.timer.unref();
}

function startSnapshotRefresh() {
  if (snapshotRefresh.inFlight) return snapshotRefresh.inFlight;
  if (snapshotRefresh.timer) {
    clearTimeout(snapshotRefresh.timer);
    snapshotRefresh.timer = null;
  }
  snapshotRefresh.inFlight = runProbe('snapshot')
    .then(result => {
      cache.snapshot = result;
      snapshotRefresh.lastError = null;
      return { ok: true, result };
    })
    .catch(error => {
      snapshotRefresh.lastError = error;
      return { ok: false, error };
    })
    .finally(() => {
      snapshotRefresh.inFlight = null;
      scheduleSnapshotRefresh();
    });
  return snapshotRefresh.inFlight;
}

function snapshotHeaders(cacheMode, error = null) {
  const headers = baseHeaders('application/json; charset=utf-8');
  headers['x-firstmate-cache'] = cacheMode;
  headers['x-firstmate-refreshing'] = snapshotRefresh.inFlight ? 'true' : 'false';
  if (cache.snapshot) headers['x-firstmate-captured-at'] = cache.snapshot.capturedAt;
  if (error) headers['x-firstmate-error'] = headerSafe(trimmedError(error));
  return headers;
}

function sendSnapshotSuccess(res, cacheMode = null) {
  const error = snapshotRefresh.lastError;
  const mode = cacheMode || (error ? 'last-good' : (snapshotRefresh.inFlight ? 'stale-while-refresh' : 'fresh'));
  send(res, 200, snapshotHeaders(mode, error), cache.snapshot.body);
}

function sendSnapshotFailure(res, error) {
  const message = trimmedError(error);
  sendJson(res, 503, {
    error: 'probe_failed',
    message,
    cached: false,
  }, snapshotHeaders('none', error));
}

function sendProbeSuccess(res, kind, cached, cacheMode) {
  const contentType = kind === 'report' ? 'text/plain; charset=utf-8' : 'application/json; charset=utf-8';
  const headers = baseHeaders(contentType);
  if (cacheMode) headers['x-firstmate-cache'] = cacheMode;
  send(res, 200, headers, cached.body);
}

function sendProbeFailure(res, kind, error) {
  const cached = cache[kind];
  const message = trimmedError(error);
  let text = `probe failed: ${message}\n`;
  if (cached) {
    text += `\nLast good report from ${cached.capturedAt}:\n\n${cached.body}`;
  }
  send(res, 503, { ...baseHeaders('text/plain; charset=utf-8'), 'x-firstmate-cache': cached ? 'last-good' : 'none' }, text);
}

async function serveProbe(res, kind) {
  if (inFlight[kind]) {
    if (cache[kind]) {
      sendProbeSuccess(res, kind, cache[kind], 'stale-while-refresh');
      return;
    }
    const pending = await inFlight[kind];
    if (pending.ok) sendProbeSuccess(res, kind, pending.result, '');
    else sendProbeFailure(res, kind, pending.error);
    return;
  }

  const result = await startProbe(kind);
  if (result.ok) sendProbeSuccess(res, kind, result.result, '');
  else sendProbeFailure(res, kind, result.error);
}

async function serveSnapshot(res) {
  if (cache.snapshot) {
    sendSnapshotSuccess(res);
    return;
  }

  if (!snapshotRefresh.inFlight) {
    sendSnapshotFailure(res, snapshotRefresh.lastError || new Error('snapshot refresh has not started'));
    return;
  }

  const pending = await snapshotRefresh.inFlight;
  if (pending.ok) sendSnapshotSuccess(res, 'fresh');
  else sendSnapshotFailure(res, pending.error);
}

const server = http.createServer((req, res) => {
  if (req.method !== 'GET') {
    sendJson(res, 405, { error: 'method_not_allowed', allowed: ['GET'] }, { allow: 'GET' });
    return;
  }

  let url;
  try {
    url = new URL(req.url, `http://${host}:${port || 0}`);
  } catch (_error) {
    sendJson(res, 400, { error: 'bad_request' });
    return;
  }

  if (url.pathname === '/') {
    send(res, 200, baseHeaders('text/html; charset=utf-8'), html);
    return;
  }
  if (url.pathname === '/favicon.ico') {
    send(res, 204, { 'cache-control': 'no-store' }, '');
    return;
  }
  if (url.pathname === '/healthz') {
    sendJson(res, 200, { ok: true });
    return;
  }
  if (url.pathname === '/api/snapshot') {
    serveSnapshot(res).catch(error => sendSnapshotFailure(res, error));
    return;
  }
  if (url.pathname === '/api/report') {
    serveProbe(res, 'report').catch(error => sendProbeFailure(res, 'report', error));
    return;
  }

  sendJson(res, 404, { error: 'not_found' });
});

server.on('clientError', (_error, socket) => {
  socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});

server.on('error', error => {
  if (error && error.code === 'EADDRINUSE') {
    console.error(`fm-dashboard-server: ${host}:${port} is already in use`);
    process.exit(1);
  }
  console.error(`fm-dashboard-server: ${error && error.message ? error.message : error}`);
  process.exit(1);
});

server.listen(port, host, () => {
  const address = server.address();
  const boundPort = typeof address === 'object' && address ? address.port : port;
  startSnapshotRefresh();
  console.log(`fm-dashboard-server listening on http://${host}:${boundPort}`);
});
NODE

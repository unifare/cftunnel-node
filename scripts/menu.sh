#!/usr/bin/env bash
# CF Tunnel Proxy - Interactive Menu
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
D=/opt/proxy

show_banner() {
  echo ""
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║     CF Tunnel Proxy Manager         ║"
  echo "  ╚══════════════════════════════════════╝"
  echo ""
}

show_status() {
  echo "  ── Status ──"
  if test -f "$D/.state"; then
    . "$D/.state"
    echo "  Zone:     $zone_name"
    echo "  Tunnel:   $tunnel_name"
    echo ""
    for s in singbox-proxy cloudflared-proxy; do
      st=$(systemctl is-active $s 2>/dev/null || echo "dead")
      printf "  %-22s %s\n" "$s" "$st"
    done
    echo ""
    test -f "$D/clients.txt" && cat "$D/clients.txt"
  else
    echo "  No deployment found."
  fi
  echo ""
}

show_token_guide() {
  echo ""
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║          How to create a CF API Token           ║"
  echo "  ╠══════════════════════════════════════════════════╣"
  echo "  ║                                                ║"
  echo "  ║  1. Open: https://dash.cloudflare.com/profile   ║"
  echo "  ║            → API Tokens                        ║"
  echo "  ║                                                ║"
  echo "  ║  2. Click: Create Token → Custom               ║"
  echo "  ║                                                ║"
  echo "  ║  3. Permissions needed:                        ║"
  echo "  ║     ┌──────────────────────┬────────┐          ║"
  echo "  ║     │ Permission           │ Scope  │          ║"
  echo "  ║     ├──────────────────────┼────────┤          ║"
  echo "  ║     │ Tunnel — Edit        │Account │          ║"
  echo "  ║     │ DNS    — Edit        │Zone    │          ║"
  echo "  ║     └──────────────────────┴────────┘          ║"
  echo "  ║                                                ║"
  echo "  ║  4. Account Resources: Include → All           ║"
  echo "  ║     Zone Resources:    Include → All           ║"
  echo "  ║                                                ║"
  echo "  ║  5. Continue → Create Token → COPY IT NOW      ║"
  echo "  ║     (Token only shown once, save it!)          ║"
  echo "  ║                                                ║"
  echo "  ║  Token format: NO special prefix               ║"
  echo "  ║  NOT a Tunnel token (eyJh...)                  ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo ""
}

do_install() {
  echo ""
  read -rp "  CF API Token: " tok
  test -z "$tok" && { echo "  Cancelled."; return; }
  echo ""
  bash "$SCRIPT_DIR/install.sh" --tok "$tok"
}

do_uninstall() {
  if test ! -f "$D/.state"; then
    echo "  No deployment found."
    return
  fi
  echo ""
  read -rp "  Uninstall and delete CF resources? [y/N]: " yn
  case "$yn" in
    [yY]*) bash "$SCRIPT_DIR/uninstall.sh" ;;
    *) echo "  Cancelled." ;;
  esac
}

do_fresh() {
  echo ""
  read -rp "  This will create NEW domains. Continue? [y/N]: " yn
  case "$yn" in
    [yY]*) read -rp "  CF API Token: " tok
           test -z "$tok" && { echo "  Cancelled."; return; }
           bash "$SCRIPT_DIR/install.sh" --tok "$tok" --fresh ;;
    *) echo "  Cancelled." ;;
  esac
}

while true; do
  clear 2>/dev/null || true
  show_banner
  show_status
  echo "  ── Menu ──"
  echo "  1. Install / Update"
  echo "  2. Uninstall"
  echo "  3. Rebuild (new domains)"
  echo "  4. Token guide"
  echo "  5. Service status"
  echo "  6. View logs"
  echo "  0. Exit"
  echo ""
  read -rp "  Choose [0-6]: " choice

  case "$choice" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_fresh ;;
    4) show_token_guide; read -rp "  Press Enter..." _ ;;
    5) systemctl status --no-pager singbox-proxy cloudflared-proxy 2>/dev/null || true
       read -rp "  Press Enter..." _ ;;
    6) journalctl -u singbox-proxy -u cloudflared-proxy --no-pager -n 50 2>/dev/null || true
       read -rp "  Press Enter..." _ ;;
    0) echo ""; exit 0 ;;
    *) echo "  Invalid."; sleep 1 ;;
  esac
done

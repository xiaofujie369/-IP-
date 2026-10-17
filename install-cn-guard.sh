#!/usr/bin/env bash
# cn-guard: mainland China source-IP guard for Debian 13 + nftables/iptables-nft.
# Safety: first apply is temporary and automatically rolls back unless confirmed.
set -Eeuo pipefail
umask 077

CONF=/etc/cn-guard.conf
STATE=/var/lib/cn-guard
RULES=/etc/cn-guard.nft
BIN=/usr/local/sbin/cn-guard
ROLLBACK_UNIT=cn-guard-rollback
URL4=${URL4:-https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone}
URL6=${URL6:-https://www.ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone}
MIN4=500
MIN6=50

log(){ printf '[cn-guard] %s\n' "$*" >&2; logger -t cn-guard -- "$*" 2>/dev/null || true; }
die(){ log "ERROR: $*"; exit 1; }
need_root(){ [[ $(id -u) -eq 0 ]] || die "run as root"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
load_conf(){ [[ -r "$CONF" ]] && source "$CONF"; ADMIN_IPS=${ADMIN_IPS:-}; WAN_IFS=${WAN_IFS:-}; ROLLBACK_MIN=${ROLLBACK_MIN:-15}; LOCAL_V4=${LOCAL_V4:-}; }
wan_interfaces(){
  if [[ -n "${WAN_IFS:-}" ]]; then printf '%s\n' "$WAN_IFS"; return; fi
  { ip -4 -o route show default; ip -6 -o route show default; } |
    awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | sort -u | xargs
}
backup(){
  need_root
  local d="/root/cn-guard-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -m 700 -p "$d"
  nft list ruleset > "$d/nft-ruleset.txt"
  iptables-save > "$d/iptables-save.txt" 2>/dev/null || true
  ip6tables-save > "$d/ip6tables-save.txt" 2>/dev/null || true
  ip addr show > "$d/addresses.txt"
  ip route show > "$d/routes4.txt"
  ip -6 route show > "$d/routes6.txt"
  ss -lntup > "$d/listeners.txt"
  printf '%s\n' "$d" > /root/cn-guard-last-backup
  log "backup created: $d"
}
install_command(){
  need_root
  for c in bash curl python3 nft ip ss systemctl systemd-run logger; do command -v "$c" >/dev/null 2>&1 || missing=1; done
  if [[ ${missing:-0} -eq 1 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl python3 nftables iproute2 iptables
  fi
  install -d -m 700 /etc/cn-guard /var/lib/cn-guard
  if [[ ! -f "$CONF" ]]; then
    local admin="${ADMIN_IP:-}"
    if [[ -z "$admin" && -n "${SSH_CONNECTION:-}" ]]; then admin="${SSH_CONNECTION%% *}"; fi
    [[ -n "$admin" ]] || die "cannot detect admin IP; rerun with ADMIN_IP=x.x.x.x"
    cat > "$CONF" <<EOF
# Space-separated interface names. Empty = auto-detect default-route interfaces.
WAN_IFS=""
# Only add trusted on-link source ranges here after reviewing the network design.
# Normally leave empty; RFC1918 source addresses are NOT automatically exempted.
LOCAL_V4=""
# Current management client must be in the mainland IP database before activation.
ADMIN_IPS="$admin"
ROLLBACK_MIN=15
EOF
    chmod 600 "$CONF"
  fi
  [[ -f "$0" ]] || die "run this installer from a downloaded file, not via 'curl | bash'; save it as install-cn-guard.sh first"
  install -m 700 "$0" "$BIN"
  log "installed command: $BIN"
  log "configuration: $CONF"
  log "no firewall rules changed by the install-only operation"
}
fetch_lists(){
  need curl; need python3
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' RETURN
  for fam in 4 6; do
    local url="URL$fam" min="MIN$fam"
    url="${!url}"; min="${!min}"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 90 "$url" -o "$tmp/raw$fam" || die "download failed: $url"
    python3 - "$fam" "$tmp/raw$fam" "$min" > "$tmp/cn$fam.zone" <<'PY'
import sys, ipaddress
fam, path, minimum = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
nets=[]
for raw in open(path, encoding="ascii"):
    s=raw.strip()
    if not s or s.startswith("#"): continue
    n=ipaddress.ip_network(s, strict=True)
    if n.version != fam or n.prefixlen < (8 if fam == 4 else 16):
        raise SystemExit("invalid/unexpected network: "+s)
    nets.append(n)
nets=list(ipaddress.collapse_addresses(nets))
if len(nets) < minimum:
    raise SystemExit(f"too few IPv{fam} networks: {len(nets)} < {minimum}")
print("\n".join(map(str,nets)))
PY
  done
  # Refuse to activate/update if any configured management IP is absent.
  python3 - "$tmp/cn4.zone" "$tmp/cn6.zone" ${ADMIN_IPS} <<'PY'
import sys, ipaddress
lists=[ipaddress.ip_network(x.strip()) for f in sys.argv[1:3] for x in open(f) if x.strip()]
for text in sys.argv[3:]:
    ip=ipaddress.ip_address(text)
    if not any(n.version==ip.version and ip in n for n in lists):
        raise SystemExit("management IP is not in mainland lists; refusing: "+str(ip))
PY
  for fam in 4 6; do
    [[ ! -s "$STATE/cn$fam.zone" ]] || cp -p "$STATE/cn$fam.zone" "$STATE/cn$fam.zone.prev"
    install -m 600 "$tmp/cn$fam.zone" "$STATE/cn$fam.zone.new"
    mv -f "$STATE/cn$fam.zone.new" "$STATE/cn$fam.zone"
  done
  date -u +%FT%TZ > "$STATE/updated"
  log "validated IP lists: IPv4 $(wc -l < "$STATE/cn4.zone") CIDRs; IPv6 $(wc -l < "$STATE/cn6.zone") CIDRs"
}
build_rules(){
  [[ -s "$STATE/cn4.zone" && -s "$STATE/cn6.zone" ]] || die "IP lists missing; run cn-guard fetch"
  local wan ifs e4 e6 body local4=""
  wan=$(wan_interfaces)
  [[ -n "${wan// /}" ]] || die "cannot determine WAN interface; set WAN_IFS in $CONF"
  ifs=$(for i in $wan; do [[ "$i" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "invalid interface name: $i"; printf '"%s", ' "$i"; done)
  ifs=${ifs%, }
  e4=$(paste -sd, "$STATE/cn4.zone")
  e6=$(paste -sd, "$STATE/cn6.zone")
  if [[ -n "${LOCAL_V4:-}" ]]; then
    local4="ip saddr { ${LOCAL_V4// /, } } return"
  fi
  body="
    iifname != { $ifs } return
    ct state established,related return
    $local4
    ip6 saddr fe80::/10 return
    icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } return
    ip saddr @cn4 return
    ip6 saddr @cn6 return
    counter drop"
  cat > "$RULES.new" <<EOF
# generated by cn-guard at $(date -u +%FT%TZ); WAN interfaces: $wan
table inet cn_guard {
  set cn4 { type ipv4_addr; flags interval; elements = { $e4 } }
  set cn6 { type ipv6_addr; flags interval; elements = { $e6 } }
  chain input_guard {
    type filter hook input priority -20; policy accept;
    $body
  }
  chain forward_guard {
    type filter hook forward priority -20; policy accept;
    $body
  }
}
EOF
  nft -c -f "$RULES.new" || die "nft syntax validation failed; no rules applied"
  mv -f "$RULES.new" "$RULES"
}
load_rules(){
  # A single nft batch is transactional. Delete/recreate only our own table if it exists.
  local tmp; tmp=$(mktemp)
  if nft list table inet cn_guard >/dev/null 2>&1; then
    printf 'delete table inet cn_guard\n' > "$tmp"
  fi
  cat "$RULES" >> "$tmp"
  nft -c -f "$tmp" || { rm -f "$tmp"; die "nft validation failed; previous runtime rules preserved"; }
  nft -f "$tmp" || { rm -f "$tmp"; die "nft transaction failed; previous runtime rules should be preserved"; }
  rm -f "$tmp"
}
apply(){
  need_root; load_conf
  [[ -n "$ADMIN_IPS" ]] || die "ADMIN_IPS is empty in $CONF"
  if nft list table inet cn_guard >/dev/null 2>&1; then
    die "table inet cn_guard already exists; inspect it first, then use 'cn-guard update' or 'cn-guard rollback' as appropriate"
  fi
  backup
  fetch_lists
  build_rules
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
  systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_MIN}m" /bin/bash -c 'nft delete table inet cn_guard 2>/dev/null || true'
  systemctl is-active --quiet "$ROLLBACK_UNIT.timer" || die "rollback timer failed to start; rules not applied"
  load_rules
  log "rules ACTIVE temporarily; rollback in ${ROLLBACK_MIN} minutes"
  log "open a NEW SSH session and test all business ports; then run: cn-guard confirm"
  log "to undo immediately: cn-guard rollback"
}
confirm(){
  need_root; load_conf
  nft list table inet cn_guard >/dev/null 2>&1 || die "cn_guard table not active"
  [[ -s "$RULES" ]] || die "rules file missing"
  cat > /etc/systemd/system/cn-guard.service <<'UNIT'
[Unit]
Description=China mainland source IP guard (dedicated nftables table)
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cn-guard load
ExecReload=/usr/local/sbin/cn-guard load
ExecStop=/usr/sbin/nft delete table inet cn_guard

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/cn-guard-update.service <<'UNIT'
[Unit]
Description=Update China mainland IP lists for cn-guard
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cn-guard update
UNIT
  cat > /etc/systemd/system/cn-guard-update.timer <<'UNIT'
[Unit]
Description=Daily cn-guard IP database update

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now cn-guard.service || die "could not start persistent cn-guard service; leave rollback timer active and investigate"
  systemctl enable --now cn-guard-update.timer
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
  log "persistence and daily update timer enabled"
}
update_lists(){
  need_root; load_conf
  # Preserve the prior cache and generated rules so a failed update can be rolled back.
  local old4="" old6="" oldrules="" had4=0 had6=0 hadrules=0
  if [[ -f "$STATE/cn4.zone" ]]; then had4=1; old4=$(mktemp); cp -p "$STATE/cn4.zone" "$old4"; fi
  if [[ -f "$STATE/cn6.zone" ]]; then had6=1; old6=$(mktemp); cp -p "$STATE/cn6.zone" "$old6"; fi
  if [[ -f "$RULES" ]]; then hadrules=1; oldrules=$(mktemp); cp -p "$RULES" "$oldrules"; fi

  restore_cache(){
    if [[ $had4 -eq 1 ]]; then cp -p "$old4" "$STATE/cn4.zone"; else rm -f "$STATE/cn4.zone"; fi
    if [[ $had6 -eq 1 ]]; then cp -p "$old6" "$STATE/cn6.zone"; else rm -f "$STATE/cn6.zone"; fi
    if [[ $hadrules -eq 1 ]]; then cp -p "$oldrules" "$RULES"; else rm -f "$RULES"; fi
    rm -f "$old4" "$old6" "$oldrules"
  }

  if ! ( fetch_lists && build_rules ); then
    restore_cache
    die "update download/validation/build failed; previous cache and rules file restored; active firewall table unchanged"
  fi
  if ! ( load_rules ); then
    restore_cache
    die "update application failed; previous cache and rules file restored; nftables transaction should preserve active table"
  fi
  rm -f "$old4" "$old6" "$oldrules"
  log "IP database update applied"
}
rollback(){
  need_root
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
  systemctl disable --now cn-guard.service cn-guard-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/cn-guard.service /etc/systemd/system/cn-guard-update.service /etc/systemd/system/cn-guard-update.timer
  systemctl daemon-reload
  nft delete table inet cn_guard 2>/dev/null || true
  log "removed only inet cn_guard and cn-guard systemd units"
}
status(){
  nft list table inet cn_guard 2>&1 || true
  systemctl list-timers --all --no-pager 'cn-guard*' || true
  cat "$STATE/updated" 2>/dev/null || true
}
case "${1:-install}" in
  install) install_command; "$BIN" apply ;;
  --install-only) install_command ;;
  backup) load_conf; backup ;;
  fetch) load_conf; fetch_lists ;;
  build) load_conf; build_rules ;;
  apply) apply ;;
  load) load_conf; load_rules ;;
  confirm) confirm ;;
  update) update_lists ;;
  rollback) rollback ;;
  status) status ;;
  *) echo "Usage: cn-guard {install|backup|fetch|build|apply|load|confirm|update|rollback|status}"; exit 2 ;;
esac

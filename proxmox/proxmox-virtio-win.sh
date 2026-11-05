#!/usr/bin/env bash
# =============================================================================
# proxmox-virtio-win.sh
#
# Host-side helper (run as root on a Proxmox VE node) that automates the
# "Windows guest -> VirtIO" migration procedure for a QEMU/KVM virtual machine.
#
# It is the counterpart of windows/Install-VirtioWin.ps1, which runs INSIDE the
# Windows guest. Typical workflow:
#
#   1. (host)   proxmox-virtio-win.sh prepare  --vmid 100
#               -> downloads the newest virtio-win ISO, attaches it to the VM
#                  as a CD-ROM, enables the QEMU guest agent option and makes
#                  sure a VirtIO SCSI controller type is selected.
#   2. (guest)  Install-VirtioWin.ps1
#               -> installs the VirtIO drivers and the QEMU guest agent.
#   3. (host)   proxmox-virtio-win.sh status   --vmid 100     (optional check)
#   4. (host)   proxmox-virtio-win.sh finalize --vmid 100 --nic --vga --disk
#               -> switches the virtual hardware to VirtIO (network card,
#                  display adapter and the boot disk) safely, with a snapshot
#                  taken first.
#
# Commands
#   latest    Print the newest virtio-win ISO version/URL found upstream.
#   prepare   Download + attach the ISO, enable the agent (see above).
#             With --installer-iso, also builds and attaches a small helper
#             ISO holding Install-VirtioWin.ps1 and a double-click launcher:
#             useful when the guest has no network, no RDP and no agent yet,
#             so the only way in is the Proxmox console.
#   status    Show the VM hardware bus/model types and, if the guest agent
#             answers, the Windows-side view (disks, drivers, services).
#   finalize  Switch NIC / VGA / boot disk to VirtIO (opt-in flags).
#
# Global options
#   --vmid ID         VM to operate on (required except for `latest`).
#   --storage NAME    Proxmox storage that holds ISO images (default: local).
#   --dry-run         Print the qm/pvesm commands instead of running them.
#   --yes             Do not ask for confirmation before disruptive steps.
#   --installer-iso   (prepare) build/attach the helper ISO described above.
#   -h, --help        Show the help text.
#
# `finalize` options
#   --nic             Change net0's model to virtio (MAC address is preserved).
#   --vga             Change the display adapter to virtio.
#   --disk            Move the boot disk from IDE/SATA to VirtIO SCSI.
#   --no-snapshot     Do not take a snapshot before --disk (NOT recommended).
#
# Requirements: Proxmox VE 8/9 (qm, pvesm), curl, python3 (shipped with PVE),
# and for `status`/`finalize` the QEMU guest agent running in the Windows guest.
#
# Exit status: 0 on success, non-zero on any error (the script stops at the
# first failure; nothing is half-applied without being reported).
#
# License: MIT (see LICENSE).
# =============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Constants (edit here if upstream moves things around)
# ----------------------------------------------------------------------------

# Upstream directory listing that contains one sub-directory per released
# virtio-win version (virtio-win-0.1.302-1/, virtio-win-0.1.285-1/, ...).
ARCHIVE_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio"

# Pattern used to recognise an already attached virtio-win ISO in a VM config.
ISO_NAME_RE='virtio-win[-_0-9.]*\.iso'

# ----------------------------------------------------------------------------
# Defaults for command line options
# ----------------------------------------------------------------------------
VMID=""
STORAGE="local"
DRY_RUN=0
ASSUME_YES=0
DO_NIC=0
DO_VGA=0
DO_DISK=0
DO_SNAPSHOT=1
INSTALLER_ISO=0
COMMAND=""

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

# All diagnostics go to stderr so that functions can return values on stdout
# (e.g. `volid=$(download_iso ...)`) without capturing log lines.
log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# Print the leading comment block of this file as help text.
usage() { sed -n '2,/^# ====.*$/{/^# ====/!s/^# \{0,1\}//p}' "$0" | sed '1d'; }

# Fail early if a required tool is missing.
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# Execute a command, or only print it when --dry-run is active.
# Use for every command that MODIFIES something (qm set, qm start, mv, ...).
# Read-only commands are executed directly.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[1;35m[DRY ]\033[0m %s\n' "$*" >&2
  else
    "$@"
  fi
}

# Ask for confirmation unless --yes (or --dry-run) was given.
confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer =~ ^[Yy]$ ]] || die "Aborted by user."
}

# Return the value of a key in `qm config` output (first match), e.g.
#   vm_conf_value net0   ->  virtio=BC:24:...,bridge=vmbr0
vm_conf_value() { qm config "$VMID" | sed -n "s/^$1: //p" | head -n1; }

# ----------------------------------------------------------------------------
# Guest agent helpers
# ----------------------------------------------------------------------------

# True when the QEMU guest agent answers a ping.
agent_up() { qm guest cmd "$VMID" ping >/dev/null 2>&1; }

# Wait (default 10 min) until the guest agent answers.
wait_agent() {
  local timeout=${1:-600} waited=0
  log "Waiting for the guest agent of VM $VMID (up to ${timeout}s)..."
  until agent_up; do
    sleep 5; waited=$((waited + 5))
    [[ $waited -lt $timeout ]] || die "Guest agent did not answer within ${timeout}s."
  done
}

# Run a PowerShell snippet inside the guest through the guest agent and print
# its stdout. The agent runs commands as SYSTEM, so no password is needed.
#
# The command is started ASYNCHRONOUSLY and polled: a synchronous
# `qm guest exec` gives up after a few seconds on slow guests (the agent
# answers "got timeout" even though the command is still running), which would
# make callers believe the command failed. Here we wait up to ${2:-180}s.
# Returns non-zero (with a message on stderr) if the command cannot be run or
# does not finish in time, so callers never mistake "no answer" for "no".
guest_ps() {
  local ps=$1 limit=${2:-180} out pid status waited=0
  out=$(qm guest exec "$VMID" --synchronous 0 -- powershell -NoProfile -NonInteractive \
          -Command "$ps" 2>&1) || { warn "guest-exec failed: $out"; return 1; }
  pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' <<<"$out" 2>/dev/null) \
    || { warn "Unexpected guest-exec answer: $out"; return 1; }
  while :; do
    # exec-status itself can time out while the guest is busy: just retry.
    if status=$(qm guest exec-status "$VMID" "$pid" 2>/dev/null) \
       && python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("exited") else 1)' <<<"$status" 2>/dev/null; then
      break
    fi
    sleep 2; waited=$((waited + 2))
    [[ $waited -lt $limit ]] || { warn "Guest command did not finish within ${limit}s."; return 1; }
  done
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data",""))' <<<"$status"
}

# ----------------------------------------------------------------------------
# Upstream discovery and download
# ----------------------------------------------------------------------------

# Print "<directory> <iso-url>" for the newest upstream release whose ISO exists.
# Versions are compared with `sort -V` (natural version order), so
# 0.1.302-1 > 0.1.285-1 > 0.1.262-2 > 0.1.262-1.
find_latest_iso() {
  local index dirs dir ver url
  index=$(curl -fsSL "$ARCHIVE_URL/") || die "Cannot read $ARCHIVE_URL/"
  dirs=$(grep -oE 'href="virtio-win-[0-9][0-9.]*-[0-9]+/"' <<<"$index" \
         | sed -E 's/^href="//; s/\/"$//' | sort -V -r)
  [[ -n $dirs ]] || die "No virtio-win-* directory found at $ARCHIVE_URL/"
  for dir in $dirs; do
    ver=${dir#virtio-win-}      # 0.1.302-1
    ver=${ver%-*}               # 0.1.302   (drop the packaging release number)
    url="$ARCHIVE_URL/$dir/virtio-win-$ver.iso"
    # A release directory may exist without the ISO (still being published):
    # only accept it if the ISO answers a HEAD request.
    if curl -fsSI "$url" >/dev/null 2>&1; then
      echo "$dir $url"
      return 0
    fi
  done
  die "No downloadable ISO found in $ARCHIVE_URL/"
}

# Download the ISO into the Proxmox ISO storage (idempotent, resumable) and
# print the resulting volume id (e.g. local:iso/virtio-win-0.1.302.iso).
download_iso() {
  local url=$1 file path volid expected actual
  file=$(basename "$url")
  volid="$STORAGE:iso/$file"
  path=$(pvesm path "$volid") || die "Storage '$STORAGE' not found or has no 'iso' content type."

  expected=$(curl -fsSI "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)
  actual=$(stat -c %s "$path" 2>/dev/null || echo 0)

  if [[ -n $expected && $expected == "$actual" ]]; then
    log "ISO already present with the expected size: $path"
  else
    log "Downloading $url"
    run mkdir -p "$(dirname "$path")"
    # Download to a temporary name; rename only after a size check so that an
    # interrupted download is never mistaken for a complete ISO.
    run curl -fL --retry 3 -C - --progress-bar -o "$path.part" "$url"
    if [[ $DRY_RUN -eq 0 ]]; then
      actual=$(stat -c %s "$path.part")
      [[ $expected == "$actual" ]] || die "Size mismatch: expected $expected bytes, got $actual."
      mv "$path.part" "$path"
      log "SHA-256 (for your records): $(sha256sum "$path" | cut -d' ' -f1)"
    fi
  fi
  echo "$volid"
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

cmd_latest() {
  local dir url
  read -r dir url < <(find_latest_iso)
  echo "release : $dir"
  echo "iso url : $url"
}

# Find the first unused sata/ide slot for a CD-ROM drive.
free_cdrom_slot() {
  local conf slot
  conf=$(qm config "$VMID")
  for slot in sata5 sata4 sata3 sata2 sata1 sata0 ide3 ide2 ide1 ide0; do
    grep -q "^$slot:" <<<"$conf" || { echo "$slot"; return 0; }
  done
  die "No free IDE/SATA slot available for the CD-ROM drive."
}

# Build a tiny ISO (label VIRTIO_INSTALLER) that contains the guest-side
# installer script plus a launcher, and print its volume id. The script is taken
# from the repository checkout next to this file; if absent (script copied
# alone), it is downloaded from GitHub.
build_installer_iso() {
  local here src tmp iso_name path tool
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  src="$here/../windows/Install-VirtioWin.ps1"
  iso_name="qemu-win-virtio-installer.iso"
  path=$(pvesm path "$STORAGE:iso/$iso_name") || die "Storage '$STORAGE' has no 'iso' content type."
  tool=$(command -v xorriso || command -v genisoimage || command -v mkisofs || true)
  [[ -n $tool ]] || die "xorriso, genisoimage or mkisofs is required for --installer-iso (apt install xorriso)."

  tmp=$(mktemp -d)
  # Always remove the temporary directory, whatever happens.
  trap 'rm -rf "$tmp"' RETURN
  if [[ -f $src ]]; then
    cp "$src" "$tmp/Install-VirtioWin.ps1"
  else
    log "Install-VirtioWin.ps1 not found next to this script; downloading it from GitHub"
    curl -fsSL "https://raw.githubusercontent.com/sctg-development/qemu-win-virtio/main/windows/Install-VirtioWin.ps1" \
      -o "$tmp/Install-VirtioWin.ps1" || die "Cannot download Install-VirtioWin.ps1"
  fi
  # Launcher: re-launches itself elevated if needed, then runs the PowerShell
  # installer with a process-scoped execution policy bypass (no system change).
  # CRLF line endings because it is a Windows batch file.
  printf '%s\r\n' \
    '@echo off' \
    'rem Self-elevate if not running as Administrator.' \
    'net session >nul 2>&1' \
    'if errorlevel 1 (' \
    '  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath \"%~f0\""' \
    '  exit /b' \
    ')' \
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-VirtioWin.ps1"' \
    'pause' > "$tmp/Install-VirtioWin.cmd"

  log "Building helper ISO $path"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[1;35m[DRY ]\033[0m %s -o %s ... (contains Install-VirtioWin.ps1, Install-VirtioWin.cmd)\n' "$tool" "$path" >&2
  elif [[ $(basename "$tool") == xorriso ]]; then
    "$tool" -as mkisofs -quiet -V VIRTIO_INSTALLER -J -r -o "$path" "$tmp"
  else
    "$tool" -quiet -V VIRTIO_INSTALLER -J -r -o "$path" "$tmp"
  fi
  echo "$STORAGE:iso/$iso_name"
}

# Attach an ISO as a CD-ROM on a free slot unless it is already attached.
attach_cdrom() {
  local volid=$1 slot
  if qm config "$VMID" | grep -q "^\(ide\|sata\)[0-9]*:.*$volid"; then
    log "$volid already attached."
    return
  fi
  slot=$(free_cdrom_slot)
  log "Attaching $volid as CD-ROM on $slot"
  run qm set "$VMID" --"$slot" "$volid,media=cdrom"
  # IDE/SATA devices cannot be hot-plugged: on a running VM the new drive stays
  # in the "pending" section until the VM is fully stopped and started again
  # (a guest-initiated reboot is NOT enough).
  if [[ $DRY_RUN -eq 0 ]] && qm pending "$VMID" 2>/dev/null | grep -q "^new.*$slot"; then
    warn "$slot is pending: stop and start the VM (qm stop $VMID && qm start $VMID) to make the CD-ROM appear."
  fi
}

cmd_prepare() {
  local dir url volid slot attached
  read -r dir url < <(find_latest_iso)
  log "Newest upstream release: $dir"
  volid=$(download_iso "$url")

  # Is a virtio-win ISO already attached? Reuse its slot (swap the media).
  attached=$(qm config "$VMID" | grep -E "^(ide|sata)[0-9]+:.*$ISO_NAME_RE" | head -n1 || true)
  if [[ -n $attached ]]; then
    slot=${attached%%:*}
    if grep -q "$volid" <<<"$attached"; then
      log "ISO already attached on $slot."
    else
      log "Replacing the virtio-win ISO attached on $slot by $volid"
      run qm set "$VMID" --"$slot" "$volid,media=cdrom"
    fi
  else
    slot=$(free_cdrom_slot)
    log "Attaching $volid as CD-ROM on $slot"
    run qm set "$VMID" --"$slot" "$volid,media=cdrom"
  fi

  if [[ $INSTALLER_ISO -eq 1 ]]; then
    attach_cdrom "$(build_installer_iso)"
  fi

  # The guest agent option only tells Proxmox to create the virtio-serial
  # channel; the agent itself is installed by Install-VirtioWin.ps1.
  if [[ $(vm_conf_value agent) != 1* ]]; then
    log "Enabling the QEMU guest agent option (agent=1)"
    run qm set "$VMID" --agent 1
  fi

  # virtio-scsi-single (one controller per disk, enables iothread) is the
  # recommended controller. It does not change anything until a disk uses it.
  if [[ $(vm_conf_value scsihw) != virtio-scsi-single ]]; then
    log "Selecting the virtio-scsi-single controller type"
    run qm set "$VMID" --scsihw virtio-scsi-single
  fi

  cat <<EOF

Next step: inside the Windows guest, open an elevated PowerShell and run
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Install-VirtioWin.ps1
(the ISO is available as a CD-ROM drive). See README.md for details.
With --installer-iso, simply open the VIRTIO_INSTALLER CD-ROM in the guest and
run Install-VirtioWin.cmd (it elevates itself).
EOF
}

cmd_status() {
  log "Hardware view of VM $VMID (from the Proxmox configuration):"
  qm config "$VMID" | grep -E '^(name|machine|bios|agent|scsihw|boot|vga|net[0-9]+|(ide|sata|scsi|virtio)[0-9]+):' || true
  if agent_up; then
    log "Guest agent is running. Windows-side view:"
    # Single quotes are intentional: the text is PowerShell, not shell.
    # shellcheck disable=SC2016
    guest_ps '
      "--- Disks (BusType SAS/SCSI with vioscsi = VirtIO SCSI; ATA/IDE = emulated)";
      Get-Disk | Select-Object Number,FriendlyName,BusType,Size | Format-Table -AutoSize | Out-String;
      "--- SCSI controllers";
      Get-CimInstance Win32_SCSIController | Select-Object Name,Status,DriverName | Format-Table -AutoSize | Out-String;
      "--- Network adapters";
      Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed | Format-Table -AutoSize | Out-String;
      "--- VirtIO drivers staged in the driver store";
      Get-WindowsDriver -Online | Where-Object { $_.ProviderName -match "Red Hat" } | Sort-Object OriginalFileName | ForEach-Object { "{0,-14} {1,-12} {2}" -f (Split-Path $_.OriginalFileName -Leaf), $_.ClassName, $_.Version } | Out-String;
      "--- Guest agent service";
      Get-Service QEMU-GA -ErrorAction SilentlyContinue | Select-Object Name,Status | Format-Table -AutoSize | Out-String'
  else
    warn "Guest agent not running: install it with Install-VirtioWin.ps1 first."
  fi
}

# --- finalize helpers --------------------------------------------------------

# Abort unless Windows already has the VirtIO driver identified by $1 staged
# in its driver store (otherwise switching the hardware would break the guest).
require_guest_driver() {
  local name=$1 answer
  answer=$(guest_ps "if (pnputil /enum-drivers | Select-String -SimpleMatch '$name') { 'yes' } else { 'no' }") \
    || die "Could not query the guest (see warning above); retry once the guest is idle."
  [[ $answer == *yes* ]] \
    || die "Windows has no '$name' driver yet. Run Install-VirtioWin.ps1 in the guest first."
}

switch_nic() {
  local net model rest
  net=$(vm_conf_value net0)
  [[ -n $net ]] || die "VM has no net0 interface."
  model=${net%%=*}
  if [[ $model == virtio ]]; then log "net0 already uses virtio."; return; fi
  require_guest_driver "netkvm.inf"
  rest=${net#*=}                       # MAC address followed by other options
  log "Changing net0 model $model -> virtio (MAC and options preserved)"
  run qm set "$VMID" --net0 "virtio=$rest"
}

switch_vga() {
  local vga
  vga=$(vm_conf_value vga)
  if [[ $vga == virtio* ]]; then log "Display adapter already virtio."; return; fi
  require_guest_driver "viogpudo.inf"
  log "Changing the display adapter to virtio"
  run qm set "$VMID" --vga virtio
}

# Determine the boot disk key (e.g. sata0) from the `boot: order=` option.
boot_disk_key() {
  local order first
  order=$(vm_conf_value boot)
  order=${order#order=}
  first=${order%%;*}
  [[ -n $first ]] || die "Cannot determine the boot device (no 'boot: order=' in the config)."
  echo "$first"
}

# Find the first free scsiN slot.
free_scsi_slot() {
  local conf n
  conf=$(qm config "$VMID")
  for n in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    grep -q "^scsi$n:" <<<"$conf" || { echo "scsi$n"; return 0; }
  done
  die "No free scsi slot."
}

# Make sure the vioscsi driver is actually LOADED by Windows (not just staged).
# A staged-but-never-loaded driver is the classic cause of the
# INACCESSIBLE_BOOT_DEVICE blue screen after changing the disk bus. We force
# the load by hot-adding a tiny temporary VirtIO SCSI disk and rebooting once.
# Returns 0 when a SCSI controller driven by vioscsi is present and healthy,
# 1 when it is not, and 2 when the guest could not be queried at all.
# (Single quotes are intentional: the text is PowerShell, not shell.)
# shellcheck disable=SC2016
vioscsi_loaded() {
  local out
  out=$(guest_ps 'Get-CimInstance Win32_SCSIController | Where-Object { $_.DriverName -eq "vioscsi" -and $_.Status -eq "OK" } | ForEach-Object { "loaded" }') \
    || return 2
  [[ $out == *loaded* ]]
}

ensure_vioscsi_loaded() {
  local rc=0
  vioscsi_loaded || rc=$?
  [[ $rc -ne 2 ]] || die "Could not query the guest to check the vioscsi driver."
  if [[ $rc -eq 0 ]]; then
    log "The vioscsi driver is already loaded in the guest."
    return
  fi
  local slot storage
  storage=$(vm_conf_value "$(boot_disk_key)"); storage=${storage%%:*}
  slot=$(free_scsi_slot)
  log "Forcing the vioscsi driver to load with a temporary 1 GiB disk on $slot ($storage)"
  run qm set "$VMID" --"$slot" "$storage:1"
  run qm reboot "$VMID" --timeout 300
  if [[ $DRY_RUN -eq 0 ]]; then
    sleep 30; wait_agent 900
    vioscsi_loaded || die "vioscsi is still not loaded (or the guest could not be queried) after the reboot; the temporary disk $slot was kept for inspection."
  fi
  # Remove the temporary disk (first detach, then destroy the now-unused volume).
  run qm set "$VMID" --delete "$slot"
  if [[ $DRY_RUN -eq 0 ]]; then
    local unused
    unused=$(qm config "$VMID" | sed -n 's/^\(unused[0-9]*\): .*/\1/p' | tail -n1)
    [[ -z $unused ]] || qm set "$VMID" --delete "$unused"
  fi
}

switch_disk() {
  local key conf_line volid opts newslot order
  key=$(boot_disk_key)
  case $key in
    scsi*|virtio*) log "Boot disk ($key) is already on a VirtIO bus."; return ;;
    ide*|sata*) ;;
    *) die "Unsupported boot device '$key'." ;;
  esac
  conf_line=$(vm_conf_value "$key")
  volid=${conf_line%%,*}
  opts=${conf_line#*,}; [[ $opts == "$conf_line" ]] && opts=""

  agent_up || die "The guest agent must be running for --disk."
  require_guest_driver "vioscsi.inf"
  confirm "Switch boot disk $key ($volid) to VirtIO SCSI? The VM will be rebooted and then shut down."

  local snap=""
  if [[ $DO_SNAPSHOT -eq 1 ]]; then
    snap="virtio-pre-$(date +%Y%m%d-%H%M%S)"
    log "Taking snapshot $snap (rollback: qm rollback $VMID $snap)"
    run qm snapshot "$VMID" "$snap" --description "Before VirtIO disk migration"
  fi

  ensure_vioscsi_loaded

  log "Shutting down VM $VMID"
  run qm shutdown "$VMID" --timeout 300
  [[ $DRY_RUN -eq 1 ]] || while [[ $(qm status "$VMID") != "status: stopped" ]]; do sleep 3; done

  # Keep user options (cache, backup, ...) except the size and media keys; add
  # discard (TRIM on thin storage) and iothread (one I/O thread per disk).
  opts=$(tr ',' '\n' <<<"$opts" | grep -Ev '^(size|media|discard|iothread)=' | paste -sd, - || true)
  newslot=$(free_scsi_slot)
  log "Moving $volid from $key to $newslot"
  # Read the boot order BEFORE detaching the disk: Proxmox silently removes a
  # detached device from "boot: order=", so reading it afterwards would lose
  # the entry and leave the VM without a bootable disk.
  order=$(vm_conf_value boot); order=${order#order=}
  order=$(sed -E "s/(^|;)$key(;|$)/\1$newslot\2/" <<<"$order")

  run qm set "$VMID" --delete "$key"
  run qm set "$VMID" --"$newslot" "$volid,discard=on,iothread=1${opts:+,$opts}"
  run qm set "$VMID" --boot "order=$order"

  log "Starting VM $VMID"
  run qm start "$VMID"
  if [[ $DRY_RUN -eq 0 ]]; then
    # If Windows cannot boot from the new bus (typically INACCESSIBLE_BOOT_DEVICE
    # or an automatic-repair loop) the agent never answers: tell the user how
    # to go back instead of leaving a bare timeout message.
    ( wait_agent 900 ) 2>/dev/null || die "The guest did not come back after the disk change. Check the VM console, then roll back: qm stop $VMID; qm rollback $VMID ${snap:-<snapshot>}; qm start $VMID"
    guest_ps 'Get-Disk | Select-Object Number,FriendlyName,BusType,Size | Format-Table -AutoSize | Out-String'
  fi
  log "Done. If the guest fails to boot: stop it, then 'qm rollback $VMID <snapshot>'."
}

cmd_finalize() {
  [[ $DO_NIC -eq 1 || $DO_VGA -eq 1 || $DO_DISK -eq 1 ]] \
    || die "Nothing to do: pass at least one of --nic, --vga, --disk."
  # NIC and VGA changes are applied to the configuration immediately and take
  # effect at the next VM (re)start. Do them before the disk step, whose
  # reboot/shutdown/start cycle will then also activate them.
  agent_up || die "The guest agent must be running (install it with Install-VirtioWin.ps1)."
  [[ $DO_NIC  -eq 1 ]] && switch_nic
  [[ $DO_VGA  -eq 1 ]] && switch_vga
  [[ $DO_DISK -eq 1 ]] && switch_disk
  if [[ $DO_DISK -eq 0 ]]; then
    log "Restart the VM (full stop/start) for the NIC/VGA changes to take effect."
  fi
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

[[ $# -ge 1 ]] || { usage; exit 1; }
case $1 in
  latest|prepare|status|finalize) COMMAND=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown command: $1" ;;
esac

while [[ $# -gt 0 ]]; do
  case $1 in
    --vmid)        VMID=${2:?--vmid needs a value}; shift 2 ;;
    --storage)     STORAGE=${2:?--storage needs a value}; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    --installer-iso) INSTALLER_ISO=1; shift ;;
    --nic)         DO_NIC=1; shift ;;
    --vga)         DO_VGA=1; shift ;;
    --disk)        DO_DISK=1; shift ;;
    --no-snapshot) DO_SNAPSHOT=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1" ;;
  esac
done

need_cmd curl
if [[ $COMMAND != latest ]]; then
  need_cmd qm; need_cmd pvesm; need_cmd python3
  [[ -n $VMID ]] || die "--vmid is required for '$COMMAND'."
  qm status "$VMID" >/dev/null 2>&1 || die "VM $VMID does not exist on this node."
fi

"cmd_$COMMAND"

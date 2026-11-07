# qemu-win-virtio

Automate the installation of the **VirtIO drivers** and the **QEMU guest agent**
in a Windows virtual machine running on **Proxmox VE** (QEMU/KVM), and then move
the VM's virtual hardware (network card, display adapter, boot disk) from
emulated devices to VirtIO, safely.

This is typically needed after a physical-to-virtual (P2V) migration or after
importing a Windows VM from another hypervisor: Windows boots on emulated
hardware (SATA disk, e1000e network card) and has no VirtIO drivers yet.

The repository contains two scripts that work together:

| Script | Runs on | Purpose |
| --- | --- | --- |
| [`proxmox/proxmox-virtio-win.sh`](proxmox/proxmox-virtio-win.sh) | Proxmox VE host (bash, root) | Downloads the newest virtio-win ISO, attaches it to the VM, enables the guest agent option, then later switches NIC / display / disk to VirtIO. |
| [`windows/Install-VirtioWin.ps1`](windows/Install-VirtioWin.ps1) | Windows guest (PowerShell 5.1+, Administrator) | Stages all VirtIO drivers in the driver store and installs the VirtIO guest tools including the QEMU guest agent. |

Both scripts are heavily commented; reading them top to bottom is the best way
to understand or modify them.

## How it works

```
 Proxmox host                                   Windows guest
 ------------                                   -------------
 1. proxmox-virtio-win.sh prepare --vmid N
      - newest ISO from fedorapeople.org
      - attached as a CD-ROM, agent=1
                                                2. Install-VirtioWin.ps1
                                                     - drivers staged (pnputil)
                                                     - guest tools + QEMU-GA
                                                3. reboot the guest
 4. proxmox-virtio-win.sh finalize --vmid N --nic --vga --disk
      - snapshot, load check, disk moved SATA -> VirtIO SCSI
```

### Which ISO is used?

`proxmox-virtio-win.sh` reads the directory listing of
<https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/>,
sorts the `virtio-win-X.Y.Z-R/` directories with a natural version sort and
picks the newest one **whose ISO actually exists** (a release directory can
appear before its files are published). The ISO is stored on the Proxmox ISO
storage as `virtio-win-X.Y.Z.iso`; an already downloaded ISO of the right size
is reused, and interrupted downloads are resumed.

Integrity: the download uses HTTPS and the file size is checked against the
server's `Content-Length`. Upstream publishes no checksum for the ISO in that
directory, so the script prints the SHA-256 for your records. The drivers inside
are signed by Microsoft (WHQL) / Red Hat.

## Requirements

* Proxmox VE 8 or 9, commands run as `root` on the node that hosts the VM.
  Needs `curl` and `python3` (both present on a standard install).
* A Windows VM (Windows 7 / Server 2008 R2 up to Windows 11 / Server 2025,
  x86, x64 or ARM64) that boots and where you have Administrator rights
  (console, RDP, ...).
* For `status` and `finalize`: the QEMU guest agent must be running in the
  guest (installed by `Install-VirtioWin.ps1`).

Tested on Proxmox VE 9.2 with Windows Server 2025 guests:

* `prepare`, `status`, `--installer-iso` and `Install-VirtioWin.ps1`: validated
  on two VMs (a P2V-migrated server and a Hyper-V import).
* Disk bus change (`finalize --disk`): the manual procedure it automates worked
  on the first VM (a P2V-migrated server). On the second VM (a Hyper-V import that itself
  runs Hyper-V/Docker) Windows did **not** boot from the VirtIO SCSI disk (it fell
  into the recovery environment) and the VM was rolled back to the snapshot taken
  by the script, which restored it intact. Root cause not determined yet, so treat
  `--disk` as the delicate step: keep the snapshot, watch the console, use `--dry-run` first.

## Step by step

### 1. On the Proxmox host: prepare the VM

```bash
git clone https://github.com/sctg-development/qemu-win-virtio.git
cd qemu-win-virtio/proxmox
./proxmox-virtio-win.sh prepare --vmid 100          # add --storage NAME if your ISOs are not on "local"
```

Use `--dry-run` first if you want to see the `qm` commands without running
them. `./proxmox-virtio-win.sh latest` only prints which ISO would be used.

#### No network, no RDP, no agent? Use the helper ISO

If you cannot reach the guest at all (typical right after a migration: no
network driver, RDP unreachable), let `prepare` build a small extra CD-ROM that
contains the installer and a launcher:

```bash
./proxmox-virtio-win.sh prepare --vmid 103 --installer-iso
qm stop 103 && qm start 103      # IDE/SATA CD-ROMs are not hot-pluggable
```

Open the Proxmox web console of the VM, sign in, open the CD-ROM labelled
`VIRTIO_INSTALLER` and double-click `Install-VirtioWin.cmd`: it elevates itself,
bypasses the execution policy for that single process and runs the installer.
(`xorriso`, `genisoimage` or `mkisofs` must be installed on the host.)

### 2. In the Windows guest: install drivers and agent

Copy `windows/Install-VirtioWin.ps1` into the guest (RDP clipboard, a shared
folder, `Invoke-WebRequest` from the raw GitHub URL...). Open **PowerShell as
Administrator** and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-VirtioWin.ps1
```

#### About PowerShell permissions

* **Administrator rights are mandatory** (the script has `#Requires
  -RunAsAdministrator`): it installs drivers and a service.
* Windows blocks unsigned scripts by default (`Restricted` policy on clients,
  `RemoteSigned` on servers). The command above uses `-ExecutionPolicy Bypass`,
  which applies **only to that one process** and changes no system setting.
* If you prefer to change the policy for your session only:
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  .\Install-VirtioWin.ps1
  ```
* A file downloaded from the internet carries a "Mark of the Web" and may be
  refused even under `RemoteSigned`; remove it with `Unblock-File .\Install-VirtioWin.ps1`.

Useful options (see `Get-Help .\Install-VirtioWin.ps1 -Full`):

| Option | Meaning |
| --- | --- |
| `-IsoDriveLetter E` | Use this CD-ROM letter instead of auto-detecting the `virtio-win*` volume. |
| `-IsoPath C:\Temp\virtio-win.iso` | Mount an ISO file when no CD-ROM is attached. |
| `-Drivers vioscsi,viostor,NetKVM` | Stage only these driver folders. |
| `-SkipGuestTools` | Stage drivers only; do not install the guest tools / agent. |
| `-SkipDriverStaging` | Only run the guest tools installer. |
| `-TimeoutMinutes 30` | Time limit for the guest tools installer. |

The script is idempotent, writes a transcript under
`%ProgramData%\virtio-win-install\`, and exits with code `0` only if the
required drivers and the QEMU guest agent service are present. **Reboot the
guest afterwards.**

You can also run it without any guest login once an agent already runs, using
the host: `qm guest exec <vmid> -- powershell -ExecutionPolicy Bypass -File C:\path\Install-VirtioWin.ps1`.

### 3. On the host: check, then switch the hardware to VirtIO

```bash
./proxmox-virtio-win.sh status   --vmid 100                  # what Windows sees
./proxmox-virtio-win.sh finalize --vmid 100 --nic --vga --disk
```

`finalize` flags (combine freely, at least one is required):

* `--nic` &mdash; `net0` model becomes `virtio`; the MAC address and options are kept.
* `--vga` &mdash; display adapter becomes `virtio`.
* `--disk` &mdash; moves the **boot disk** from IDE/SATA to VirtIO SCSI:
  1. checks that the `vioscsi` driver is staged in Windows,
  2. takes a snapshot `virtio-pre-<date>` (skip with `--no-snapshot`, not recommended),
  3. makes sure Windows has actually **loaded** `vioscsi` by hot-adding a temporary
     1 GiB VirtIO disk and rebooting once (a driver that is staged but never loaded
     is the classic cause of the `INACCESSIBLE_BOOT_DEVICE` blue screen),
  4. shuts the VM down, re-attaches the same volume as `scsiN` with
     `discard=on,iothread=1`, fixes the boot order, starts the VM and prints the
     disk bus type seen by Windows.

If the guest does not boot after `--disk`, stop it and roll back:

```bash
qm stop 100 && qm rollback 100 virtio-pre-YYYYMMDD-HHMMSS
```

Delete the snapshot once you are satisfied (`qm delsnapshot 100 <name>`): on thin
storage it keeps consuming space as the disk changes. `--yes` skips the
confirmation prompt, `--dry-run` prints the commands without running them.

Network and display changes take effect at the next full stop/start of the VM
(`--disk` does that for you). When the NIC model changes, Windows sees a new
adapter: static IP settings of the old adapter are not carried over automatically.

## Installing a new VM directly on VirtIO (integrated ISO)

For a **new** VM you can skip the migration steps altogether: build a Windows
installation ISO that already contains the VirtIO drivers.

1. In any Windows machine, as Administrator, with the virtio-win ISO attached and the
   `boot.wim` / `install.wim` of the Windows ISO copied to a local folder:
   ```powershell
   .\windows\Add-VirtioDriversToWim.ps1 -DriverRoot E:\ -BootWim C:\iso\boot.wim -InstallWim C:\iso\install.wim
   ```
   Both images of `boot.wim` (WinPE and Setup) and all images of `install.wim` get the
   drivers (`-InstallIndex 1` limits it to one edition, which is much faster). A few
   packages (for example `smbus`) are refused by WinPE; the script warns and goes on.
2. Put the modified WIM files back into the `sources` folder of the extracted ISO and
   rebuild it. `install.wim` is larger than 4 GiB, so the ISO needs UDF:
   ```bash
   genisoimage -udf -allow-limited-size -iso-level 3 -allow-lowercase -relaxed-filenames \
     -V WIN2025_VIRTIO -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
     -eltorito-alt-boot -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
     -o Server2025-virtio.iso tree/
   ```
   (`-e` marks the second El Torito entry as UEFI. `xorriso -as mkisofs` has no UDF.)
3. Create the VM with `scsihw virtio-scsi-single`, a VirtIO SCSI disk, a `virtio` NIC and
   `--vga virtio`; Setup sees the disk and the network card without a driver prompt.
   [`examples/windows-server-2025-unattended`](examples/windows-server-2025-unattended)
   contains an `autounattend.xml` (Server Core, GPT) and first-boot scripts that install
   the guest agent, enable Remote Desktop, add Hyper-V/Containers and Docker CE. Put them
   on a small extra ISO (`genisoimage -J -R -V UNATTEND`).

With the integrated ISO, `DriverPaths` entries in `autounattend.xml` are unnecessary. In
one test Setup stopped with error `0x80070103 - 0x40031` while they were present and
succeeded once they were removed (the cause was not isolated further).

## Verifying VirtIO is really used

In the guest, as Administrator:

```powershell
Get-Disk | Select-Object Number,FriendlyName,BusType     # SAS/SCSI with vioscsi = VirtIO
Get-CimInstance Win32_SCSIController | Select-Object Name,DriverName,Status
Get-NetAdapter | Select-Object Name,InterfaceDescription # "Red Hat VirtIO Ethernet Adapter"
Get-Service QEMU-GA
```

A VirtIO SCSI disk is reported with `BusType SAS` and the controller named
*Red Hat VirtIO SCSI pass-through controller* (driver `vioscsi`); an emulated
SATA disk shows as `IDE`/`ATA`. On the host, `status` prints the same data.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Guest agent did not answer` | The agent needs `agent=1` on the VM **and** a reboot after installation. Check `qm config <vmid> \| grep agent` and the `QEMU-GA` service. |
| `virtio-win media not found` | The CD-ROM is not attached or has no drive letter: use `prepare` again, or pass `-IsoPath` / `-IsoDriveLetter`. |
| Blue screen `INACCESSIBLE_BOOT_DEVICE` after the disk change | `vioscsi` was not loaded. Roll back to the snapshot and re-run `finalize --disk` (it forces the driver to load first). |
| VirtIO SCSI controller shows a problem code 12 after hot-add | Normal until the guest is rebooted; `finalize --disk` reboots automatically. |
| No network after `--nic` | Windows created a new adapter: re-apply the IP configuration or DHCP on it. |
| Orphan "HPE Smart Array" or other old devices in Device Manager | Leftovers of the previous physical hardware; harmless, can be removed. |

## Maintenance notes

* All upstream URLs live in constants at the top of `proxmox-virtio-win.sh`
  (`ARCHIVE_URL`).
* The mapping Windows build number &rarr; ISO folder (`w10`, `w11`, `2k19`,
  `2k22`, `2k25`, ...) is in `Get-VirtioOsFolder` in the PowerShell script; add
  new rows there when Microsoft ships a new Windows Server.
* Lint the bash script with `shellcheck -x proxmox/proxmox-virtio-win.sh`.

## License

[MIT](LICENSE)

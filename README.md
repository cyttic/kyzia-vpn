# kyzia-vpn

Self-hosted **AmneziaWG** VPN on an Azure VM. Connect from anywhere and your
internet traffic exits from the VM's country — useful for privacy, accessing
geo-restricted services, and bypassing network censorship.

AmneziaWG is a WireGuard fork that **obfuscates the handshake** (junk packets +
randomized magic headers) so DPI systems like Russia's TSPU can't fingerprint it
as a VPN. It's as fast as WireGuard with a near-identical config — just extra
obfuscation params that the server and every client share.

> **Client app:** you must use an **AmneziaWG-capable** client — the *AmneziaWG*
> app ([iOS](https://apps.apple.com/app/amneziawg/id6478942365) /
> [Android](https://play.google.com/store/apps/details?id=org.amnezia.awg)), the
> Amnezia VPN client, or `awg-quick` on Linux. The **stock WireGuard app will not
> work** — it doesn't understand the obfuscation params.

```
  [ your phone/laptop ]  --encrypted-->  [ Azure VM (e.g. Germany) ]  -->  internet
   (in country A)                          (exit IP = country B)
```

---

## Prerequisites

- An Azure Linux VM (Ubuntu 22.04/24.04 recommended) — you already have this.
- SSH access to the VM.
- `az` CLI logged in locally (`az login`) to open the firewall port.

## Option A — Deploy from GitHub Actions (SSH)

The `Deploy WireGuard VPN` workflow SSHes into the VM and runs the setup/add-client
scripts, then returns the client config as a downloadable artifact.

### One-time: add three repo secrets
`Settings → Secrets and variables → Actions → New repository secret`

| Secret name     | Value                                            |
|-----------------|--------------------------------------------------|
| `AZURE_USER`    | SSH username on the VM (e.g. `azureuser`)         |
| `AZURE_ADDRESS` | VM address / public IP (`20.197.16.237`)          |
| `AZURE_SSH_KEY` | the **private** SSH key that logs into the VM     |

Requirements:
- The VM must allow inbound **SSH (TCP 22)** so the GitHub runner can reach it.
- **UDP 443** (the deploy's default port) must be open in the NSG — a **one-time**
  step: run `azure/open-ports.sh` yourself (see Option B, step 2) or open it in the
  Azure Portal. After that, every push deploys automatically.
- The SSH user needs passwordless `sudo` (Azure's default `azureuser` has it).

> Keep this repo **private** — workflow artifacts contain a client private key.

### Run it
Just **push to `main`** — the deploy runs automatically on UDP 443 and refreshes the
`phone` client. Or trigger it manually: `Actions → Deploy AmneziaWG VPN → Run
workflow`, set the device name / port, then run. When it finishes, download the
**`wg-<name>`** artifact — that's your `.conf`. Import it into the **AmneziaWG** app
(not stock WireGuard), toggle on, then **delete the run** (the artifact holds a
private key).

Re-running (including every push) **keeps an existing device's config valid** — it
won't regenerate keys for a name that already exists. To roll new keys for a device,
run the workflow manually with **`force = true`** (or `FORCE=1` for the script). A new
device name always adds a new client.

---

## Option B — Manual setup (3 steps)

### 1. Install the server (on the VM)
Copy this repo to the VM (`scp -r . user@vm:~/kyzia-vpn`), then:
```bash
sudo WG_PORT=443 bash server/setup-server.sh   # 443 matches the automatic deploy
```
Note the **public IP** and **listen port** it prints at the end.

### 2. Open the port in Azure (locally)
AmneziaWG needs its UDP port allowed inbound in the VM's Network Security Group.
This is a **one-time** step; the default deploy port is **443**:
```bash
az network nsg list -o table                       # find your NSG name
RG=<resource-group> NSG=<nsg-name> bash azure/open-ports.sh   # opens UDP 443
```
(Or do it in the Portal: VM → Networking → Add inbound port rule → UDP, port 443.)

### 3. Add a client (on the VM)
```bash
sudo bash client/add-client.sh phone
```
This prints a **QR code** — scan it in the **AmneziaWG** app (iOS/Android), or copy
the generated `clients/phone.conf` to a desktop AmneziaWG / Amnezia VPN client.
Toggle on. Done.

Verify your exit IP changed: open https://ipinfo.io — it should show the VM's country.

---

## Censorship bypass — read this

Your stated goal is getting around censorship (Russia / TSPU). This project now
runs **AmneziaWG**, which obfuscates the handshake so DPI can't fingerprint it as
WireGuard. That defeats the fingerprint-based blocking that stops plain WireGuard.
Still worth knowing:

- **Run it on UDP 443.** Re-deploy with `WG_PORT=443` so the traffic also *looks*
  like QUIC/HTTPS on a rarely-filtered port. Obfuscation + 443 is the strong combo.
  (Remember to open UDP 443 in the NSG, not 51820 — see `azure/open-ports.sh`.)
- **The obfuscation params are randomized per deploy** and stored server-side in
  `/etc/amnezia/amneziawg/params.env`. Server and every client share the same values
  (`add-client.sh` reads them automatically), so your signature is unique to you.
- Keep `PersistentKeepalive = 25` (already set) so the tunnel survives strict NAT.
- **If a region's TSPU still catches AmneziaWG**, the next escalation is
  **VLESS + XTLS-Reality** (Xray / sing-box) — traffic disguised as a real TLS
  handshake to a borrowed SNI. Strongest option, but a different protocol/stack
  (see TODO below).

> ⚠️ Bypassing censorship may carry legal/personal risk depending on the country you
> connect *from*. Understand your local situation before relying on this.

---

## Costs

- VM: a `B1s` runs ~\$8–15/month.
- **Outbound bandwidth is metered** by Azure (~first 100 GB/mo free, then ~\$0.05–0.09/GB).
  Heavy video streaming can add up — watch your data.

## Security notes

- Private keys and the obfuscation `params.env` live in `/etc/amnezia/amneziawg/`
  on the VM, and each client `.conf` holds a private key.
  **Never commit them** — `.gitignore` already blocks `*.key` and `clients/*.conf`.
- One config per device. To revoke a device, delete its `[Peer]` block from
  `/etc/amnezia/amneziawg/awg0.conf` and run `sudo systemctl restart awg-quick@awg0`.

## Layout

```
server/setup-server.sh   # install + configure AmneziaWG on the VM
client/add-client.sh     # generate a new device config + QR code
azure/open-ports.sh      # open the UDP port in the Azure NSG (az CLI)
```

## TODO / possible next steps

- [x] AmneziaWG migration for stronger censorship resistance
- [ ] Move listen port to UDP 443 (re-deploy with `WG_PORT=443` + open it in the NSG)
- [ ] VLESS + XTLS-Reality fallback if AmneziaWG gets blocked in a region
- [ ] Optional: Terraform to provision the VM from scratch

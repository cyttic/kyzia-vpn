# kyzia-vpn

Self-hosted **WireGuard** VPN on an Azure VM. Connect from anywhere and your
internet traffic exits from the VM's country — useful for privacy, accessing
geo-restricted services, and bypassing network censorship.

```
  [ your phone/laptop ]  --encrypted-->  [ Azure VM (e.g. Germany) ]  -->  internet
   (in country A)                          (exit IP = country B)
```

---

## Prerequisites

- An Azure Linux VM (Ubuntu 22.04/24.04 recommended) — you already have this.
- SSH access to the VM.
- `az` CLI logged in locally (`az login`) to open the firewall port.

## Setup (3 steps)

### 1. Install the server (on the VM)
Copy this repo to the VM (`scp -r . user@vm:~/kyzia-vpn`), then:
```bash
sudo bash server/setup-server.sh
```
Note the **public IP** and **listen port** it prints at the end.

### 2. Open the port in Azure (locally)
WireGuard needs its UDP port allowed inbound in the VM's Network Security Group:
```bash
az network nsg list -o table                       # find your NSG name
RG=<resource-group> NSG=<nsg-name> WG_PORT=51820 bash azure/open-ports.sh
```
(Or do it in the Portal: VM → Networking → Add inbound port rule → UDP, port 51820.)

### 3. Add a client (on the VM)
```bash
sudo bash client/add-client.sh phone
```
This prints a **QR code** — scan it in the WireGuard app (iOS/Android), or copy the
generated `clients/phone.conf` to a desktop WireGuard client. Toggle on. Done.

Verify your exit IP changed: open https://ipinfo.io — it should show the VM's country.

---

## Censorship bypass — read this

Your stated goal is getting around censorship. Be aware:

- **Plain WireGuard is fast but not stealthy.** Its handshake has a recognizable
  signature. Basic geo-blocks and lightweight filtering won't stop it, but a serious
  DPI-based censor (GFW-class) can detect and block/throttle it.
- **Cheap hardening that helps:**
  - Run WireGuard on **UDP 443** instead of 51820 (looks like QUIC/HTTPS, less likely
    to be blocked, and 443 is rarely filtered). Re-run setup with `WG_PORT=443`.
  - Keep `PersistentKeepalive = 25` (already set) so the tunnel survives strict NAT.
- **If plain WG gets blocked, escalate to obfuscation:**
  - **AmneziaWG** — a WireGuard fork that masks the handshake to defeat DPI. Same
    speed, near-identical config. This is the recommended next step and the project
    is structured to migrate to it (see TODO below).
  - **Shadowsocks / Outline** — disguises traffic as ordinary TLS; strongest against
    aggressive censors, but it's a different protocol than WireGuard.

> ⚠️ Bypassing censorship may carry legal/personal risk depending on the country you
> connect *from*. Understand your local situation before relying on this.

---

## Costs

- VM: a `B1s` runs ~\$8–15/month.
- **Outbound bandwidth is metered** by Azure (~first 100 GB/mo free, then ~\$0.05–0.09/GB).
  Heavy video streaming can add up — watch your data.

## Security notes

- Private keys live in `/etc/wireguard/` on the VM and inside each client `.conf`.
  **Never commit them** — `.gitignore` already blocks `*.key` and `clients/*.conf`.
- One config per device. To revoke a device, delete its `[Peer]` block from
  `/etc/wireguard/wg0.conf` and run `sudo systemctl restart wg-quick@wg0`.

## Layout

```
server/setup-server.sh   # install + configure WireGuard on the VM
client/add-client.sh     # generate a new device config + QR code
azure/open-ports.sh      # open the UDP port in the Azure NSG (az CLI)
```

## TODO / possible next steps

- [ ] AmneziaWG migration path for stronger censorship resistance
- [ ] Optional: move listen port to UDP 443
- [ ] Optional: Terraform to provision the VM from scratch

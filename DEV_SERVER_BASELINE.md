# CMDS_WEB Dev Server Baseline
**Server:** 192.168.110.118 — Rocky Linux 10.1 (Red Quartz)  
**Last Updated:** 2026-06-13  
**Purpose:** Reference baseline for comparing against new test/production installs

---

## OS & Kernel

- **OS:** Rocky Linux 10.1 (Red Quartz) — `platform:el10`
- **Kernel versions present:** 6.12.0-124.55, 6.12.0-124.56, 6.12.0-211.18 (el10_2 — updated beyond base 10.1)
- **Python:** 3.12 (`/usr/local/lib/python3.12/`)
- **SELinux:** Enforcing, targeted policy

---

## Python Packages (pip — clean, never thrashed)

| Package | Version |
|---|---|
| fastapi | 0.136.1 |
| starlette | 1.0.0 |
| uvicorn | 0.46.0 |
| python-multipart | 0.0.27 |
| python-pam | 2.0.2 |
| pydantic | 2.13.4 |
| anyio | 4.13.0 |
| h11 | 0.16.0 |
| click | 8.3.3 |
| pip | 26.1 |

**NOTE:** aiofiles, meraki, python-dotenv are in requirements.txt but NOT installed on dev. The app runs fine without them — do not install them unless needed.

---

## Apache Configuration

### MPM
`mpm_event` — loaded via `00-mpm.conf` (default for Rocky 10)

### `/etc/httpd/conf.d/cmds-go.conf` (working reference)
```apache
<VirtualHost *:80>
    DocumentRoot "/opt/cmds-go/ui"
    LimitRequestBody 2147483648

    # Disable mod_reqtimeout body limit — allows large IOS-XE uploads (1GB+)
    # over slow/routed paths without Apache killing the connection mid-transfer.
    # (Default body=20,MinRate=500 drops connections on I226-V NIC + inter-VLAN paths)
    RequestReadTimeout body=0

    <Directory "/opt/cmds-go/ui">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /cmds-docs /opt/cmds-go/docs
    <Directory "/opt/cmds-go/docs">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    DirectoryIndex index.html

    ProxyRequests Off
    ProxyPreserveHost On

    ProxyPass        /api/login http://127.0.0.1:8000/api/login
    ProxyPassReverse /api/login http://127.0.0.1:8000/api/login

    ProxyPass        /api/auth/check http://127.0.0.1:8000/api/auth/check
    ProxyPassReverse /api/auth/check http://127.0.0.1:8000/api/auth/check

    ProxyPass        /api/ http://127.0.0.1:8000/
    ProxyPassReverse /api/ http://127.0.0.1:8000/

    ErrorLog /var/log/httpd/cmds-go-error.log
    CustomLog /var/log/httpd/cmds-go-access.log combined
</VirtualHost>
```

### `/etc/httpd/conf.d/00-sendfile.conf`
```
EnableSendfile Off
```
(Overrides `EnableSendfile on` in httpd.conf — required for NFS/network filesystems)

### `/etc/httpd/conf.d/tftp-images.conf`
```apache
Alias /images /var/lib/tftpboot/images
<Directory "/var/lib/tftpboot/images">
   Options Indexes FollowSymLinks
   AllowOverride None
   Require all granted
</Directory>
```

### No `/etc/httpd/conf.d/reqtimeout.conf` (not present on dev, not needed)

### All proxy modules loaded (default Rocky 10 `00-proxy.conf`)
Full list including: proxy_module, proxy_http_module, proxy_balancer_module, proxy_ajp_module, proxy_fcgi_module, proxy_wstunnel_module, lbmethod_* modules. **Do NOT overwrite 00-proxy.conf in the installer.**

### Do NOT install `mod_ssl` or `mod_proxy_html`
- `mod_ssl` drops `/etc/httpd/conf.d/ssl.conf` which requires a TLS cert that doesn't exist → Apache fails to start on fresh installs. CMDS runs HTTP-only; mod_ssl is not needed.
- `mod_proxy_html` is already loaded by the default `00-proxy.conf`. Installing it as a separate package causes `AH01574: module proxy_html_module is already loaded, skipping` warnings. Not needed.
- Installer package list: `httpd` only — all required proxy modules come with it.

---

## SELinux Custom Contexts (`/etc/selinux/targeted/contexts/files/file_contexts.local`)

```
/var/lib/tftpboot/images(/.*)?    system_u:object_r:public_content_rw_t:s0
/opt/cmds-go/ui(/.*)?             system_u:object_r:httpd_sys_content_t:s0
```

The installer sets these via `semanage fcontext` + `restorecon`. These must be present for uploads to work correctly under SELinux enforcing.

### Booleans set by installer
- `httpd_can_network_connect = on` (required for Apache → uvicorn proxy)
- `tftp_anon_write = on`

---

## systemd Service (`/etc/systemd/system/cmds-go.service`)

```ini
[Unit]
Description=CMDS-go FastAPI Backend
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/cmds-go/api
ExecStart=/usr/local/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

## TFTP Images Directory

`/var/lib/tftpboot/images/` — working uploads confirmed:
- cat9k_iosxe.17.12.05.SPA.bin — 1.3 GB
- cat9k_iosxe.17.15.03.SPA.bin — 1.2 GB ✅
- cat9k_iosxe.17.18.03.SPA.bin — 1.2 GB
- cat9k_lite_iosxe.17.*.SPA.bin — 450–480 MB (lite images)

### Chunk temp directory
`/var/lib/tftpboot/images/.chunks/` — created at uvicorn startup by `main.py`. Holds in-flight upload chunks; auto-cleaned when each upload completes. SELinux context inherits `public_content_rw_t` from parent.

---

## Upload Architecture — Chunked HTTP (current)

### Why chunked upload

The original single-shot `POST /upload/iosxe` sent the entire file (1+ GB) as one HTTP request. This caused consistent failures at ~50% when uploading from a client on a different subnet or VLAN because:

1. A stateful firewall/router between the client and server tracks TCP sessions. During a large one-directional HTTP POST, the server sends zero data back for many minutes. The firewall sees the server→client direction as idle and kills the TCP session.
2. Intel I226-V NIC (found on Weidan and similar Alder Lake-N hardware) has hardware-enforced GRO/TSO offloading that cannot be disabled via `ethtool`. This causes bursty TCP receive patterns that exacerbate the stall window.
3. WebSocket uploads (e.g. Cockpit file browser) were unaffected because WebSocket sends frames in both directions, resetting the firewall's idle timer continuously.

### Diagnosis path
| Test | Result | Conclusion |
|---|---|---|
| curl loopback → uvicorn | ✅ works | uvicorn OK |
| curl loopback → Apache → uvicorn | ✅ works | Apache proxy OK |
| curl KVM host → VM external IP via Apache | ✅ 1 GB in 3s | server-side fine |
| Cockpit WebSocket upload from external | ✅ works | physical path fine |
| Browser POST upload from external subnet | ❌ dies at ~50% | firewall kills one-directional TCP |
| Browser POST upload on same subnet (NUC .119) | ✅ works | no inter-VLAN firewall in path |

macvtap → bridge change did **not** fix the issue. `RequestReadTimeout body=0` is a useful hardening addition but was **not** the root fix.

### The fix — `/upload/iosxe/chunk` endpoint

Each 10 MB chunk is a complete HTTP request/response cycle. The firewall sees normal bidirectional HTTP at all times. No single connection is ever open long enough to hit idle timeouts.

**Backend (main.py):**
- New endpoint: `POST /upload/iosxe/chunk`
- Accepts: `file`, `chunk_index`, `total_chunks`, `filename`, `upload_id` (Form fields)
- Writes each chunk to `/var/lib/tftpboot/images/.chunks/{upload_id}/chunk_{N:06d}`
- When `received == total_chunks`: assembles final file, removes temp dir
- Returns `{"status": "chunk_received"}` per chunk, `{"status": "complete", ...}` on last

**Frontend (app.js):**
- `uploadIOSXEImage()` splits the file into 10 MB slices using `File.slice()`
- Uploads each slice sequentially with `await fetch()`
- Progress bar advances per chunk
- On any chunk failure, reports which chunk failed with the HTTP error

---

## Root Cause History (Post-Mortems)

### Issue 1 — pip thrashing (original NUC test server, Session 1)
Pip downgrade/upgrade cycles (starlette 1.3.1 → 1.0.0 → 1.3.1 → 1.0.0) corrupted python-multipart's multipart parser. Uploads stalled before the FastAPI endpoint was reached. **Resolution:** fresh reinstall with no pip version changes.

### Issue 2 — upload stall at ~50% on inter-VLAN deployments (Session 2)
See "Upload Architecture" section above. **Resolution:** chunked upload. Weidan hardware with I226-V NIC was retired; Lenovo workstation with Realtek NIC used instead.

---

## Lessons / Rules for New Installs

1. **Never run pip downgrade/upgrade cycles** after initial install. If a package version needs changing, reinstall from scratch.
2. **Pin exact versions** in requirements.txt (not `>=`) to prevent drift between installs.
3. **Do not add `Timeout 3600`** to the VirtualHost — default 300s is fine on LAN.
4. **Do not overwrite `00-proxy.conf`** — use Rocky's default which includes all proxy modules.
5. **Do not install `mod_ssl` or `mod_proxy_html`** — mod_ssl breaks fresh installs (no cert), mod_proxy_html causes duplicate-load warnings. Neither is needed.
6. **Add `RequestReadTimeout body=0`** to the VirtualHost — prevents mod_reqtimeout from killing uploads on slow/routed paths.
7. **Use chunked upload** for all large file transfers. Never send multi-GB files as a single HTTP POST through an Apache reverse proxy.
8. **Remove debug print statements** from main.py (auth middleware, PAM debug, etc.) before shipping.
9. **Session never expires** (no timeout in ACTIVE_SESSIONS) — if the service restarts during an upload, session token is lost. Chunked upload mitigates this (each chunk re-presents the cookie), but long-term consider session persistence.
10. **`dnf upgrade` does not reboot** — the running kernel remains `el10_1` even after upgrading to 10.2. A reboot is required to run the new kernel. The installer should trigger a reboot after `run_system_upgrade()`.

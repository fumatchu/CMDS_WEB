#!/usr/bin/env python3
"""
Patches CMDS-GO to use chunked IOS-XE upload.

Run on the server as:
    python3 /tmp/patch_chunked_upload.py

Backups are written alongside the originals (.bak).
After patching: systemctl restart cmds-go
"""

import re
import shutil
from pathlib import Path

MAIN_PY = Path("/opt/cmds-go/api/main.py")
APP_JS  = Path("/opt/cmds-go/ui/app.js")

# ─────────────────────────────────────────────────────────────────────────────
# BACKUP
# ─────────────────────────────────────────────────────────────────────────────

shutil.copy(MAIN_PY, str(MAIN_PY) + ".bak")
shutil.copy(APP_JS,  str(APP_JS)  + ".bak")
print("[✓] Backups written (.bak)")


# ─────────────────────────────────────────────────────────────────────────────
# PATCH main.py
# ─────────────────────────────────────────────────────────────────────────────

src = MAIN_PY.read_text()
original_src = src

# 1. Add Form to fastapi imports
src = src.replace(
    "from fastapi import FastAPI, File, HTTPException, Request, UploadFile",
    "from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile",
    1,
)

# 2. Add CHUNK_TMP_DIR constant alongside UPLOAD_DIR
src = src.replace(
    'UPLOAD_DIR = Path("/var/lib/tftpboot/images")',
    'UPLOAD_DIR     = Path("/var/lib/tftpboot/images")\nCHUNK_TMP_DIR = Path("/var/lib/tftpboot/images/.chunks")',
    1,
)

# 3. Create CHUNK_TMP_DIR at startup alongside UPLOAD_DIR.mkdir
src = src.replace(
    "UPLOAD_DIR.mkdir(parents=True, exist_ok=True)",
    "UPLOAD_DIR.mkdir(parents=True, exist_ok=True)\nCHUNK_TMP_DIR.mkdir(parents=True, exist_ok=True)",
    1,
)

# 4. Inject chunk endpoint immediately after the existing single-shot endpoint
CHUNK_ENDPOINT = '''

# ============================================================
# IOS-XE IMAGE UPLOAD — CHUNKED (firewall-safe, bidirectional)
# Each 10 MB chunk is a short complete request/response cycle.
# Avoids stateful-firewall TCP-idle kills on long one-way POSTs.
# ============================================================


@app.post("/upload/iosxe/chunk")
async def upload_iosxe_chunk(
    file: UploadFile = File(...),
    chunk_index: int  = Form(...),
    total_chunks: int = Form(...),
    filename: str     = Form(...),
    upload_id: str    = Form(...),
):
    suffix = Path(filename).suffix.lower()
    if suffix not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Invalid file type")

    # Reject path-traversal attempts
    safe_name = Path(filename).name
    if not safe_name or safe_name != filename:
        raise HTTPException(status_code=400, detail="Invalid filename")

    chunk_dir = CHUNK_TMP_DIR / upload_id
    chunk_dir.mkdir(parents=True, exist_ok=True)

    chunk_path = chunk_dir / f"chunk_{chunk_index:06d}"
    with chunk_path.open("wb") as f:
        shutil.copyfileobj(file.file, f)

    received = len(list(chunk_dir.glob("chunk_*")))

    if received == total_chunks:
        destination = UPLOAD_DIR / safe_name
        with destination.open("wb") as out:
            for i in range(total_chunks):
                cf = chunk_dir / f"chunk_{i:06d}"
                with cf.open("rb") as inp:
                    shutil.copyfileobj(inp, out)
        shutil.rmtree(chunk_dir, ignore_errors=True)
        return {
            "status":   "complete",
            "filename": safe_name,
            "path":     str(destination),
        }

    return {
        "status":      "chunk_received",
        "chunk_index": chunk_index,
        "received":    received,
        "total":       total_chunks,
    }
'''

ANCHOR = '    return {"status": "success", "filename": filename, "path": str(destination)}'
if ANCHOR in src:
    src = src.replace(ANCHOR, ANCHOR + CHUNK_ENDPOINT, 1)
    print("[✓] main.py: chunk endpoint injected")
else:
    print("[✗] main.py: anchor not found — check manually")

if src != original_src:
    MAIN_PY.write_text(src)
    print("[✓] main.py written")
else:
    print("[!] main.py: no changes applied")


# ─────────────────────────────────────────────────────────────────────────────
# PATCH app.js  — replace uploadIOSXEImage with chunked fetch loop
# ─────────────────────────────────────────────────────────────────────────────

NEW_UPLOAD_FN = r"""async function uploadIOSXEImage() {

  const fileInput    = document.getElementById('iosxeFile');
  const status       = document.getElementById('uploadStatus');
  const progressFill = document.getElementById('uploadProgressFill');

  if (!fileInput.files.length) {
    status.innerHTML = `<div class="upload-error">Please select an image.</div>`;
    return;
  }

  const file        = fileInput.files[0];
  const CHUNK_SIZE  = 10 * 1024 * 1024; // 10 MB per chunk
  const totalChunks = Math.ceil(file.size / CHUNK_SIZE);
  const uploadId    = (typeof crypto.randomUUID === 'function')
    ? crypto.randomUUID()
    : Date.now().toString(36) + Math.random().toString(36).slice(2);

  progressFill.style.width = '0%';
  status.innerHTML = `<div class="upload-progress">Uploading image... 0%</div>`;

  for (let i = 0; i < totalChunks; i++) {

    const start = i * CHUNK_SIZE;
    const end   = Math.min(start + CHUNK_SIZE, file.size);
    const chunk = file.slice(start, end);

    const formData = new FormData();
    formData.append('file',         new File([chunk], file.name));
    formData.append('chunk_index',  i);
    formData.append('total_chunks', totalChunks);
    formData.append('filename',     file.name);
    formData.append('upload_id',    uploadId);

    try {

      const response = await fetch('/api/upload/iosxe/chunk', {
        method: 'POST',
        body:   formData,
      });

      if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.detail || `HTTP ${response.status}`);
      }

      const percent = Math.round(((i + 1) / totalChunks) * 100);
      progressFill.style.width = `${percent}%`;
      status.innerHTML = `
        <div class="upload-progress">
          Uploading image... ${percent}%
        </div>
      `;

    } catch (err) {

      progressFill.style.width = '0%';
      status.innerHTML = `
        <div class="upload-error">
          Upload failed on chunk ${i + 1} of ${totalChunks}: ${err.message}
        </div>
      `;
      return;

    }

  }

  status.innerHTML = `
    <div class="upload-success">
      Upload complete: ${file.name}
    </div>
  `;
  progressFill.style.width = '100%';
  loadImageList();
  document.getElementById('dropZoneFile').innerHTML = '';
  fileInput.value = '';

}"""

js_src = APP_JS.read_text()

pattern = r'async function uploadIOSXEImage\(\) \{.*?xhr\.send\(formData\);\n\n\}'
replaced, n = re.subn(pattern, NEW_UPLOAD_FN.strip(), js_src, flags=re.DOTALL)

if n == 1:
    APP_JS.write_text(replaced)
    print("[✓] app.js: uploadIOSXEImage replaced with chunked fetch loop")
else:
    print(f"[✗] app.js: pattern matched {n} times — check manually")

print()
print("Done. Run:  systemctl restart cmds-go")
print("Then reload the browser (hard refresh) and test the upload.")

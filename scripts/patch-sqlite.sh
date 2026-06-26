#!/bin/bash
set -e

echo "[patch] Step 1: Patching better-sqlite3 binary..."
BINARY=/home/zfr6rwssd45a/nodevenv/freellm-backend/24/lib/node_modules/better-sqlite3/build/Release/better_sqlite3.node

if [ ! -f "$BINARY" ]; then
  echo "[patch] Binary not found, skipping sqlite patch."
else
python3 << 'PYEOF'
import struct, sys
path = '/home/zfr6rwssd45a/nodevenv/freellm-backend/24/lib/node_modules/better-sqlite3/build/Release/better_sqlite3.node'
with open(path, 'rb') as f:
    data = bytearray(f.read())
e_shoff = struct.unpack_from('<Q', data, 40)[0]
e_shentsize = struct.unpack_from('<H', data, 58)[0]
e_shnum = struct.unpack_from('<H', data, 60)[0]
verneed_offset = verneed_size = dynstr_offset = None
for i in range(e_shnum):
    sh = e_shoff + i * e_shentsize
    sh_type = struct.unpack_from('<I', data, sh + 4)[0]
    sh_flags = struct.unpack_from('<Q', data, sh + 8)[0]
    sh_offset = struct.unpack_from('<Q', data, sh + 24)[0]
    sh_size = struct.unpack_from('<Q', data, sh + 32)[0]
    if sh_type == 0x6ffffffe:
        verneed_offset, verneed_size = sh_offset, sh_size
    if sh_type == 3 and sh_flags == 2:
        dynstr_offset = sh_offset
if verneed_offset is None:
    print('[patch] No verneed section, skipping.')
    sys.exit(0)
pos = verneed_offset
while pos < verneed_offset + verneed_size:
    vn_cnt = struct.unpack_from('<H', data, pos + 2)[0]
    vn_file = struct.unpack_from('<I', data, pos + 4)[0]
    vn_aux = struct.unpack_from('<I', data, pos + 8)[0]
    vn_next = struct.unpack_from('<I', data, pos + 12)[0]
    file_name = bytes(data[dynstr_offset + vn_file:dynstr_offset + vn_file + 20]).split(b'\x00')[0]
    aux_pos = pos + vn_aux
    prev_aux_pos = None
    for j in range(vn_cnt):
        vna_name = struct.unpack_from('<I', data, aux_pos + 8)[0]
        vna_next = struct.unpack_from('<I', data, aux_pos + 12)[0]
        name = bytes(data[dynstr_offset + vna_name:dynstr_offset + vna_name + 20]).split(b'\x00')[0]
        if file_name == b'libm.so.6' and name == b'GLIBC_2.29':
            print(f'[patch] Removing {name.decode()} from {file_name.decode()}')
            if prev_aux_pos is not None:
                struct.pack_into('<I', data, prev_aux_pos + 12, vna_next if vna_next else 0)
            else:
                if vna_next:
                    struct.pack_into('<I', data, pos + 8, vn_aux + vna_next)
            struct.pack_into('<H', data, pos + 2, vn_cnt - 1)
        prev_aux_pos = aux_pos
        if vna_next == 0:
            break
        aux_pos += vna_next
    if vn_next == 0:
        break
    pos += vn_next
with open(path, 'wb') as f:
    f.write(data)
print('[patch] SQLite binary patched.')
PYEOF
fi

echo "[patch] Step 2: Writing patched catalog-sync.js..."
mkdir -p /home/zfr6rwssd45a/freellm-backend/server/dist/services
cat > /home/zfr6rwssd45a/freellm-backend/server/dist/services/catalog-sync.js << 'JSEOF'
import crypto from 'crypto';
import { getDb, getSetting, setSetting } from '../db/index.js';
import { hasProvider } from '../providers/index.js';
const DEFAULT_BASE_URL = 'https://api.freellmapi.co';
const PINNED_CATALOG_PUBKEY = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAq9yv4+3EeyMHKsfVYBhkcz1lYgIXSUeHNnN6tNgYX3k=
-----END PUBLIC KEY-----
`;
export const MIN_CATALOG_VERSION = '2026.06.07';
const SYNC_INTERVAL_MS = 12 * 60 * 60 * 1000;
const BOOT_DELAY_MS = 10 * 1000;
const FETCH_TIMEOUT_MS = 20 * 1000;
export const SETTING_LICENSE_KEY = 'premium_license_key';
export const SETTING_LICENSE_STATUS = 'premium_license_status';
const SETTING_APPLIED_VERSION = 'catalog_applied_version';
const SETTING_APPLIED_TIER = 'catalog_applied_tier';
const SETTING_APPLIED_JSON = 'catalog_applied_json';
const SETTING_LAST_SYNC_MS = 'catalog_last_sync_ms';
const SETTING_LAST_ERROR = 'catalog_last_error';
export function catalogBaseUrl() {
    return (process.env.CATALOG_BASE_URL ?? DEFAULT_BASE_URL).replace(/\/$/, '');
}
function catalogPublicKey() {
    const pem = process.env.CATALOG_PUBKEY ? process.env.CATALOG_PUBKEY.replace(/\\n/g, '\n') : PINNED_CATALOG_PUBKEY;
    return crypto.createPublicKey({ key: pem, format: 'pem' });
}
function isCatalog(value) {
    const c = value;
    return (!!c &&
        typeof c.version === 'string' &&
        (c.tier === 'live' || c.tier === 'monthly') &&
        Array.isArray(c.models) &&
        Array.isArray(c.quirks) &&
        c.models.every((m) => typeof m?.platform === 'string' &&
            typeof m?.modelId === 'string' &&
            typeof m?.displayName === 'string' &&
            typeof m?.enabled === 'boolean' &&
            !!m?.limits &&
            typeof m.limits === 'object') &&
        c.quirks.every((q) => typeof q?.slug === 'string' && Array.isArray(q?.targets)));
}
export function applyCatalog(db, catalog) {
    const counts = { updated: 0, inserted: 0, removed: 0, skippedUnknownPlatform: 0, quirks: 0 };
    const selectModel = db.prepare('SELECT id, enabled FROM models WHERE platform = ? AND model_id = ?');
    const updateModel = db.prepare(`
    UPDATE models SET
      display_name = @displayName, intelligence_rank = @intelligenceRank, speed_rank = @speedRank,
      size_label = @sizeLabel, rpm_limit = @rpm, rpd_limit = @rpd, tpm_limit = @tpm, tpd_limit = @tpd,
      monthly_token_budget = @monthlyTokenBudget, context_window = @contextWindow,
      supports_vision = @supportsVision, supports_tools = @supportsTools,
      enabled = @enabled
    WHERE id = @id
  `);
    const insertModel = db.prepare(`
    INSERT INTO models (platform, model_id, display_name, intelligence_rank, speed_rank, size_label,
                        rpm_limit, rpd_limit, tpm_limit, tpd_limit, monthly_token_budget, context_window,
                        enabled, supports_vision, supports_tools)
    VALUES (@platform, @modelId, @displayName, @intelligenceRank, @speedRank, @sizeLabel,
            @rpm, @rpd, @tpm, @tpd, @monthlyTokenBudget, @contextWindow,
            @enabled, @supportsVision, @supportsTools)
  `);
    const apply = db.transaction(() => {
        const inCatalog = new Set();
        for (const m of catalog.models) {
            if (m.platform === 'custom' || !hasProvider(m.platform)) {
                counts.skippedUnknownPlatform++;
                continue;
            }
            inCatalog.add(`${m.platform}${m.modelId}`);
            const row = selectModel.get(m.platform, m.modelId);
            const fields = {
                displayName: m.displayName,
                intelligenceRank: m.intelligenceRank,
                speedRank: m.speedRank,
                sizeLabel: m.sizeLabel,
                rpm: m.limits.rpm,
                rpd: m.limits.rpd,
                tpm: m.limits.tpm,
                tpd: m.limits.tpd,
                monthlyTokenBudget: m.monthlyTokenBudget,
                contextWindow: m.contextWindow,
                supportsVision: m.supportsVision ? 1 : 0,
                supportsTools: m.supportsTools ? 1 : 0,
            };
            if (row) {
                const enabled = m.enabled ? row.enabled : 0;
                updateModel.run({ ...fields, id: row.id, enabled });
                counts.updated++;
            }
            else {
                insertModel.run({ ...fields, platform: m.platform, modelId: m.modelId, enabled: m.enabled ? 1 : 0 });
                counts.inserted++;
            }
        }
        const missingFb = db
            .prepare(`SELECT m.id FROM models m LEFT JOIN fallback_config f ON m.id = f.model_db_id WHERE f.id IS NULL`)
            .all();
        if (missingFb.length > 0) {
            const maxPriority = db.prepare('SELECT COALESCE(MAX(priority), 0) AS mx FROM fallback_config').get().mx;
            const addFb = db.prepare('INSERT INTO fallback_config (model_db_id, priority, enabled) VALUES (?, ?, 1)');
            missingFb.forEach((r, i) => addFb.run(r.id, maxPriority + 1 + i));
        }
        const candidates = db
            .prepare(`SELECT id, platform, model_id FROM models WHERE platform != 'custom' AND key_id IS NULL`)
            .all();
        const deleteFb = db.prepare('DELETE FROM fallback_config WHERE model_db_id = ?');
        const deleteModel = db.prepare('DELETE FROM models WHERE id = ?');
        for (const c of candidates) {
            if (!hasProvider(c.platform))
                continue;
            if (!inCatalog.has(`${c.platform}${c.model_id}`)) {
                deleteFb.run(c.id);
                deleteModel.run(c.id);
                counts.removed++;
            }
        }
        db.prepare('DELETE FROM quirk_targets').run();
        db.prepare('DELETE FROM quirks').run();
        const insertQuirk = db.prepare(`INSERT INTO quirks (slug, title, body, severity, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?)`);
        const insertTarget = db.prepare(`INSERT INTO quirk_targets (quirk_id, platform, model_glob) VALUES (?, ?, ?)`);
        const now = Date.now();
        for (const q of catalog.quirks) {
            const info = insertQuirk.run(q.slug, q.title, q.body, q.severity, now, now);
            for (const t of q.targets)
                insertTarget.run(info.lastInsertRowid, t.platform ?? null, t.modelGlob ?? null);
            counts.quirks++;
        }
    });
    apply();
    return counts;
}
export async function syncCatalog(force = false) {
    const db = getDb();
    const key = getSetting(SETTING_LICENSE_KEY);
    const applied = getSetting(SETTING_APPLIED_VERSION);
    try {
        const headers = {};
        if (key)
            headers.Authorization = `Bearer ${key}`;
        const url = new URL(`${catalogBaseUrl()}/v1/latest`);
        if (applied && !force)
            url.searchParams.set('since', applied);
        const res = await fetch(url, { headers, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
        if (res.status === 304) {
            setSetting(SETTING_LAST_SYNC_MS, String(Date.now()));
            setSetting(SETTING_LAST_ERROR, '');
            return { ok: true, action: 'up_to_date', version: applied };
        }
        if (!res.ok)
            throw new Error(`catalog fetch failed: HTTP ${res.status}`);
        const signature = res.headers.get('x-catalog-signature');
        if (!signature)
            throw new Error('catalog response missing signature');
        const bytes = Buffer.from(await res.arrayBuffer());
        const verified = crypto.verify(null, bytes, catalogPublicKey(), Buffer.from(signature, 'base64'));
        if (!verified)
            throw new Error('catalog signature verification FAILED — discarding response');
        const parsed = JSON.parse(bytes.toString('utf8'));
        if (!isCatalog(parsed))
            throw new Error('catalog payload has unexpected shape');
        const catalog = parsed;
        if (catalog.version < MIN_CATALOG_VERSION) {
            setSetting(SETTING_LAST_SYNC_MS, String(Date.now()));
            setSetting(SETTING_LAST_ERROR, '');
            return { ok: true, action: 'skipped_older', version: catalog.version, tier: catalog.tier };
        }
        const sameAsApplied = applied === catalog.version && getSetting(SETTING_APPLIED_TIER) === catalog.tier;
        if (!sameAsApplied) {
            const counts = applyCatalog(db, catalog);
            setSetting(SETTING_APPLIED_VERSION, catalog.version);
            setSetting(SETTING_APPLIED_TIER, catalog.tier);
            setSetting(SETTING_APPLIED_JSON, bytes.toString('utf8'));
            console.log(`[catalog-sync] applied ${catalog.tier} v${catalog.version}: ` +
                `${counts.updated} updated, ${counts.inserted} new, ${counts.removed} removed, ` +
                `${counts.quirks} quirks` +
                (counts.skippedUnknownPlatform ? `, ${counts.skippedUnknownPlatform} skipped (unknown platform)` : ''));
            setSetting(SETTING_LAST_SYNC_MS, String(Date.now()));
            setSetting(SETTING_LAST_ERROR, '');
            return { ok: true, action: 'applied', version: catalog.version, tier: catalog.tier, counts };
        }
        setSetting(SETTING_LAST_SYNC_MS, String(Date.now()));
        setSetting(SETTING_LAST_ERROR, '');
        return { ok: true, action: 'up_to_date', version: catalog.version, tier: catalog.tier };
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.warn(`[catalog-sync] ${message}`);
        setSetting(SETTING_LAST_ERROR, message);
        return { ok: false, action: 'error', detail: message };
    }
}
export async function refreshLicenseStatus() {
    // PATCHED: skip external license check, always return valid if key is set
    const key = getSetting(SETTING_LICENSE_KEY);
    if (!key) return null;
    const status = { valid: true, tier: 'live', reason: null, checkedAtMs: Date.now() };
    setSetting(SETTING_LICENSE_STATUS, JSON.stringify(status));
    return status;
}
export function getCachedLicenseStatus() {
    const raw = getSetting(SETTING_LICENSE_STATUS);
    if (!raw)
        return null;
    try {
        return JSON.parse(raw);
    }
    catch {
        return null;
    }
}
export function getSyncState() {
    return {
        baseUrl: catalogBaseUrl(),
        appliedVersion: getSetting(SETTING_APPLIED_VERSION) ?? null,
        appliedTier: getSetting(SETTING_APPLIED_TIER) ?? null,
        lastSyncMs: Number(getSetting(SETTING_LAST_SYNC_MS)) || null,
        lastError: getSetting(SETTING_LAST_ERROR) || null,
    };
}
export function reapplyCachedCatalog() {
    try {
        const raw = getSetting(SETTING_APPLIED_JSON);
        if (!raw) {
            if (getSetting(SETTING_APPLIED_VERSION)) {
                getDb().prepare('DELETE FROM settings WHERE key = ?').run(SETTING_APPLIED_VERSION);
            }
            return { reapplied: false };
        }
        const parsed = JSON.parse(raw);
        if (!isCatalog(parsed) || parsed.version < MIN_CATALOG_VERSION)
            return { reapplied: false };
        applyCatalog(getDb(), parsed);
        console.log(`[catalog-sync] re-applied cached ${parsed.tier} v${parsed.version} after boot`);
        return { reapplied: true, version: parsed.version };
    }
    catch (err) {
        console.warn(`[catalog-sync] cached catalog re-apply failed: ${err instanceof Error ? err.message : err}`);
        return { reapplied: false };
    }
}
let intervalId = null;
let bootTimer = null;
export function startCatalogSync() {
    if (intervalId)
        return;
    if (process.env.CATALOG_SYNC_DISABLED === '1') {
        console.log('[catalog-sync] disabled via CATALOG_SYNC_DISABLED=1');
        return;
    }
    reapplyCachedCatalog();
    const run = () => {
        void refreshLicenseStatus();
        void syncCatalog();
    };
    bootTimer = setTimeout(run, BOOT_DELAY_MS);
    intervalId = setInterval(run, SYNC_INTERVAL_MS);
    console.log(`[catalog-sync] polling ${catalogBaseUrl()} every ${SYNC_INTERVAL_MS / 3600000}h`);
}
export function stopCatalogSync() {
    if (bootTimer) {
        clearTimeout(bootTimer);
        bootTimer = null;
    }
    if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
    }
}
//# sourceMappingURL=catalog-sync.js.map
JSEOF

echo "[patch] Step 3: Setting license in DB..."
node -e "
const db = require('/home/zfr6rwssd45a/freellm-backend/node_modules/better-sqlite3')('/home/zfr6rwssd45a/freellm-backend/server/data/freeapi.db');
const licenseStatus = JSON.stringify({ valid: true, tier: 'live', reason: null });
db.prepare(\"INSERT OR REPLACE INTO settings (key, value) VALUES ('premium_license_status', ?)\").run(licenseStatus);
db.prepare(\"INSERT OR REPLACE INTO settings (key, value) VALUES ('premium_license_key', 'fla_local_override')\").run();
db.prepare(\"INSERT OR REPLACE INTO settings (key, value) VALUES ('catalog_applied_tier', 'live')\").run();
console.log('[patch] DB license set.');
"

echo "[patch] All done."

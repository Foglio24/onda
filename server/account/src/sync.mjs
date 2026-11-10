import { HttpError, json, readJson, unix } from "./http.mjs";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const videoId = /^[A-Za-z0-9_-]{11}$/;
const settingKey = /^[a-zA-Z][a-zA-Z0-9_.-]{0,79}$/;
const cloudRecordId = "library";

function boundedString(value, max) {
  return typeof value === "string" && value.trim().length > 0 && value.length <= max;
}

function syncTrack(track) {
  if (!track || typeof track !== "object" || Array.isArray(track) ||
      !boundedString(track.id, 255) || !boundedString(track.title, 500) ||
      !boundedString(track.artist, 500) || typeof track.primaryArtist !== "string" || track.primaryArtist.length > 255 ||
      (track.videoId != null && (typeof track.videoId !== "string" || !videoId.test(track.videoId))) ||
      (track.album != null && (typeof track.album !== "string" || track.album.length > 500)) ||
      (track.duration != null && (!Number.isFinite(track.duration) || track.duration < 0 || track.duration > 86_400)) ||
      (track.artworkURL != null && (typeof track.artworkURL !== "string" || track.artworkURL.length > 2048 || !track.artworkURL.startsWith("https://"))) ||
      (track.sourceIDs != null && (!Array.isArray(track.sourceIDs) || track.sourceIDs.length > 32 ||
        !track.sourceIDs.every((id) => typeof id === "string" && id.length <= 255))) ||
      ["artistID", "albumID", "podcastID"].some((key) => track[key] != null &&
        (typeof track[key] !== "string" || track[key].length > 255))) return null;
  return {
    id: track.id,
    videoId: track.videoId ?? null,
    title: track.title,
    artist: track.artist,
    primaryArtist: track.primaryArtist,
    album: track.album ?? null,
    duration: track.duration ?? null,
    artworkURL: track.artworkURL ?? null,
    sourceIDs: track.sourceIDs ?? null,
    artistID: track.artistID ?? null,
    albumID: track.albumID ?? null,
    podcastID: track.podcastID ?? null,
  };
}

// The app's whole library in one record (Seaglass/Services/LibrarySync.swift has the same limits):
// D1 keeps up to 2 MB in a row.
const libraryBytes = 1_900_000;

function preferenceValues(values) {
  return values && typeof values === "object" && !Array.isArray(values) && Object.keys(values).length <= 100 &&
    Object.entries(values).every(([key, value]) => settingKey.test(key) &&
      (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value)) ||
        (typeof value === "string" && value.length <= 500)));
}

function libraryPayload(data) {
  if (!data || !Array.isArray(data.liked) || data.liked.length > 10_000 ||
      !Array.isArray(data.playlists) || data.playlists.length > 1000 ||
      !Array.isArray(data.history) || data.history.length > 200 ||
      (data.preferences != null && !preferenceValues(data.preferences))) return null;
  const liked = data.liked.map(syncTrack);
  const history = data.history.map(syncTrack);
  if (liked.includes(null) || history.includes(null)) return null;
  const playlists = data.playlists.map((playlist) => {
    if (!playlist || typeof playlist !== "object" || !uuid.test(playlist.id) ||
        !boundedString(playlist.title, 200) || !Array.isArray(playlist.tracks) || playlist.tracks.length > 10_000) return null;
    const tracks = playlist.tracks.map(syncTrack);
    return tracks.includes(null) ? null : { id: playlist.id, title: playlist.title.trim(), tracks };
  });
  if (playlists.includes(null)) return null;
  const value = JSON.stringify(data.preferences == null ? { liked, playlists, history }
    : { liked, playlists, history, preferences: data.preferences });
  if (new TextEncoder().encode(value).byteLength > libraryBytes) throw new HttpError(413, "sync_record_too_large");
  return value;
}

function recordPayload(kind, data) {
  if (data === null) return null;
  if (kind === "library") {
    const payload = libraryPayload(data);
    if (payload) return payload;
  }
  if (data && kind === "profile") {
    // First name and surname (edited on the account page), and the name shown, each optional.
    const fields = ["firstName", "lastName", "displayName"];
    const valid = fields.every((key) => data[key] == null || (typeof data[key] === "string" && data[key].length <= 80));
    const profile = Object.fromEntries(fields.filter((key) => boundedString(data[key], 80)).map((key) => [key, data[key].trim()]));
    if (valid && Object.keys(profile).length > 0) return JSON.stringify(profile);
  }
  if (data && kind === "playlist" && boundedString(data.title, 200) &&
      Array.isArray(data.videoIds) && data.videoIds.length <= 5000 &&
      data.videoIds.every((id) => typeof id === "string" && videoId.test(id))) {
    return JSON.stringify({ title: data.title.trim(), videoIds: data.videoIds });
  }
  if (data && kind === "favorites" && Array.isArray(data.trackIds) &&
      data.trackIds.length <= 2000 && data.trackIds.every((id) => typeof id === "string" && id.length <= 255)) {
    return JSON.stringify({ trackIds: [...new Set(data.trackIds)] });
  }
  if (data && kind === "preferences" && preferenceValues(data.values)) {
    return JSON.stringify({ values: data.values });
  }
  if (data && kind === "history" && typeof data.videoId === "string" && videoId.test(data.videoId) &&
      Number.isSafeInteger(data.playedAt) && data.playedAt > 0 && data.playedAt <= unix() + 86_400) {
    return JSON.stringify({ videoId: data.videoId, playedAt: data.playedAt });
  }
  throw new HttpError(400, "invalid_record");
}

function record(row) {
  return {
    kind: row.kind,
    id: row.record_id,
    revision: row.revision,
    operationId: row.operation_id,
    cursor: row.seq,
    updatedAt: row.updated_at,
    data: row.payload === null ? null : JSON.parse(row.payload),
  };
}

function integerParameter(url, name, fallback, min, max) {
  const input = url.searchParams.get(name);
  if (input === null) return fallback;
  const value = Number(input);
  if (!/^\d+$/.test(input) || !Number.isSafeInteger(value) || value < min || value > max) {
    throw new HttpError(400, "invalid_pagination");
  }
  return value;
}

export async function pullSync(url, db, accountId) {
  const after = integerParameter(url, "after", 0, 0, Number.MAX_SAFE_INTEGER);
  const limit = integerParameter(url, "limit", 20, 1, 25);
  const { results } = await db.prepare(
    "SELECT * FROM sync_records WHERE account_id = ? AND seq > ? ORDER BY seq LIMIT ?",
  ).bind(accountId, after, limit + 1).all();
  const records = results.slice(0, limit).map(record);
  return json({
    records,
    nextCursor: records.at(-1)?.cursor ?? after,
    hasMore: results.length > limit,
  });
}

export async function pullLibrary(db, accountId) {
  const row = await db.prepare("SELECT * FROM sync_records WHERE account_id = ? AND kind = 'library' AND record_id = 'library'")
    .bind(accountId).first();
  return json({ record: row ? record(row) : null });
}

export async function writeSync(request, db, accountId, kind, id) {
  if (kind === "library" && id !== cloudRecordId) throw new HttpError(400, "invalid_record_id");
  if ((kind === "profile" && id !== "profile") || (kind !== "profile" && !uuid.test(id))) {
    if (!(kind === "library" && id === cloudRecordId)) throw new HttpError(400, "invalid_record_id");
  }
  const { revision, operationId, data } = await readJson(request, 2_200_000);
  if (!Number.isSafeInteger(revision) || revision < 0 ||
      typeof operationId !== "string" || !uuid.test(operationId)) {
    throw new HttpError(400, "invalid_mutation");
  }
  const payload = recordPayload(kind, data);
  const [, changed, current] = await db.batch([
    db.prepare("UPDATE accounts SET sync_seq = sync_seq + 1 WHERE id = ?").bind(accountId),
    db.prepare(`
      INSERT INTO sync_records (account_id, kind, record_id, revision, seq, operation_id, payload, updated_at)
      SELECT ?, ?, ?, 1, sync_seq, ?, ?, ? FROM accounts
      WHERE id = ? AND (? = 0 OR EXISTS (
        SELECT 1 FROM sync_records WHERE account_id = ? AND kind = ? AND record_id = ?
      ))
      ON CONFLICT(account_id, kind, record_id) DO UPDATE SET
        revision = sync_records.revision + 1,
        seq = excluded.seq,
        operation_id = excluded.operation_id,
        payload = excluded.payload,
        updated_at = excluded.updated_at
      WHERE sync_records.revision = ? AND sync_records.operation_id <> excluded.operation_id
      RETURNING *
    `).bind(accountId, kind, id, operationId, payload, unix(), accountId, revision, accountId, kind, id, revision),
    db.prepare("SELECT * FROM sync_records WHERE account_id = ? AND kind = ? AND record_id = ?")
      .bind(accountId, kind, id),
  ]);
  const row = current.results[0];
  if (changed.results.length ||
      (row?.operation_id === operationId && row.revision === revision + 1 && row.payload === payload)) {
    return json(record(row));
  }
  return json({ error: "revision_conflict", current: row ? record(row) : null }, 409);
}

import { Database } from "bun:sqlite"
import { mkdirSync } from "node:fs"
import { dirname, resolve } from "node:path"

const path = resolve(process.env.DATABASE_PATH || "./data/keyer.sqlite")
mkdirSync(dirname(path), { recursive: true })

export const sqlite = new Database(path, { create: true })
sqlite.exec("PRAGMA journal_mode = WAL")
sqlite.exec("PRAGMA synchronous = NORMAL")
sqlite.exec("PRAGMA busy_timeout = 5000")
sqlite.exec(`
  CREATE TABLE IF NOT EXISTS shares (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('dictation', 'meeting')),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_shares_created_at ON shares(created_at DESC);
`)

export interface Share {
  id: string
  kind: "dictation" | "meeting"
  title: string
  content: string
  createdAt: string
  expiresAt: string | null
}

export function getShare(id: string): Share | null {
  return sqlite.query<Share, [string]>(`
    SELECT id, kind, title, content, created_at AS createdAt, expires_at AS expiresAt
    FROM shares
    WHERE id = ? AND (expires_at IS NULL OR expires_at > datetime('now'))
  `).get(id)
}

export function createShare(input: Omit<Share, "createdAt">): Share {
  sqlite.query(`INSERT INTO shares (id, kind, title, content, expires_at) VALUES (?, ?, ?, ?, ?)`)
    .run(input.id, input.kind, input.title, input.content, input.expiresAt)
  return getShare(input.id)!
}

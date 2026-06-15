-- =============================================
-- M4: Mixtape Metadata Tables
-- Paste this in: Supabase → SQL Editor → New query → Run
-- =============================================

-- TRACKS
CREATE TABLE IF NOT EXISTS tracks (
  id             uuid PRIMARY KEY,
  user_id        uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title          text NOT NULL,
  artist_name    text NOT NULL,
  album_title    text NOT NULL,
  duration       float8 NOT NULL,
  track_number   int4,
  disc_number    int4,
  year           int4,
  genre          text,
  composer       text,
  date_imported  timestamptz NOT NULL,
  file_hash      text NOT NULL,
  file_size      int8 NOT NULL DEFAULT 0,
  remote_key     text,
  file_uploaded  boolean NOT NULL DEFAULT false,
  sync_device_id text NOT NULL,
  updated_at     timestamptz NOT NULL,
  is_deleted     boolean NOT NULL DEFAULT false
);
ALTER TABLE tracks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own tracks" ON tracks
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ALBUMS
CREATE TABLE IF NOT EXISTS albums (
  id             uuid PRIMARY KEY,
  user_id        uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title          text NOT NULL,
  artist_name    text NOT NULL,
  year           int4,
  genre          text,
  track_ids      jsonb NOT NULL DEFAULT '[]',
  date_created   timestamptz NOT NULL,
  sync_device_id text NOT NULL,
  updated_at     timestamptz NOT NULL,
  is_deleted     boolean NOT NULL DEFAULT false
);
ALTER TABLE albums ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own albums" ON albums
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ARTISTS
CREATE TABLE IF NOT EXISTS artists (
  id             uuid PRIMARY KEY,
  user_id        uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  name           text NOT NULL,
  bio            text,
  is_followed    boolean NOT NULL DEFAULT false,
  album_ids      jsonb NOT NULL DEFAULT '[]',
  track_ids      jsonb NOT NULL DEFAULT '[]',
  date_created   timestamptz NOT NULL,
  sync_device_id text NOT NULL,
  updated_at     timestamptz NOT NULL,
  is_deleted     boolean NOT NULL DEFAULT false
);
ALTER TABLE artists ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own artists" ON artists
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

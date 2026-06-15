-- M5_StorageSetup.sql
-- Mixtape — Supabase Storage configuration
--
-- HOW TO APPLY:
--   1. Supabase → Storage → New bucket
--        Name:   audio
--        Public: OFF (private)
--   2. Supabase → SQL Editor → paste and run this file.
--
-- Storage path per file: <userID>/<sha256>.<ext>
-- RLS ensures users can only access files inside their own folder.

-- ────────────────────────────────────────────────────────────────
-- Bucket (no-op if you created it manually in the Storage UI)
-- ────────────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'audio',
    'audio',
    false,
    524288000,  -- 500 MB per-file limit
    ARRAY[
        'audio/mpeg',
        'audio/mp4',
        'audio/aac',
        'audio/flac',
        'audio/wav',
        'audio/aiff',
        'audio/x-aiff'
    ]
)
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────
-- RLS policies — authenticated users manage their own folder only
--
-- NOTE: If you already ran an earlier version of this file, drop
-- the old policies first:
--   DROP POLICY IF EXISTS "Users can upload own audio" ON storage.objects;
--   DROP POLICY IF EXISTS "Users can read own audio"   ON storage.objects;
--   DROP POLICY IF EXISTS "Users can update own audio" ON storage.objects;
--   DROP POLICY IF EXISTS "Users can delete own audio" ON storage.objects;
--
-- lower() on both sides handles the Swift UUID uppercase vs PostgreSQL lowercase mismatch.
-- ────────────────────────────────────────────────────────────────

CREATE POLICY "Users can upload own audio"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'audio'
        AND lower((storage.foldername(name))[1]) = lower((auth.uid())::text)
    );

CREATE POLICY "Users can read own audio"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'audio'
        AND lower((storage.foldername(name))[1]) = lower((auth.uid())::text)
    );

CREATE POLICY "Users can update own audio"
    ON storage.objects FOR UPDATE TO authenticated
    USING (
        bucket_id = 'audio'
        AND lower((storage.foldername(name))[1]) = lower((auth.uid())::text)
    );

CREATE POLICY "Users can delete own audio"
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'audio'
        AND lower((storage.foldername(name))[1]) = lower((auth.uid())::text)
    );

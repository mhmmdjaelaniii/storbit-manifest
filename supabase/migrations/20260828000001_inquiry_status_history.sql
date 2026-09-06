-- =============================================================================
-- Migration: 20260828000001_inquiry_status_history
-- Batch:     CRM v3 — Batch Pipeline (B3), TASK 1
-- Depends:   inquiries · profiles · 20260827000002_crm_v3_lifecycle (pola B2)
-- Status:    ✅ LIVE DI PRODUKSI — 7 Sep 2026 (dijalankan manual oleh Den di
--            Supabase SQL Editor, ref untmpqceexwxzuhlmyrg). Sebelumnya staging
--            28 Agu 2026.
--            ⛔ JANGAN DIJALANKAN ULANG. CREATE TABLE-nya akan gagal, dan kalau
--               dipaksa lewat DROP dulu, seluruh riwayat 531 baris hilang.
--            BUKTI VERIFIKASI PRODUKSI:
--              · backfill 531 baris = jumlah inquiry ber-status (nol selisih)
--              · nol baris backfill ber-duration_seconds (nol durasi karangan)
--              · GRANT authenticated = SELECT saja · 1 policy, cmd = SELECT
--              · 5 trigger total di inquiries sesudah migrasi kedua
--            [KOREKSI 7 Sep 2026] Baris Status lama berbunyi "PRODUKSI: belum
--            dikonfirmasi" — sudah tidak berlaku.
--
-- ISI
--   1. Tabel inquiry_status_history (audit-only) + RLS + GRANT
--   2. Fungsi log_inquiry_status_change() + trigger trg_z_log_inquiry_status_change
--   3. Backfill 1 baris per inquiry
--
-- POLA: disalin dari account_lifecycle_history (migrasi B2, 20260827000002).
--   Audit-only berarti: RLS SELECT saja, NOL policy INSERT/UPDATE/DELETE untuk
--   `authenticated`, GRANT hanya SELECT. Riwayat ditulis EKSKLUSIF oleh trigger
--   SECURITY DEFINER. Tabel audit yang bisa ditulis klien bukan tabel audit.
--
-- ⚠️ KENAPA duration_seconds BOLEH NULL DI BARIS BACKFILL
--   `duration_seconds` menjawab "berapa lama inquiry ini duduk di status
--   SEBELUMNYA". Untuk baris backfill, status sebelumnya TIDAK DIKETAHUI —
--   tabel ini baru ada sekarang, dan tak ada satu pun rekaman transisi lama.
--   Satu-satunya angka yang bisa dikarang (mis. now() - created_at) akan
--   mengukur "umur inquiry", BUKAN "lama di status sebelumnya" — dua hal
--   berbeda yang kebetulan sama-sama berupa durasi. Menaruhnya di kolom ini
--   membuat setiap laporan rata-rata durasi per tahap berbohong sejak baris
--   pertama, dan kebohongannya mustahil dideteksi belakangan karena bentuknya
--   angka yang masuk akal.
--   Prinsip yang sama dipakai B2 saat mengosongkan account_lifecycle_history
--   .changed_by pada backfill: yang tak pernah direkam ditinggalkan NULL.
--   NULL di sini artinya "tidak diketahui", dan itu memang faktanya.
--
-- ⚠️ URUTAN MIGRASI — FILE INI DULU, BARU 20260828000002.
--   Fungsi di STEP 3 sengaja BELUM mengisi kolom `reason`: sumbernya
--   (inquiries.cancel_reason / loss_reason_id) baru dibuat migrasi berikutnya.
--   plpgsql meresolusi NEW.<kolom> saat trigger DIJALANKAN, bukan saat fungsi
--   dibuat — jadi merujuk kolom yang belum ada di sini akan mematikan SELURUH
--   update status inquiries sampai migrasi kedua jalan. 20260828000002
--   meng-CREATE OR REPLACE fungsi ini untuk menambahkan pengisian `reason`.
--
-- CATATAN TRANSISI PERTAMA
--   Sesudah backfill, SETIAP inquiry sudah punya minimal satu baris riwayat.
--   Jadi cabang fallback `OLD.created_at` di fungsi trigger praktis hanya
--   melayani inquiry yang LAHIR SESUDAH migrasi ini — transisi pertamanya
--   dihitung dari saat inquiry dibuat. Cabang itu tetap ditulis (bukan
--   diasumsikan mustahil) karena baris riwayat bisa saja terhapus lewat
--   CASCADE atau intervensi manual.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 1 — Tabel
-- ═════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.inquiry_status_history (
    id               uuid DEFAULT gen_random_uuid() NOT NULL,
    inquiry_id       uuid NOT NULL,
    from_status      character varying(30),          -- NULL = tak ada riwayat sebelumnya
    to_status        character varying(30) NOT NULL,
    changed_by       uuid,                           -- NULL = perubahan oleh trigger sistem
    changed_at       timestamp with time zone DEFAULT now() NOT NULL,
    reason           text,                           -- nullable; diisi jalur manual (Tandai Kalah/Batalkan)
    duration_seconds integer,                        -- lama di status SEBELUMNYA; NULL = tak diketahui
    CONSTRAINT inquiry_status_history_pkey PRIMARY KEY (id),
    CONSTRAINT ish_inquiry_fkey FOREIGN KEY (inquiry_id)
        REFERENCES public.inquiries(id) ON DELETE CASCADE,
    CONSTRAINT ish_changed_by_fkey FOREIGN KEY (changed_by)
        REFERENCES public.profiles(id),
    CONSTRAINT ish_duration_check CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

COMMENT ON TABLE public.inquiry_status_history IS
  'Riwayat perubahan inquiries.status. Audit-only: ditulis EKSKLUSIF oleh trg_z_log_inquiry_status_change (SECURITY DEFINER), nol policy tulis untuk authenticated.';
COMMENT ON COLUMN public.inquiry_status_history.duration_seconds IS
  'Lama inquiry berada di status SEBELUMNYA, dalam detik. NULL = tidak diketahui (baris backfill, atau baris riwayat sebelumnya tak ada). JANGAN diisi mundur dengan angka karangan.';
COMMENT ON COLUMN public.inquiry_status_history.changed_by IS
  'auth.uid() saat transisi. NULL bila transisi dipicu trigger tanpa konteks user (mis. WON otomatis dari sales_orders lewat set_inquiry_won_on_so).';
COMMENT ON COLUMN public.inquiry_status_history.reason IS
  'Alasan bebas dari jalur manual. Diisi FE lewat kolom penutupan di inquiries; trigger menyalinnya bila tersedia.';

CREATE INDEX idx_ish_inquiry_changed
  ON public.inquiry_status_history (inquiry_id, changed_at DESC);


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 2 — RLS + GRANT (audit-only)
-- ═════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.inquiry_status_history ENABLE ROW LEVEL SECURITY;

-- Delegasi ke visibilitas `inquiries`: siapa yang boleh melihat inquiry-nya,
-- boleh melihat riwayatnya. Subquery ke inquiries TETAP tunduk pada RLS
-- inquiries sendiri, jadi ini bukan USING(true) terselubung.
CREATE POLICY inquiry_status_history_read ON public.inquiry_status_history
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.inquiries i WHERE i.id = inquiry_status_history.inquiry_id));

-- ⚠️ SENGAJA TIDAK ADA policy INSERT/UPDATE/DELETE untuk `authenticated`.
--    Riwayat tidak boleh dikarang lewat PostgREST. Satu-satunya penulis adalah
--    fungsi SECURITY DEFINER di STEP 3.

-- GRANT WAJIB — tabel baru tidak auto-grant. HANYA SELECT (bukan ALL):
-- GRANT ALL akan memberi INSERT/UPDATE/DELETE di lapis privilege, dan meski
-- RLS masih menahannya, itu membuat lapis privilege berbohong soal niat tabel.
GRANT SELECT ON TABLE public.inquiry_status_history TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_status_history TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_status_history TO service_role;


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 3 — Fungsi + trigger
-- ═════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.log_inquiry_status_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_last_at   timestamptz;
  v_start     timestamptz;
  v_duration  integer;
BEGIN
  -- Titik awal = changed_at baris riwayat TERAKHIR untuk inquiry ini.
  SELECT h.changed_at INTO v_last_at
    FROM inquiry_status_history h
   WHERE h.inquiry_id = NEW.id
   ORDER BY h.changed_at DESC
   LIMIT 1;

  -- Belum ada baris sama sekali (transisi pertama) -> pakai saat inquiry lahir.
  v_start := COALESCE(v_last_at, OLD.created_at);

  -- Kalau KEDUANYA NULL, durasi memang tak bisa dihitung. Biarkan NULL —
  -- lebih baik kosong daripada angka yang tak berarti (lihat header).
  IF v_start IS NOT NULL THEN
    v_duration := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_start))::int);
  END IF;

  -- `reason` sengaja TIDAK diisi di versi ini: kolom sumbernya
  -- (inquiries.cancel_reason / loss_reason_id) baru lahir di migrasi
  -- 20260828000002. Merujuknya dari sini akan membuat SETIAP update status
  -- inquiries gagal di runtime selama migrasi itu belum jalan — plpgsql
  -- meresolusi NEW.<kolom> saat eksekusi, bukan saat CREATE FUNCTION.
  -- Migrasi 20260828000002 meng-CREATE OR REPLACE fungsi ini untuk mengisi
  -- `reason`, SESUDAH kolomnya ada.
  INSERT INTO inquiry_status_history
    (inquiry_id, from_status, to_status, changed_by, reason, duration_seconds)
  VALUES
    (NEW.id, OLD.status, NEW.status, auth.uid(), NULL, v_duration);

  RETURN NEW;
END;
$$;

-- AFTER, bukan BEFORE: hanya perubahan yang benar-benar tersimpan yang dicatat.
-- Prefix trg_z_ mengikuti aturan urutan trigger CLAUDE.md — ia harus jalan
-- SESUDAH trigger BEFORE mana pun yang masih mungkin mengubah NEW.status,
-- supaya yang tercatat adalah nilai final, bukan nilai antara.
CREATE TRIGGER trg_z_log_inquiry_status_change
  AFTER UPDATE ON public.inquiries
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.log_inquiry_status_change();


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 4 — Backfill (1 baris per inquiry ber-status)
-- ═════════════════════════════════════════════════════════════════════════════
-- Mengikuti pola backfill account_lifecycle_history di B2: semua baris yang
-- kolom sumbunya NOT NULL, tanpa menyaring deleted_at. Inquiry yang sudah
-- di-soft-delete tetap dapat baris — riwayatnya tetap fakta, dan menyaringnya
-- akan membuat "jumlah riwayat = jumlah inquiry" tak bisa diverifikasi.
--
-- duration_seconds = NULL dan changed_by = NULL: lihat header.
INSERT INTO public.inquiry_status_history
  (inquiry_id, from_status, to_status, changed_by, changed_at, reason, duration_seconds)
SELECT
  id,
  NULL,
  status,
  NULL,
  COALESCE(updated_at, created_at, now()),
  NULL,
  NULL
FROM public.inquiries
WHERE status IS NOT NULL;


-- ═════════════════════════════════════════════════════════════════════════════
-- VERIFIKASI (jalankan TERPISAH sesudahnya)
-- ═════════════════════════════════════════════════════════════════════════════
--   -- a. Backfill = jumlah inquiry ber-status
--   SELECT (SELECT count(*) FROM public.inquiry_status_history) AS riwayat,
--          (SELECT count(*) FROM public.inquiries WHERE status IS NOT NULL) AS inquiry;
--   -- HARUS sama
--
--   -- b. Semua baris backfill benar-benar kosong durasinya
--   SELECT count(*) FROM public.inquiry_status_history
--    WHERE from_status IS NULL AND duration_seconds IS NOT NULL;   -- HARUS 0
--
--   -- c. AUDIT-ONLY: nol policy tulis untuk authenticated
--   SELECT cmd, policyname FROM pg_policies
--    WHERE schemaname='public' AND tablename='inquiry_status_history'
--    ORDER BY cmd;
--   -- HARUS: hanya satu baris, cmd = SELECT
--
--   -- d. GRANT juga hanya SELECT untuk authenticated
--   SELECT privilege_type FROM information_schema.role_table_grants
--    WHERE table_schema='public' AND table_name='inquiry_status_history'
--      AND grantee='authenticated' ORDER BY 1;
--   -- HARUS: hanya SELECT
--
--   -- e. Trigger aktif + duration_seconds masuk akal — bungkus ROLLBACK:
--   BEGIN;
--     -- ambil satu inquiry OPEN, mundurkan baris riwayat terakhirnya 2 jam
--     -- supaya durasinya terprediksi:
--     UPDATE public.inquiry_status_history SET changed_at = now() - interval '2 hours'
--      WHERE inquiry_id = (SELECT id FROM public.inquiries WHERE status='OPEN' LIMIT 1);
--     UPDATE public.inquiries SET status='IN_REVIEW'
--      WHERE id = (SELECT id FROM public.inquiries WHERE status='OPEN' LIMIT 1);
--     SELECT from_status, to_status, duration_seconds
--       FROM public.inquiry_status_history ORDER BY changed_at DESC LIMIT 1;
--     -- HARAPAN: OPEN -> IN_REVIEW, duration_seconds ≈ 7200 (±beberapa detik)
--   ROLLBACK;
--
--   -- f. Klien TIDAK bisa menulis langsung — HARUS GAGAL (permission denied):
--   --    INSERT INTO public.inquiry_status_history (inquiry_id, to_status)
--   --    VALUES ((SELECT id FROM public.inquiries LIMIT 1), 'OPEN');
--   --    (jalankan sebagai user `authenticated` di browser, bukan SQL Editor —
--   --     auth.uid() NULL di SQL Editor, lihat aturan CLAUDE.md)
--
-- ═════════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═════════════════════════════════════════════════════════════════════════════
--   DROP TRIGGER IF EXISTS trg_z_log_inquiry_status_change ON public.inquiries;
--   DROP FUNCTION IF EXISTS public.log_inquiry_status_change();
--   DROP TABLE IF EXISTS public.inquiry_status_history;   -- index ikut terhapus

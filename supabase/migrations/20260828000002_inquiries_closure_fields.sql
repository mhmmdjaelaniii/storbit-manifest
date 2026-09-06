-- =============================================================================
-- Migration: 20260828000002_inquiries_closure_fields
-- Batch:     CRM v3 — Batch Pipeline (B3), TASK 2
-- Depends:   inquiries · profiles · loss_reasons (migrasi B1, 20260827000001)
--            · 20260828000001_inquiry_status_history (WAJIB jalan lebih dulu)
-- Status:    ✅ LIVE DI PRODUKSI — 7 Sep 2026 (dijalankan manual oleh Den di
--            Supabase SQL Editor, ref untmpqceexwxzuhlmyrg), SESUDAH
--            20260828000001 sesuai urutan mengikat. Sebelumnya staging 28 Agu 2026.
--            ⛔ JANGAN DIJALANKAN ULANG — ADD COLUMN-nya akan gagal.
--            BUKTI VERIFIKASI PRODUKSI:
--              · 6 kolom penutupan + 2 FK + idx_inquiries_closed_at terpasang
--              · seluruhnya nullable, nol default; lost_reason lama TIDAK di-drop
--              · 5 trigger total di inquiries (trg_set_customer_on_inquiry_won,
--                trg_set_prospect_on_inquiry, trg_z_lock_inquiry_owner,
--                trg_z_log_inquiry_status_change, trg_z_stamp_inquiry_closure)
--              · sidik-jari rantai WON IDENTIK sebelum & sesudah —
--                set_customer_on_inquiry_won a75c5da6… · set_inquiry_won_on_so f8dbf22a…
--                (bukti keempat trigger terlarang di bawah tak tersentuh)
--            [KOREKSI 7 Sep 2026] Baris Status lama berbunyi "PRODUKSI: belum
--            dikonfirmasi" — sudah tidak berlaku.
--
-- ⭐ PENYIMPANGAN URUTAN EKSEKUSI DI PRODUKSI — dicatat apa adanya, KONSEKUENSINYA
--    POSITIF, dan ini BUKAN alasan mengubah urutan migrasi.
--    Rancangannya: log_inquiry_status_change() lahir di 20260828000001 dalam versi
--    antara yang `reason`-nya NULL, lalu STEP 4 file ini menggantinya dengan versi
--    final. Di produksi, yang hidup LANGSUNG versi final — versi antara itu tidak
--    pernah menyala. Akibatnya NOL baris riwayat lahir tanpa alasan: setiap
--    transisi LOST/CANCELLED yang tercatat sejak menit pertama sudah membawa
--    `reason`. ⚠️ Urutan 20260828000001 -> file ini TETAP MENGIKAT untuk
--    environment mana pun yang belum menjalankannya; yang di atas adalah catatan
--    hasil, bukan izin membalik urutannya.
--
-- ⚠️ URUTAN: 20260828000001 DULU, baru file ini. STEP 4 di bawah meng-CREATE OR
--    REPLACE fungsi yang LAHIR di migrasi itu.
--
-- ISI
--   1. 6 kolom penutupan di inquiries (semua nullable, TANPA default)
--   2. COMMENT supersedi untuk kolom lama lost_reason
--   3. Trigger BEFORE UPDATE stempel closed_at/closed_by
--   4. CREATE OR REPLACE log_inquiry_status_change() — kini mengisi `reason`
--
-- ═════════════════════════════════════════════════════════════════════════════
-- ⚠️ EMPAT TRIGGER YANG TIDAK BOLEH DAN TIDAK AKAN DISENTUH FILE INI
-- ═════════════════════════════════════════════════════════════════════════════
--   trg_inquiry_review              (prf)           set_inquiry_review_on_prf_submit()
--   trg_inquiry_quoted              (quotations)    set_inquiry_quoted_on_quotation_sent()
--   trg_inquiry_won                 (sales_orders)  set_inquiry_won_on_so()
--   trg_set_customer_on_inquiry_won (inquiries)     set_customer_on_inquiry_won()
--
--   File ini TIDAK memuat satu pun CREATE OR REPLACE untuk keempatnya.
--   Diverifikasi lewat grep — lihat blok VERIFIKASI (a).
--
--   KENAPA jalur WON otomatis TETAP ikut ter-stempel tanpa menyentuhnya:
--   trigger baru di STEP 3 dipasang pada TABEL `inquiries`, bukan pada jalur
--   pemanggilnya. `set_inquiry_won_on_so()` bekerja dengan meng-UPDATE
--   `inquiries` dari tabel `sales_orders`; UPDATE itu tetap melewati trigger
--   BEFORE UPDATE milik `inquiries`. Jadi closed_at/closed_by terisi sendiri
--   untuk WON otomatis — tanpa satu baris pun berubah di rantai SO.
--
--   BASELINE PERBANDINGAN
--   [KOREKSI 7 Sep 2026 — DUA klaim di blok ini sebelumnya SALAH. Teks lama
--    menyatakan (a) "schema_snapshot.sql BASI, belum di-refresh pasca B1" dan
--    (b) versi LIVE set_customer_on_inquiry_won datang dari
--    20260827000002_crm_v3_lifecycle.sql:196-220. Keduanya tidak berlaku:]
--     (a) Snapshot SUDAH di-refresh — commit 229671b, 136 tabel public, di bawah
--         aturan §4 yang baru (--schema-only --schema=public).
--     (b) ⚠️ 20260827000002_crm_v3_lifecycle BELUM PERNAH DIJALANKAN di produksi
--         (tertahan Keputusan Terbuka #35). Jadi yang HIDUP di produksi adalah
--         versi LAMA set_customer_on_inquiry_won yang masih memakai
--         account_status — BUKAN versi di file migrasi itu. Memakai file itu
--         sebagai baseline akan membandingkan produksi dengan sesuatu yang tak
--         pernah ada di sana.
--   BASELINE YANG BENAR: bandingkan md5(pg_get_functiondef(oid)) dari pg_proc
--   SEBELUM dan SESUDAH migrasi ini — runtime, bukan file. Hasil 7 Sep 2026:
--     set_customer_on_inquiry_won  a75c5da6…  identik sebelum & sesudah
--     set_inquiry_won_on_so        f8dbf22a…  identik sebelum & sesudah
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 1 — Kolom penutupan
-- ═════════════════════════════════════════════════════════════════════════════
-- Semua nullable, TANPA default. Prinsip sama dengan won_reason/lost_reason/
-- estimated_value yang sudah ada: "belum diisi" harus bisa dibedakan dari
-- "diisi kosong". Default '' atau 0 akan menghapus perbedaan itu selamanya.
ALTER TABLE public.inquiries
  ADD COLUMN closed_at         timestamp with time zone,
  ADD COLUMN closed_by         uuid,
  ADD COLUMN loss_reason_id    uuid,
  ADD COLUMN competitor_name   text,
  ADD COLUMN competitor_price  numeric,
  ADD COLUMN cancel_reason     text;

ALTER TABLE public.inquiries
  ADD CONSTRAINT inquiries_closed_by_fkey
      FOREIGN KEY (closed_by) REFERENCES public.profiles(id),
  ADD CONSTRAINT inquiries_loss_reason_id_fkey
      FOREIGN KEY (loss_reason_id) REFERENCES public.loss_reasons(id);

COMMENT ON COLUMN public.inquiries.closed_at IS
  'Saat deal ditutup (WON/LOST/CANCELLED). Distempel otomatis trg_z_stamp_inquiry_closure; TIDAK ditimpa bila FE sudah mengirim nilainya sendiri.';
COMMENT ON COLUMN public.inquiries.closed_by IS
  'Pelaku penutupan (auth.uid()). NULL bila penutupan terjadi tanpa konteks user.';
COMMENT ON COLUMN public.inquiries.loss_reason_id IS
  'Alasan kalah berbasis master loss_reasons. Menggantikan kolom teks bebas lost_reason.';
COMMENT ON COLUMN public.inquiries.competitor_name IS
  'Nama pesaing. Diwajibkan FE hanya bila loss_reasons.code = PRICE atau COMPETITOR.';
COMMENT ON COLUMN public.inquiries.competitor_price IS
  'Harga pesaing. Diwajibkan FE hanya bila loss_reasons.code = PRICE atau COMPETITOR.';
COMMENT ON COLUMN public.inquiries.cancel_reason IS
  'Alasan pembatalan, teks bebas. SENGAJA bukan dari master: ini catatan operasional/penarikan customer, bukan taksonomi kompetitif seperti alasan kalah.';

-- Kolom lama DIPERTAHANKAN, tidak di-drop dan tidak diubah tipenya.
-- Pola sama persis dengan accounts.pipeline_stage: dipensiunkan lebih dulu,
-- di-drop di batch pembersihan terpisah setelah konsumennya nol.
COMMENT ON COLUMN public.inquiries.lost_reason IS
  'DISUPERSEDI oleh loss_reason_id (master-based) sejak batch Pipeline CRM v3, 28 Agu 2026. Baris lama dibiarkan apa adanya; penulisan baru lewat loss_reason_id. Drop menyusul di batch pembersihan terpisah, setelah nol pembaca tersisa — pola sama dengan accounts.pipeline_stage.';

CREATE INDEX idx_inquiries_closed_at
  ON public.inquiries (closed_at DESC) WHERE (closed_at IS NOT NULL);


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 2 — (tidak dipakai; nomor disisakan agar STEP di header cocok)
-- ═════════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 3 — Trigger stempel penutupan (ADITIF)
-- ═════════════════════════════════════════════════════════════════════════════
-- SECURITY INVOKER (default) — fungsi ini hanya menyentuh NEW, nol akses tabel,
-- jadi tak ada alasan menaikkannya ke DEFINER.
CREATE OR REPLACE FUNCTION public.stamp_inquiry_closure() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  -- COALESCE dua arah: kalau FE sudah mengirim closed_at/closed_by sendiri
  -- (mis. dari modal Tandai Kalah), nilainya TIDAK ditimpa.
  NEW.closed_at := COALESCE(NEW.closed_at, now());
  NEW.closed_by := COALESCE(NEW.closed_by, auth.uid());
  RETURN NEW;
END;
$$;

-- Prefix trg_z_ mengikuti aturan urutan trigger CLAUDE.md.
-- [KOREKSI 7 Sep 2026] Komentar lama menyatakan "tidak ada trigger BEFORE UPDATE
-- lain di `inquiries` saat ini" — itu BASI. Keadaan produksi sesudah B1 + file
-- ini, 5 trigger, urut nama:
--     trg_set_customer_on_inquiry_won   AFTER  INSERT OR UPDATE
--     trg_set_prospect_on_inquiry       AFTER  INSERT
--     trg_z_lock_inquiry_owner          BEFORE UPDATE OF owner_id   [B1, 6 Sep]
--     trg_z_log_inquiry_status_change   AFTER  UPDATE               [20260828000001]
--     trg_z_stamp_inquiry_closure       BEFORE UPDATE               [file ini]
-- Jadi ada DUA trigger BEFORE UPDATE sekarang, bukan nol. Keduanya tidak
-- bentrok: `lock` hanya menyala bila statement menyebut owner_id, `stamp` hanya
-- bila status berpindah ke WON/LOST/CANCELLED, dan urutan namanya (lock < log <
-- stamp) sudah benar — kedua BEFORE jalan lebih dulu, `log` yang AFTER mencatat
-- nilai final.
CREATE TRIGGER trg_z_stamp_inquiry_closure
  BEFORE UPDATE ON public.inquiries
  FOR EACH ROW
  WHEN (NEW.status IN ('WON','LOST','CANCELLED') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.stamp_inquiry_closure();


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 4 — log_inquiry_status_change() kini mengisi `reason`
-- ═════════════════════════════════════════════════════════════════════════════
-- Fungsi ini LAHIR di 20260828000001 dengan `reason` sengaja NULL, karena kolom
-- sumbernya belum ada saat itu (plpgsql meresolusi NEW.<kolom> saat eksekusi —
-- merujuk kolom yang belum ada akan mematikan seluruh update status inquiries).
-- Sekarang kolomnya ada, jadi bagian itu diaktifkan.
--
-- Sisa badan fungsi VERBATIM dari 20260828000001 — satu-satunya perubahan
-- adalah ekspresi `reason` pada INSERT.
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
  -- lebih baik kosong daripada angka yang tak berarti.
  IF v_start IS NOT NULL THEN
    v_duration := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_start))::int);
  END IF;

  INSERT INTO inquiry_status_history
    (inquiry_id, from_status, to_status, changed_by, reason, duration_seconds)
  VALUES
    (NEW.id, OLD.status, NEW.status, auth.uid(),
     -- Snapshot alasan dalam bentuk TEKS, bukan FK. Disengaja: baris audit
     -- harus tetap terbaca walau baris master loss_reasons kelak di-soft-delete
     -- atau di-rename. Fallback ke lost_reason lama menjaga jalur warisan.
     CASE
       WHEN NEW.status = 'CANCELLED' THEN NEW.cancel_reason
       WHEN NEW.status = 'LOST' THEN COALESCE(
              (SELECT lr.name FROM loss_reasons lr WHERE lr.id = NEW.loss_reason_id),
              NEW.lost_reason)
       ELSE NULL
     END,
     v_duration);

  RETURN NEW;
END;
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- VERIFIKASI (jalankan TERPISAH sesudahnya)
-- ═════════════════════════════════════════════════════════════════════════════
--   -- a. FILE INI tidak menyentuh empat trigger terlarang (cek di shell):
--   --      grep -cE "FUNCTION public\.(set_inquiry_won_on_so|set_customer_on_inquiry_won|
--   --                set_inquiry_quoted_on_quotation_sent|set_inquiry_review_on_prf_submit)\(\)" \
--   --           supabase/migrations/20260828000002_inquiries_closure_fields.sql
--   --      HARUS 0
--
--   -- b. Badan dua fungsi sensitif TIDAK berubah sesudah migrasi (cek runtime):
--   SELECT proname, md5(pg_get_functiondef(oid)) AS sidik
--     FROM pg_proc
--    WHERE proname IN ('set_inquiry_won_on_so','set_customer_on_inquiry_won')
--    ORDER BY proname;
--   -- Jalankan SEBELUM dan SESUDAH migrasi ini — kedua sidik HARUS identik.
--
--   -- c. Enam kolom ada, semuanya nullable, nol default
--   SELECT column_name, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='inquiries'
--      AND column_name IN ('closed_at','closed_by','loss_reason_id',
--                          'competitor_name','competitor_price','cancel_reason')
--    ORDER BY column_name;
--   -- HARUS: 6 baris, is_nullable=YES semua, column_default NULL semua
--
--   -- d. Kolom lama lost_reason MASIH ADA (tidak di-drop)
--   SELECT count(*) FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='inquiries' AND column_name='lost_reason';
--   -- HARUS 1
--
--   -- e. Stempel penutupan jalan untuk jalur MANUAL — bungkus ROLLBACK:
--   BEGIN;
--     UPDATE public.inquiries SET status='CANCELLED', cancel_reason='uji rollback'
--      WHERE id=(SELECT id FROM public.inquiries WHERE status='OPEN' LIMIT 1);
--     SELECT status, closed_at IS NOT NULL AS ada_closed_at, cancel_reason
--       FROM public.inquiries WHERE status='CANCELLED' ORDER BY closed_at DESC LIMIT 1;
--     -- HARAPAN: ada_closed_at = true
--     SELECT from_status, to_status, reason FROM public.inquiry_status_history
--      ORDER BY changed_at DESC LIMIT 1;
--     -- HARAPAN: OPEN -> CANCELLED, reason = 'uji rollback'
--   ROLLBACK;
--
--   -- f. Stempel penutupan jalan untuk jalur WON OTOMATIS (lewat sales_orders),
--   --    TANPA menyentuh trg_inquiry_won — bungkus ROLLBACK:
--   BEGIN;
--     UPDATE public.sales_orders SET status='SENT' WHERE id='<SO_ID_DRAFT>';
--     SELECT i.status, i.closed_at IS NOT NULL AS ada_closed_at, i.closed_by
--       FROM public.inquiries i
--       JOIN public.sales_orders so ON so.inquiry_id = i.id
--      WHERE so.id='<SO_ID_DRAFT>';
--     -- HARAPAN: status=WON, ada_closed_at=true — tanpa ada yang mengklik apa pun
--   ROLLBACK;
--
--   -- g. Kolom baru TIDAK mengganggu kosakata status
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname='inquiries_status_check';
--   -- HARUS tetap 7 nilai: OPEN/IN_REVIEW/QUOTED/NEGOTIATION/WON/LOST/CANCELLED
--
-- ═════════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═════════════════════════════════════════════════════════════════════════════
--   ⚠️ Kembalikan fungsi log_inquiry_status_change() ke versi 20260828000001
--      (yang `reason`-nya NULL) SEBELUM men-drop kolomnya — kalau tidak, trigger
--      riwayat akan merujuk kolom yang sudah hilang dan mematikan seluruh
--      update status inquiries.
--   1. CREATE OR REPLACE FUNCTION public.log_inquiry_status_change() ...
--      -- salin verbatim dari 20260828000001 STEP 3
--   2. DROP TRIGGER IF EXISTS trg_z_stamp_inquiry_closure ON public.inquiries;
--      DROP FUNCTION IF EXISTS public.stamp_inquiry_closure();
--   3. DROP INDEX IF EXISTS public.idx_inquiries_closed_at;
--      ALTER TABLE public.inquiries
--        DROP CONSTRAINT IF EXISTS inquiries_closed_by_fkey,
--        DROP CONSTRAINT IF EXISTS inquiries_loss_reason_id_fkey;
--      ALTER TABLE public.inquiries
--        DROP COLUMN IF EXISTS closed_at,        DROP COLUMN IF EXISTS closed_by,
--        DROP COLUMN IF EXISTS loss_reason_id,   DROP COLUMN IF EXISTS competitor_name,
--        DROP COLUMN IF EXISTS competitor_price, DROP COLUMN IF EXISTS cancel_reason;
--   4. COMMENT ON COLUMN public.inquiries.lost_reason IS NULL;

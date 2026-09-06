-- =============================================================================
-- Migration: 20260907000002_accounts_lifecycle_drop_legacy
-- Batch:     CRM v3 — penutup lifecycle JALUR B
-- Depends:   20260907000001_accounts_lifecycle_dual_write (WAJIB sudah LIVE)
--
-- ⛔⛔⛔ JANGAN DIJALANKAN SEKARANG ⛔⛔⛔
--
--   File ini men-DROP accounts.account_status. Ia ditulis SEKARANG supaya tidak
--   terlupa, dan ditahan di sini supaya tidak dijalankan terlalu dini. Kedua
--   risiko itu nyata; yang kedua lebih mahal.
--
--   PRASYARAT — KETIGANYA WAJIB, tanpa kecuali:
--     1. 20260907000001 sudah LIVE di produksi dan terverifikasi.
--     2. Branch feature/crm-v3-batch-persiapan sudah DI-MERGE ke `main`.
--     3. Hasil merge itu sudah BERJALAN STABIL di produksi.
--
--   Menjalankannya sebelum (2) mengulang PERSIS kegagalan yang membuat
--   20260827000002 ditolak dan melahirkan jalur B: kolom account_status lenyap
--   sementara kode yang sedang melayani produksi masih membacanya. Bedanya cuma
--   waktu — akibatnya identik.
--
--   PRA-CEK WAJIB — jalankan di working tree `main` PASCA-MERGE.
--   Kalau hasilnya BUKAN nol, BERHENTI:
--     grep -rn "account_status" src/ | grep -v "^\s*//"          -- harus nihil
--     grep -rn "account_status" supabase/functions/              -- harus nihil
--
--   PRA-CEK DB — harus 0, kalau bukan 0 BERHENTI:
--     SELECT count(*) FILTER (WHERE lifecycle_stage IS DISTINCT FROM account_status)
--       FROM public.accounts;
--     -- Kedua kolom harus identik sebelum salah satunya dibuang. Kalau ada
--     -- selisih, trg_a_ tidak bekerja sebagaimana mestinya — selidiki dulu,
--     -- jangan tutupi dengan men-drop kolomnya.
--
-- CATATAN URUTAN DI DALAM FILE INI
--   Trigger sinkron dicabut LEBIH DULU, lalu fungsi disederhanakan, baru kolom
--   di-drop — seluruhnya dalam SATU transaksi. Tidak ada jendela di mana
--   account_status masih ada tapi sudah berhenti disinkronkan: kalau transaksi
--   gagal di tengah, semuanya ter-rollback bersama.
-- =============================================================================

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Cabut sinkronisasi
-- ═════════════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS trg_a_sync_lifecycle_columns ON public.accounts;
DROP FUNCTION IF EXISTS public.sync_lifecycle_columns();


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Sederhanakan keempat fungsi: satu kolom saja
-- ═════════════════════════════════════════════════════════════════════════════
-- ── 2a. set_customer_on_inquiry_won ──────────────────────────────────────────
-- Guard kembali ke SATU kolom. Kondisi ganda di 20260907000001 ada khusus untuk
-- masa transisi (menjaga idempotensi kalau invarian dua-kolom patah); sesudah
-- account_status hilang, invarian itu tak punya arti lagi.
CREATE OR REPLACE FUNCTION public.set_customer_on_inquiry_won() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_account_id uuid;
BEGIN
  IF NEW.status <> 'WON' THEN RETURN NEW; END IF;
  IF NEW.deleted_at IS NOT NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'WON' THEN RETURN NEW; END IF;

  v_account_id := COALESCE(NEW.prospect_id, NEW.customer_id);
  IF v_account_id IS NULL THEN RETURN NEW; END IF;

  UPDATE public.accounts
  SET lifecycle_stage    = 'customer',
      became_customer_at = COALESCE(became_customer_at, now()),
      converted_at       = COALESCE(converted_at, now())
  WHERE id = v_account_id
    AND COALESCE(lifecycle_stage,'') <> 'customer'
    AND deleted_at IS NULL;

  RETURN NEW;
END;
$$;

-- ── 2b. set_customer_on_won ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_customer_on_won() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.pipeline_stage = 'WON' AND COALESCE(NEW.lifecycle_stage,'') <> 'customer' THEN
    NEW.lifecycle_stage    := 'customer';
    NEW.became_customer_at := COALESCE(NEW.became_customer_at, now());
    NEW.converted_at       := COALESCE(NEW.converted_at, now());
  END IF;
  RETURN NEW;
END;
$$;

-- ── 2c. set_prospect_on_inquiry ──────────────────────────────────────────────
-- ⛔ DAFTAR TAHAP TETAP ('lead','mql','sql'). Penyempitan ke ('lead','mql')
--    adalah Keputusan Terbuka #36 dan punya migrasinya SENDIRI, dijalankan
--    setelah branch merge & stabil. JANGAN diselundupkan ke sini — file ini
--    migrasi struktural, dan menumpangkan perubahan perilaku bisnis padanya
--    adalah kesalahan yang sama yang membuat 20260827000002 ditolak.
CREATE OR REPLACE FUNCTION public.set_prospect_on_inquiry() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.accounts
  SET lifecycle_stage = 'prospect'
  WHERE id = COALESCE(NEW.prospect_id, NEW.customer_id)
    AND lifecycle_stage IN ('lead','mql','sql');
  RETURN NEW;
END;
$$;

-- ── 2d. generate_customer_code ───────────────────────────────────────────────
-- COALESCE dua kolom tidak lagi perlu: hanya satu kolom yang tersisa.
CREATE OR REPLACE FUNCTION public.generate_customer_code() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  yr int := extract(year from coalesce(NEW.created_at, now()))::int;
  next_num int;
  prefix text;
  ckey text;
begin
  if NEW.lifecycle_stage = 'customer' and (NEW.code is null or NEW.code = '') then
    select code into prefix from public.companies
      where id = coalesce(NEW.owner_company_id, NEW.company_id);
    if prefix is null or prefix = '' then prefix := 'MSI'; end if;

    ckey := prefix || '-CUST';
    insert into public.code_counters (entity, year, last_number)
    values (ckey, yr, 1)
    on conflict (entity, year)
    do update set last_number = public.code_counters.last_number + 1
    returning last_number into next_num;

    NEW.code := prefix || '/CUST/' || yr || '/' || int_to_roman(next_num);
  end if;
  return NEW;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Drop kolom lama
-- ═════════════════════════════════════════════════════════════════════════════
-- CONSTRAINT accounts_account_status_check ikut terhapus bersama kolomnya —
-- tidak perlu di-drop terpisah.
ALTER TABLE public.accounts DROP COLUMN account_status;


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Baru sekarang default dipasang
-- ═════════════════════════════════════════════════════════════════════════════
-- Selama transisi lifecycle_stage SENGAJA tanpa default — NULL adalah penanda
-- provenance yang dipakai trigger sinkron (lihat kepala 20260907000001).
-- Triggernya sudah dicabut di langkah 1, jadi penanda itu tak dibutuhkan lagi
-- dan bentuk akhirnya bisa disamakan dengan kolom lama: DEFAULT 'lead'.
ALTER TABLE public.accounts ALTER COLUMN lifecycle_stage SET DEFAULT 'lead';

COMMENT ON COLUMN public.accounts.lifecycle_stage IS
  'Sumbu LIFECYCLE akun. Urutan: lead -> mql -> prospect -> sql -> customer. Dua exit manual dari tahap mana pun: free_agent, lost. Menggantikan account_status, yang di-drop 20260907000002 setelah masa transisi dua-kolom.';

COMMIT;


-- ═════════════════════════════════════════════════════════════════════════════
-- VERIFIKASI (jalankan TERPISAH sesudahnya)
-- ═════════════════════════════════════════════════════════════════════════════
--   -- a. Kolom lama benar-benar hilang, kolom baru ber-default
--   SELECT column_name, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='accounts'
--      AND column_name IN ('account_status','lifecycle_stage');
--   -- HARAPAN: 1 baris — lifecycle_stage, default 'lead'::character varying
--
--   -- b. Nol fungsi yang masih menyebut nama lama
--   SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND pg_get_functiondef(p.oid) ILIKE '%account_status%';
--   -- HARUS 0 baris
--
--   -- c. Nol policy yang masih menyebut nama lama
--   SELECT policyname, tablename FROM pg_policies
--    WHERE schemaname='public'
--      AND (qual ILIKE '%account_status%' OR with_check ILIKE '%account_status%');
--   -- HARUS 0 baris
--
--   -- d. Trigger sinkron benar-benar tercabut
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid='public.accounts'::regclass AND NOT tgisinternal ORDER BY tgname;
--   -- HARAPAN: trg_a_sync_lifecycle_columns TIDAK ADA lagi;
--   --          trg_z_log_lifecycle_change TETAP ADA
--
--   -- e. set_prospect_on_inquiry masih bertiga tahap
--   SELECT pg_get_functiondef(oid) ILIKE '%''lead'',''mql'',''sql''%' AS tiga_tahap_utuh
--     FROM pg_proc WHERE proname='set_prospect_on_inquiry';
--   -- HARUS true
--
--   -- f. Riwayat masih bekerja — bungkus ROLLBACK:
--   --  BEGIN;
--   --    UPDATE public.accounts SET lifecycle_stage='mql'
--   --     WHERE id=(SELECT id FROM public.accounts WHERE lifecycle_stage='lead' LIMIT 1);
--   --    SELECT from_stage, to_stage FROM public.account_lifecycle_history
--   --     ORDER BY changed_at DESC LIMIT 1;         -- HARUS lead -> mql
--   --  ROLLBACK;
--
-- ═════════════════════════════════════════════════════════════════════════════
-- PEKERJAAN FE YANG MENYERTAI
-- ═════════════════════════════════════════════════════════════════════════════
--   src/hooks/useCustomFields.js:33 — selama transisi daftarnya memuat KEDUA
--   nama kolom. Sesudah migrasi ini, 'account_status' dicabut dari daftar itu
--   dan hanya 'lifecycle_stage' yang tersisa.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═════════════════════════════════════════════════════════════════════════════
--   ⚠️ MAHAL. Men-drop kolom membuang datanya; mengembalikannya berarti
--      merekonstruksi account_status dari lifecycle_stage. Itu BISA dilakukan
--      (keduanya identik saat di-drop), tapi hanya benar bila belum ada
--      perubahan lifecycle sesudahnya.
--   1. ALTER TABLE public.accounts ADD COLUMN account_status character varying(50)
--        DEFAULT 'lead'::character varying;
--      UPDATE public.accounts SET account_status = lifecycle_stage;
--      ALTER TABLE public.accounts ADD CONSTRAINT accounts_account_status_check
--        CHECK (((account_status)::text = ANY ((ARRAY['lead','mql','sql','prospect',
--          'customer','free_agent','lost']::character varying[])::text[])));
--   2. Pasang ulang seluruh isi 20260907000001 STEP 2, 3, 4.
--   3. ALTER TABLE public.accounts ALTER COLUMN lifecycle_stage DROP DEFAULT;

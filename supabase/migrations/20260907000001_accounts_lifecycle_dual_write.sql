-- =============================================================================
-- Migration: 20260907000001_accounts_lifecycle_dual_write
-- Batch:     CRM v3 — lifecycle JALUR B (pengganti 20260827000002)
-- Depends:   accounts · profiles · 20260827000001_crm_v3_master_data (LIVE 6 Sep 2026)
-- Status:    ✅✅ LIVE DI PRODUKSI — 7 Sep 2026 (ref untmpqceexwxzuhlmyrg),
--            dijalankan manual oleh Den di Supabase SQL Editor.
--            ⛔ JANGAN DIJALANKAN ULANG. ADD COLUMN-nya akan gagal, dan kalau
--               dipaksa lewat DROP dulu, seluruh riwayat lifecycle hilang.
--
--            BUKTI VERIFIKASI PRODUKSI:
--              · 1.258 akun, kedua kolom IDENTIK (beda = 0)
--              · backfill riwayat 1.258 = 1.258 akun (nol akun ber-stage NULL)
--              · 6 trigger di accounts, trg_a_sync_lifecycle_columns di urutan
--                PERTAMA — sebelum trg_set_customer_on_won yang membacanya
--              · set_prospect_on_inquiry TIGA TAHAP UTUH ('lead','mql','sql')
--                di KEDUA kolom → penyempitan Keputusan Terbuka #36 TIDAK
--                terselundup
--              · default asimetris benar: account_status DEFAULT 'lead',
--                lifecycle_stage TANPA default
--            Snapshot: schema_snapshot.sql commit c8c67f6 (138 tabel public).
--
--            ⏭️ Penutupnya 20260907000002_accounts_lifecycle_drop_legacy BELUM
--            dijalankan dan memang belum boleh — ia ber-⛔ STOP dan menunggu
--            branch merge ke main + stabil di produksi. Sampai itu terjadi,
--            account_status SENGAJA masih ada dan disinkronkan.
--
-- ── JEJAK: bagaimana ia terbukti SEBELUM naik ke produksi ───────────────────
--            ✅ TERVERIFIKASI PENUH DI STAGING — 7 Sep 2026 (ref oovmlhilhqzejnawqkvt),
--            dijalankan lebih dulu di sana dan lolos seluruhnya. Catatan di
--            bawah SENGAJA DIPERTAHANKAN: ia rekaman bagaimana migrasi ini
--            dibuktikan sebelum menyentuh produksi, bukan sisa yang bisa
--            dihapus setelah LIVE.
--
--            JALAN UJI: T0 rekam keadaan -> T1 kembalikan staging ke bentuk
--            produksi (drop account_lifecycle_history + rename lifecycle_stage
--            balik jadi account_status) -> T1b kembalikan empat fungsi ke badan
--            produksi -> T2 jalankan kelima STEP file ini VERBATIM -> 11 uji.
--
--            HASIL STRUKTUR:
--              · STEP 1 — 7 akun, kedua kolom identik, nol NULL
--              · STEP 2 — 6 trigger di accounts, dan trg_a_sync_lifecycle_columns
--                TERBUKTI berada di urutan PERTAMA, sebelum trg_set_customer_on_won
--                yang membacanya. ⭐ Asumsi prefix trg_a_ (lihat STEP 2) kini
--                TERUJI, bukan lagi penalaran urutan alfabetis di atas kertas.
--              · STEP 5 — backfill riwayat 7 baris = 7 akun, nol akun ber-stage NULL
--              · Default ASIMETRIS terpasang benar: account_status DEFAULT 'lead',
--                lifecycle_stage DEFAULT NULL (lihat kepala soal kenapa asimetris)
--
--            HASIL 11 UJI PERILAKU — seluruhnya LOLOS:
--              0. tulis nilai SAMA ke kolom lama -> NOL baris riwayat baru.
--                 Jaring `IS DISTINCT FROM` di STEP 2 bekerja.
--              1. account_status='mql'    -> kedua kolom mql, riwayat prospect->mql
--              2. lifecycle_stage='sql'   -> kedua kolom sql
--              3. UPDATE name             -> kedua kolom tetap, NOL riwayat
--              4. INSERT lewat kolom lama -> customer + kode ter-generate
--              5. INSERT lewat kolom baru -> customer + kode ter-generate
--              6. INSERT tanpa keduanya   -> lead + NULL
--                 (4/5/6 sekaligus membuktikan tiga hal: default asimetris benar,
--                  sinkron INSERT dua arah benar, dan generate_customer_code
--                  ber-COALESCE menyala di KEDUA jalur)
--              7. pipeline_stage='WON'    -> kedua kolom customer, kode ter-generate,
--                                            became_customer_at terisi
--              8. ⭐ akun ber-tahap 'sql' + inquiry baru -> kedua kolom 'prospect'.
--                 PENYEMPITAN Keputusan Terbuka #36 TERBUKTI TIDAK TERBAWA.
--              9. inquiry ke WON          -> kedua kolom customer
--             10. backfill riwayat        -> 7 = 7
--
--            KEBERSIHAN: seluruh uji ber-ROLLBACK bersih, termasuk code_counters
--            yang kembali ke last_number=1. Nol akun ZZZTEST tersisa, nol inquiry
--            uji tersisa.
--
--            ⚠️ STAGING SENGAJA DITINGGAL DI KEADAAN TRANSISI (dua kolom, sinkron)
--            — itu persis keadaan yang akan dialami produksi dan yang dibutuhkan
--            FE branch. TIDAK dibersihkan; jangan "dirapikan" jadi satu kolom.
--
--            ⚠️ BIAYA YANG DITERIMA: 4 baris riwayat transisi NYATA di staging
--            hilang permanen saat T1 men-drop account_lifecycle_history (8 baris
--            -> 7 sesudah backfill ulang). Isinya terekam lebih dulu di T0.2.
--            Ini staging, konsekuensinya diterima — di PRODUKSI T1 tidak berlaku
--            sama sekali (produksi belum pernah punya tabel itu).
--
-- KENAPA FILE INI ADA
--   20260827000002_crm_v3_lifecycle me-RENAME accounts.account_status ->
--   lifecycle_stage. Begitu jalan, kolom lama LENYAP SEKETIKA, sedangkan `main`
--   yang sedang melayani produksi masih membacanya di 14 file / 29 baris hidup.
--   Produksi patah SEBELUM branch di-merge. Keputusan Terbuka #35 dijawab
--   JALUR B: tambah kolom + sinkron dua arah, drop kolom lama belakangan.
--   Migrasi lama TIDAK akan pernah dijalankan; kepalanya sudah membawa ⛔ STOP.
--   Penutupnya: 20260907000002_accounts_lifecycle_drop_legacy.
--
-- ⚠️ TIDAK ADA ATURAN TIE-BREAK DI TRIGGER SINKRON — DAN ITU DISENGAJA.
--   Diukur 7 Sep 2026 (grep dua arah, kedua branch): NOL jalur tulis menyentuh
--   account_status DAN lifecycle_stage sekaligus. Kedua sisi buta terhadap
--   kolom seberang — `main` nol file menyebut lifecycle_stage, branch nol file
--   menyebut account_status. Ketiga titik tulis FE bahkan baris yang SAMA di
--   file yang sama (db.js:266 · CustomerListPage.jsx:373 ·
--   ProspectFormPage.jsx:282 di main / :278 di branch), hanya berganti nama
--   kolom. Ketiga fungsi DB penulis (set_customer_on_inquiry_won,
--   set_customer_on_won, set_prospect_on_inquiry) juga menulis satu kolom saja
--   sebelum migrasi ini.
--   JANGAN menambahkan tie-break "untuk jaga-jaga". Menambahkannya berarti
--   menuliskan aturan untuk keadaan yang tak bisa terjadi, dan aturan itu akan
--   MENYEMBUNYIKAN bug kalau keadaan itu suatu saat benar-benar terjadi —
--   padahal kemunculannya justru sinyal bahwa asumsi migrasi ini gugur dan
--   triggernya harus ditinjau ulang, bukan ditambal.
--
-- ⚠️ DEFAULT — jangan "dirapikan" jadi simetris.
--   account_status TETAP DEFAULT 'lead' (produksi tak berubah).
--   lifecycle_stage SENGAJA TANPA DEFAULT selama transisi.
--   Alasannya bukan kerapian: PostgreSQL menerapkan DEFAULT SEBELUM BEFORE-
--   trigger jalan. Kalau kedua kolom ber-default 'lead', maka pada INSERT dari
--   db.js:266 (account_status='customer', lifecycle_stage tak diisi) trigger
--   menerima NEW.lifecycle_stage = 'lead' — BUKAN NULL — dan tak punya cara
--   membedakan "pemanggil tak mengisi kolom ini" dari "pemanggil menulis
--   'lead'". Sinkronisasi INSERT jadi salah secara DIAM-DIAM.
--   NULL adalah satu-satunya penanda provenance yang tersedia.
--   DEFAULT 'lead' dipasang pada lifecycle_stage di 20260907000002, saat
--   account_status di-drop — bentuk akhirnya sama dengan staging hari ini.
--
-- PRA-CEK (informatif, tidak memblokir):
--   SELECT count(*) FILTER (WHERE account_status IS NULL) FROM public.accounts;
--   -- produksi 7 Sep 2026: 0. Kalau > 0, baris itu akan ber-lifecycle_stage
--   -- NULL juga dan TIDAK mendapat baris riwayat di STEP 5 (lihat catatannya).
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 1 — Kolom baru + salin isi + CHECK
-- ═════════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.accounts
  ADD COLUMN lifecycle_stage character varying(50);

UPDATE public.accounts SET lifecycle_stage = account_status;

-- Bentuk CHECK disalin dari accounts_account_status_check yang hidup di
-- produksi (schema_snapshot.sql, CONSTRAINT accounts_account_status_check).
-- NULL lolos dengan sendirinya — ekspresinya bernilai NULL, bukan FALSE —
-- sama persis dengan kolom lama, yang juga nullable.
ALTER TABLE public.accounts
  ADD CONSTRAINT accounts_lifecycle_stage_check
  CHECK (((lifecycle_stage)::text = ANY ((ARRAY[
    'lead'::character varying,       'mql'::character varying,
    'sql'::character varying,        'prospect'::character varying,
    'customer'::character varying,   'free_agent'::character varying,
    'lost'::character varying])::text[])));

-- ⚠️ URUTAN TAHAP SENGAJA TIDAK DINYATAKAN DI COMMENT INI — ia sedang jadi
--    PERTANYAAN TERBUKA dan dua sumber saling bertentangan:
--      (i)  05_WORKFLOW_MAP.md:124 (18 Jul 2026, menggambarkan perilaku LIVE)
--           menyebut `lead/mql/sql -> prospect` sebagai PROMOSI, yang hanya
--           masuk akal bila `sql` berada DI BAWAH `prospect`.
--      (ii) src/modules/crm/v3/tokens.js:76 dan migrasi 20260827000002:93/:114
--           menyatakan "URUTAN BARU (keputusan Den, batch persiapan CRM v3):
--           lead -> mql -> prospect -> sql -> customer", yaitu `sql` DI ATAS
--           `prospect`.
--    Pertentangan ini sudah ditandai sejak 22 Jul 2026
--    (docs/archive/audits/AUDIT_CRM_CHAIN_20260722.md:756 dan :811) dan BELUM
--    PERNAH DIJAWAB di governance.
--    COMMENT kolom adalah rujukan PERMANEN di skema produksi. Menuliskan salah
--    satu urutan di sini berarti menetapkan pemenang lewat komentar migrasi —
--    tempat yang salah untuk memutuskannya. Isi urutannya SETELAH pertanyaan
--    terbukanya dijawab. Urutan CHECK/array di skema maupun FE BUKAN bukti:
--    itu daftar keanggotaan, bukan pernyataan urutan.
COMMENT ON COLUMN public.accounts.lifecycle_stage IS
  'Sumbu LIFECYCLE akun. Tujuh nilai: lead, mql, sql, prospect, customer, free_agent, lost. Gerbang yang HIDUP: akun jadi prospect hanya bila ada inquiry masuk (trigger set_prospect_on_inquiry); jadi customer lewat WON. free_agent dan lost adalah exit manual dari tahap mana pun. ⚠️ URUTAN tahapnya masih PERTANYAAN TERBUKA (dua sumber bertentangan — lihat komentar di migrasi 20260907000001); jangan simpulkan urutan dari daftar nilai di atas maupun dari urutan CHECK. Berdampingan dengan account_status selama transisi jalur B; disinkronkan trg_a_sync_lifecycle_columns. TANPA default selama transisi. account_status di-drop di 20260907000002.';

COMMENT ON COLUMN public.accounts.account_status IS
  'DIPENSIUNKAN sejak 7 Sep 2026 — digantikan lifecycle_stage. Selama transisi keduanya disinkronkan otomatis: tulis ke salah satu, yang lain ikut. Di-drop di migrasi 20260907000002 setelah branch CRM v3 merge & stabil di produksi.';

COMMIT;

-- VERIFIKASI STEP 1:
--   SELECT count(*)                                        AS total,
--          count(*) FILTER (WHERE lifecycle_stage IS NULL)  AS lc_null,
--          count(*) FILTER (WHERE account_status  IS NULL)  AS as_null,
--          count(*) FILTER (WHERE lifecycle_stage IS DISTINCT FROM account_status) AS beda
--     FROM public.accounts;
--   -- HARAPAN: beda = 0 · lc_null = as_null (produksi: keduanya 0)


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 2 — Trigger sinkron dua arah
-- ═════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.sync_lifecycle_columns() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- lifecycle_stage TANPA default, jadi NULL di sini berarti "pemanggil tidak
    -- mengisi kolom baru" -> ia memakai kolom lama (atau tak mengisi apa pun,
    -- sehingga account_status sudah berisi DEFAULT 'lead').
    IF NEW.lifecycle_stage IS NULL THEN
      NEW.lifecycle_stage := NEW.account_status;
    ELSE
      NEW.account_status  := NEW.lifecycle_stage;
    END IF;
    RETURN NEW;
  END IF;

  -- ── UPDATE ────────────────────────────────────────────────────────────────
  -- DUA IF INDEPENDEN, bukan IF/ELSIF. ELSIF adalah tie-break terselubung
  -- ("kolom lama menang"), dan tie-break memang TIDAK diperlukan di sini —
  -- lihat kepala migrasi untuk faktanya (nol jalur menulis dua-duanya).
  --
  -- ⚠️ UPDATE yang menyentuh kolom LAIN saja (mis. SET name='X'):
  --    kedua kondisi di bawah bernilai FALSE, karena untuk kolom yang tidak
  --    disebut statement, NEW.<kolom> = OLD.<kolom>. Trigger TIDAK mengubah
  --    apa pun dan tidak menstempel ulang nilai apa pun.
  --    Ini bukan detail kosmetik: kalau ditulis dengan COALESCE polos tanpa
  --    pembandingan ke OLD, SETIAP update apa pun akan "menulis ulang" kedua
  --    kolom, dan trg_z_log_lifecycle_change akan mencatat baris riwayat untuk
  --    perubahan yang tidak pernah terjadi.
  --    Hal yang sama berlaku untuk UPDATE yang menulis nilai SAMA ke kolom
  --    lifecycle (SET account_status = account_status): IS DISTINCT FROM
  --    bernilai false, jadi nol riwayat. Ada uji khusus untuk ini (uji 0).
  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    NEW.lifecycle_stage := NEW.account_status;
  END IF;

  IF NEW.lifecycle_stage IS DISTINCT FROM OLD.lifecycle_stage THEN
    NEW.account_status := NEW.lifecycle_stage;
  END IF;

  -- Catatan urutan: kalau blok pertama menyala, blok kedua ikut menyala dan
  -- menulis nilai yang SAMA — no-op yang tidak berbahaya. Kalau suatu hari
  -- sebuah statement menulis KEDUA kolom dengan nilai BERBEDA (hari ini nol
  -- jalur seperti itu), hasilnya account_status yang menang. Itu KONSEKUENSI
  -- urutan, BUKAN aturan yang dirancang — dan kemunculannya adalah tanda
  -- asumsi migrasi ini gugur. Tinjau ulang, jangan tambal.
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_lifecycle_columns() IS
  'Menjaga accounts.account_status dan accounts.lifecycle_stage identik selama transisi jalur B. Sengaja tanpa tie-break: nol jalur tulis menyentuh keduanya (diukur 7 Sep 2026). Dicabut oleh migrasi 20260907000002.';

-- ⚠️ PREFIX trg_a_, BUKAN trg_z_ — SENGAJA, dan ini KEBALIKAN dari konvensi
--    CLAUDE.md. Konvensi trg_z_ ada supaya trigger jalan TERAKHIR. Di sini
--    kebutuhannya justru PERTAMA: trigger bisnis di belakangnya membaca
--    lifecycle_stage dan harus melihat nilai yang sudah sinkron.
--    Urutan trigger BEFORE di accounts sesudah migrasi ini (alfabetis):
--      trg_a_sync_lifecycle_columns   <- INI, harus pertama
--      trg_gen_customer_code_ins
--      trg_set_customer_on_won        <- membaca lifecycle_stage
--      trg_z_gen_customer_code_upd
--      trg_z_track_stage_change
--    Tanpa prefix ini, UPDATE dari kode `main` (yang hanya menulis
--    account_status) akan membuat set_customer_on_won membaca lifecycle_stage
--    yang MASIH BERNILAI LAMA.
CREATE TRIGGER trg_a_sync_lifecycle_columns
  BEFORE INSERT OR UPDATE ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.sync_lifecycle_columns();

COMMIT;

-- VERIFIKASI STEP 2:
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid='public.accounts'::regclass AND NOT tgisinternal
--    ORDER BY tgname;
--   -- HARAPAN: trg_a_sync_lifecycle_columns ada di BARIS PERTAMA


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 3 — Tiga fungsi penulis: baca kolom baru, tulis KEDUANYA
-- ═════════════════════════════════════════════════════════════════════════════
-- Badan ketiganya disalin dari schema_snapshot.sql versi PRODUKSI, BUKAN dari
-- migrasi 20260827000002. Satu-satunya perubahan: kolom yang dibaca/ditulis.
BEGIN;

-- ── 3a. set_customer_on_inquiry_won ──────────────────────────────────────────
-- ⚠️ ANALISIS URUTAN — guard di WHERE membaca nilai PRA-SINKRON. Diperiksa,
--    dan tetap aman. Alasannya harus dibaca sebelum menyentuh baris ini:
--
--    Fungsi ini trigger di tabel `inquiries`, bukan `accounts`. Ia mengirim
--    UPDATE ke `accounts`; klausa WHERE-nya dievaluasi saat PEMILIHAN BARIS,
--    yaitu SEBELUM trg_a_sync_lifecycle_columns menyala untuk baris itu.
--    Jadi guard memang membaca lifecycle_stage versi pra-sinkron.
--
--    Kenapa itu tidak jadi celah: setiap baris `accounts` yang sudah ter-commit
--    DIJAMIN punya kedua kolom identik. Invarian itu ditegakkan dua kali —
--    STEP 1 menyalin seluruh baris lama (UPDATE ... SET lifecycle_stage =
--    account_status), dan trg_a_ menyinkronkan setiap tulisan sesudahnya.
--    Tidak ada jendela di mana baris ter-commit punya kedua kolom berbeda,
--    jadi "nilai pra-sinkron" dan "nilai pasca-sinkron" adalah nilai yang sama.
--
--    MESKIPUN BEGITU guard di bawah memeriksa KEDUA kolom, bukan satu.
--    Bukan karena analisis di atas meragukan, melainkan karena guard ini
--    bertugas menjaga IDEMPOTENSI (jangan menstempel ulang became_customer_at/
--    converted_at). Kalau invariannya suatu hari patah — mis. seseorang
--    men-drop trg_a_ tanpa men-drop account_status — memeriksa keduanya membuat
--    fungsi ini gagal ke arah AMAN (melewatkan baris) alih-alih menstempel
--    ulang tanggal historis. Saat kedua kolom sinkron, kondisi tambahan ini
--    nol dampak.
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
  SET account_status     = 'customer',
      lifecycle_stage    = 'customer',
      became_customer_at = COALESCE(became_customer_at, now()),
      converted_at       = COALESCE(converted_at, now())
  WHERE id = v_account_id
    AND COALESCE(lifecycle_stage,'') <> 'customer'
    AND COALESCE(account_status,'')  <> 'customer'   -- lihat ANALISIS URUTAN
    AND deleted_at IS NULL;

  RETURN NEW;
END;
$$;

-- ── 3b. set_customer_on_won ──────────────────────────────────────────────────
-- BEFORE trigger di `accounts`, jadi ia menulis NEW.* dan tidak mengirim UPDATE
-- terpisah. Karena trg_a_ jalan lebih dulu (prefix a < s), NEW.lifecycle_stage
-- yang dibaca di sini SUDAH sinkron — termasuk saat pemanggil hanya menulis
-- account_status. Itulah alasan prefix trg_a_ ada.
CREATE OR REPLACE FUNCTION public.set_customer_on_won() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.pipeline_stage = 'WON' AND COALESCE(NEW.lifecycle_stage,'') <> 'customer' THEN
    NEW.account_status     := 'customer';
    NEW.lifecycle_stage    := 'customer';
    NEW.became_customer_at := COALESCE(NEW.became_customer_at, now());
    NEW.converted_at       := COALESCE(NEW.converted_at, now());
  END IF;
  RETURN NEW;
END;
$$;

-- ── 3c. set_prospect_on_inquiry ──────────────────────────────────────────────
-- ⛔ DAFTAR TAHAP DISALIN APA ADANYA DARI PRODUKSI: ('lead','mql','sql').
--    Migrasi lama 20260827000002 mempersempitnya jadi ('lead','mql') dan
--    headernya mengklaim itu disetujui Den. JANGAN DIBAWA KE SINI.
--    Penyempitan itu keputusan TERPISAH — Keputusan Terbuka #36, sudah dijawab
--    "isinya DISETUJUI tapi eksekusinya DIPISAH" — dan akan dijalankan sebagai
--    migrasi tersendiri SETELAH branch merge & stabil di produksi.
--    Menggabungkannya ke sini mengulang persis kesalahan yang membuat migrasi
--    lama ditolak: perubahan perilaku bisnis menumpang di migrasi struktural.
--    Uji 8 di blok PENGUJIAN di bawah ada khusus untuk membuktikan penyempitan
--    itu TIDAK ikut terbawa.
--    ⚠️ JARING DUA-KOLOM — SAMA seperti 3a, dan alasannya di sini LEBIH KUAT.
--    Fungsi ini sebentuk persis dengan 3a: trigger di `inquiries` yang mengirim
--    UPDATE ke `accounts`, dengan WHERE yang juga membaca lifecycle_stage
--    PRA-SINKRON (lihat ANALISIS URUTAN di 3a — analisisnya berlaku identik).
--    Bedanya pada mode kegagalan kalau invarian dua-kolom suatu hari patah:
--      3a gagal dengan menstempel ULANG tanggal historis (buruk);
--      3c gagal dengan MENURUNKAN akun `customer` menjadi `prospect` — kerusakan
--      data yang lebih berat, dan senyap.
--    Karena itu WHERE-nya menuntut KEDUA kolom berada di ketiga tahap sumber.
--    ⛔ DAFTAR TAHAP TETAP TIGA NILAI DI KEDUA KOLOM. Jangan sekali-kali
--       menyempitkan salah satunya jadi ('lead','mql') — itu Keputusan Terbuka
--       #36 yang punya migrasinya sendiri.
CREATE OR REPLACE FUNCTION public.set_prospect_on_inquiry() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.accounts
  SET account_status  = 'prospect',
      lifecycle_stage = 'prospect'
  WHERE id = COALESCE(NEW.prospect_id, NEW.customer_id)
    AND lifecycle_stage IN ('lead','mql','sql')
    AND account_status  IN ('lead','mql','sql');   -- jaring, lihat catatan di atas
  RETURN NEW;
END;
$$;

COMMIT;


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 4 — generate_customer_code: kondisi baca yang tahan urutan
-- ═════════════════════════════════════════════════════════════════════════════
-- Fungsi ini TIDAK menulis kolom lifecycle — ia hanya MEMBACANYA di kondisi,
-- lalu menulis NEW.code. Satu-satunya perubahan dari versi produksi adalah
-- kondisi `if`.
--
-- Kenapa COALESCE dan bukan sekadar mengganti nama kolom: dengan trg_a_ jalan
-- lebih dulu, kedua kolom sebenarnya sudah identik saat fungsi ini menyala,
-- jadi membaca salah satu saja sudah cukup HARI INI. COALESCE membuatnya benar
-- TANPA bergantung pada urutan trigger — kalau kelak ada yang menyisipkan
-- trigger baru atau mengubah nama sehingga urutannya bergeser, fungsi ini tidak
-- ikut patah. Kode customer yang gagal ter-generate adalah kegagalan senyap:
-- akun tersimpan tanpa kode, dan tak ada yang error.
BEGIN;

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
  if COALESCE(NEW.lifecycle_stage, NEW.account_status) = 'customer'
     and (NEW.code is null or NEW.code = '') then
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

COMMIT;


-- ═════════════════════════════════════════════════════════════════════════════
-- STEP 5 — Riwayat lifecycle + backfill
-- ═════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE public.account_lifecycle_history (
    id          uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id  uuid NOT NULL,
    from_stage  character varying(50),          -- NULL = tak ada riwayat sebelumnya
    to_stage    character varying(50) NOT NULL,
    reason      text,                           -- nullable; diisi mulai batch Account
    changed_by  uuid,                           -- NULL = perubahan oleh trigger sistem
    changed_at  timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_lifecycle_history_pkey PRIMARY KEY (id),
    CONSTRAINT alh_account_fkey FOREIGN KEY (account_id)
        REFERENCES public.accounts(id) ON DELETE CASCADE,
    CONSTRAINT alh_changed_by_fkey FOREIGN KEY (changed_by)
        REFERENCES public.profiles(id)
);

COMMENT ON TABLE public.account_lifecycle_history IS
  'Riwayat perubahan accounts.lifecycle_stage. Audit-only: ditulis EKSKLUSIF oleh trg_z_log_lifecycle_change (SECURITY DEFINER), nol policy tulis untuk authenticated.';
COMMENT ON COLUMN public.account_lifecycle_history.changed_by IS
  'auth.uid() saat perubahan. NULL bila perubahan datang dari trigger SECURITY DEFINER tanpa konteks user (mis. promosi otomatis dari inquiry).';

CREATE INDEX idx_alh_account_changed
  ON public.account_lifecycle_history (account_id, changed_at DESC);

ALTER TABLE public.account_lifecycle_history ENABLE ROW LEVEL SECURITY;

-- Delegasi ke RLS `accounts`: siapa yang boleh melihat akunnya, boleh melihat
-- riwayatnya. Subquery ke accounts TETAP tunduk pada RLS accounts sendiri,
-- jadi ini bukan USING(true) terselubung.
CREATE POLICY alh_read ON public.account_lifecycle_history
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.accounts a WHERE a.id = account_lifecycle_history.account_id));

-- ⚠️ SENGAJA TIDAK ADA policy INSERT/UPDATE/DELETE untuk `authenticated`.
--    Riwayat tidak boleh dikarang lewat PostgREST. GRANT juga hanya SELECT.
--    ⚠️ Lihat TD-229: insert riwayat ini ada di JALUR KRITIS setiap perubahan
--    lifecycle. Kalau kelak FORCE ROW LEVEL SECURITY dipasang di tabel ini,
--    atau kepemilikan fungsi berpindah dari postgres, SETIAP update lifecycle
--    akan mati. Fitur yang perlu menulis riwayat dari FE WAJIB lewat RPC
--    SECURITY DEFINER — JANGAN dengan melonggarkan GRANT.
GRANT SELECT ON TABLE public.account_lifecycle_history TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.account_lifecycle_history TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.account_lifecycle_history TO service_role;

CREATE OR REPLACE FUNCTION public.log_lifecycle_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.lifecycle_stage IS DISTINCT FROM OLD.lifecycle_stage THEN
    INSERT INTO account_lifecycle_history (account_id, from_stage, to_stage, changed_by)
    VALUES (NEW.id, OLD.lifecycle_stage, NEW.lifecycle_stage, auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

-- AFTER + prefix trg_z_: mencatat nilai FINAL, sesudah seluruh trigger BEFORE
-- selesai (termasuk set_customer_on_won yang masih bisa mengubah lifecycle).
-- Karena trg_a_ sinkron sudah jalan lebih dulu, tulisan lewat kolom LAMA pun
-- tercatat di sini — lifecycle_stage ikut berubah, jadi kondisinya menyala.
CREATE TRIGGER trg_z_log_lifecycle_change
  AFTER UPDATE ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.log_lifecycle_change();

-- CATATAN: tidak ada trigger lama yang "menulis lifecycle tanpa riwayat" untuk
-- dicabut. Diverifikasi: track_stage_change hanya menyentuh pipeline_stage.

-- Backfill 1 baris per akun. changed_by NULL: kita memang tidak tahu siapa yang
-- menaruh akun di tahap sekarang — data itu tak pernah direkam sebelum tabel ini
-- ada. Mengarangnya (mis. mengisi created_by) akan membuat riwayat berbohong.
--
-- ⚠️ AKUN ber-lifecycle_stage NULL: `to_stage` NOT NULL, jadi baris seperti itu
--    SENGAJA dilewati filter di bawah — ia tidak mendapat baris riwayat sampai
--    lifecycle-nya diisi pertama kali, dan transisi pertama itu nanti tercatat
--    dengan from_stage NULL. Produksi 7 Sep 2026 punya 0 baris seperti ini;
--    filter tetap ditulis supaya migrasi ini tidak gagal di environment yang
--    punya. KONSEKUENSINYA: verifikasi di bawah membandingkan riwayat dengan
--    "akun ber-stage", BUKAN dengan total akun.
INSERT INTO public.account_lifecycle_history (account_id, from_stage, to_stage, changed_by, changed_at)
SELECT id, NULL, lifecycle_stage, NULL, COALESCE(updated_at, created_at, now())
FROM public.accounts
WHERE lifecycle_stage IS NOT NULL;

COMMIT;


-- ═════════════════════════════════════════════════════════════════════════════
-- VERIFIKASI (jalankan TERPISAH sesudahnya)
-- ═════════════════════════════════════════════════════════════════════════════
--   -- a. Kedua kolom ada dan identik di SELURUH baris
--   SELECT count(*) FILTER (WHERE lifecycle_stage IS DISTINCT FROM account_status) AS beda
--     FROM public.accounts;                                        -- HARUS 0
--
--   -- b. lifecycle_stage TANPA default, account_status TETAP ber-default
--   SELECT column_name, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='accounts'
--      AND column_name IN ('account_status','lifecycle_stage') ORDER BY 1;
--   -- HARAPAN: account_status default 'lead'::character varying ·
--   --          lifecycle_stage default NULL · keduanya is_nullable=YES
--
--   -- c. Trigger sinkron ada DAN berada di urutan pertama
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid='public.accounts'::regclass AND NOT tgisinternal ORDER BY tgname;
--   -- HARAPAN 6 baris, trg_a_sync_lifecycle_columns PERTAMA
--
--   -- d. Backfill riwayat (relasional — lihat catatan NULL di STEP 5)
--   SELECT (SELECT count(*) FROM public.account_lifecycle_history)                  AS riwayat,
--          (SELECT count(*) FROM public.accounts WHERE lifecycle_stage IS NOT NULL) AS akun_ber_stage,
--          (SELECT count(*) FROM public.accounts WHERE lifecycle_stage IS NULL)     AS akun_null;
--   -- HARAPAN: riwayat = akun_ber_stage · akun_null = 0 (kalau > 0, catat angkanya)
--
--   -- e. set_prospect_on_inquiry TIDAK membawa penyempitan #36
--   SELECT pg_get_functiondef(oid) ILIKE '%''lead'',''mql'',''sql''%' AS tiga_tahap_utuh
--     FROM pg_proc WHERE proname='set_prospect_on_inquiry';
--   -- HARUS true
--
-- ═════════════════════════════════════════════════════════════════════════════
-- PENGUJIAN DI STAGING — staging sudah ter-RENAME, migrasi ini TIDAK bisa
-- dijalankan apa adanya di sana. Urutan T0 -> T1 -> T2.
-- ═════════════════════════════════════════════════════════════════════════════
--
-- ── T0. REKAM KEADAAN STAGING SEKARANG — WAJIB, T1 di bawah DESTRUKTIF ───────
--    T1 men-DROP account_lifecycle_history. Rekam dulu apa yang akan hilang;
--    staging cuma 7 akun jadi ini murah. SIMPAN HASILNYA di luar DB.
--
--    -- T0.1 jumlah + isi riwayat yang akan di-drop
--    SELECT count(*) AS baris_riwayat FROM public.account_lifecycle_history;
--    SELECT account_id, from_stage, to_stage, changed_by, changed_at
--      FROM public.account_lifecycle_history ORDER BY changed_at;
--
--    -- T0.2 lifecycle per akun (untuk dibandingkan sesudah T1 + migrasi)
--    SELECT id, name, lifecycle_stage, pipeline_stage, code, became_customer_at
--      FROM public.accounts ORDER BY name;
--    -- staging 7 akun: 5 customer, 2 prospect
--
--    -- T0.3 sidik-jari keempat fungsi SEBELUM disentuh
--    -- ⚠️⚠️ BACA SEBELUM MEMAKAI HASIL T0.3/T0.4 SEBAGAI TARGET PEMULIHAN —
--    --    JANGAN. Terbukti membingungkan saat verifikasi 7 Sep 2026.
--    --    md5 yang direkam di sini adalah versi PASCA-RENAME milik staging
--    --    (fungsi yang menulis lifecycle_stage), dan formatnya sudah berbeda
--    --    dari produksi. Mencocokkan hasil T1b ke angka ini akan SELALU gagal,
--    --    dan kegagalan itu PALSU.
--    --    PATOKAN YANG BENAR untuk T1b adalah badan fungsi di
--    --    schema_snapshot.sql PRODUKSI (`git show main:supabase/schema_snapshot.sql`),
--    --    dicocokkan BARIS PER BARIS — bukan lewat md5. Pada 7 Sep 2026
--    --    pencocokan itu dilakukan dan hasilnya COCOK.
--    --    T0.3 tetap berguna untuk SATU hal: bukti bahwa T1b benar-benar
--    --    mengubah keempat fungsi (md5 sesudah HARUS berbeda dari yang di sini).
--    SELECT proname, md5(pg_get_functiondef(oid)) AS sidik FROM pg_proc
--     WHERE proname IN ('generate_customer_code','set_customer_on_won',
--                       'set_customer_on_inquiry_won','set_prospect_on_inquiry')
--     ORDER BY proname;
--
--    -- T0.4 trigger yang ada sekarang
--    SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
--     WHERE tgrelid='public.accounts'::regclass AND NOT tgisinternal ORDER BY tgname;
--
-- ── T1. KEMBALIKAN STAGING KE BENTUK PRODUKSI (destruktif — T0 dulu!) ────────
--    BEGIN;
--      DROP TRIGGER IF EXISTS trg_z_log_lifecycle_change ON public.accounts;
--      DROP FUNCTION IF EXISTS public.log_lifecycle_change();
--      DROP TABLE IF EXISTS public.account_lifecycle_history;
--      ALTER TABLE public.accounts RENAME COLUMN lifecycle_stage TO account_status;
--      ALTER TABLE public.accounts
--        RENAME CONSTRAINT accounts_lifecycle_stage_check TO accounts_account_status_check;
--    COMMIT;
--
--    Lalu kembalikan KEEMPAT fungsi ke badan PRODUKSI — salin verbatim dari
--    `git show main:supabase/schema_snapshot.sql`, fungsi generate_customer_code,
--    set_customer_on_won, set_customer_on_inquiry_won, set_prospect_on_inquiry
--    (semuanya versi yang menulis account_status saja).
--
--    VERIFIKASI T1:
--      SELECT column_name FROM information_schema.columns
--       WHERE table_name='accounts' AND column_name IN ('account_status','lifecycle_stage');
--      -- HARUS: hanya account_status
--
-- ── T2. Jalankan migrasi ini VERBATIM, lalu uji ──────────────────────────────
--    Uji 0-3 dan 7-9 bungkus BEGIN; ... ROLLBACK;. Uji 4-6 menyisakan baris —
--    hapus dengan DELETE FROM accounts WHERE name IN ('T1','T2','T3');
--
--    uji 0 — TULIS NILAI SAMA ke kolom lama, JANGAN sampai melahirkan riwayat:
--      UPDATE public.accounts SET account_status = account_status WHERE id=<akun>;
--      SELECT count(*) FROM public.account_lifecycle_history;
--      -- HARAPAN: TIDAK BERTAMBAH. Menguji jaring `IS DISTINCT FROM` di STEP 2,
--      --          bukan sekadar mempercayai komentarnya.
--
--    uji 1 — tulis kolom LAMA -> kolom baru ikut:
--      UPDATE public.accounts SET account_status='mql' WHERE id=<prospect>;
--      -- HARAPAN: kedua kolom 'mql', +1 baris riwayat prospect->mql
--
--    uji 2 — tulis kolom BARU -> kolom lama ikut:
--      UPDATE public.accounts SET lifecycle_stage='sql' WHERE id=<prospect>;
--      -- HARAPAN: kedua kolom 'sql', +1 baris riwayat
--
--    uji 3 — UPDATE kolom LAIN tidak mengubah apa pun:
--      UPDATE public.accounts SET name = name WHERE id=<akun>;
--      -- HARAPAN: kedua kolom tetap, NOL baris riwayat baru
--
--    uji 4 — INSERT lewat kolom lama:
--      INSERT INTO public.accounts (name, company_id, account_status)
--      VALUES ('T1', '<company_uuid>', 'customer');
--      -- HARAPAN: lifecycle_stage='customer' DAN code ter-generate
--
--    uji 5 — INSERT lewat kolom baru:
--      INSERT INTO public.accounts (name, company_id, lifecycle_stage)
--      VALUES ('T2', '<company_uuid>', 'customer');
--      -- HARAPAN: account_status='customer' DAN code ter-generate
--
--    uji 6 — INSERT tanpa keduanya:
--      INSERT INTO public.accounts (name, company_id) VALUES ('T3', '<company_uuid>');
--      -- HARAPAN: kedua kolom 'lead' (default account_status disalin trigger)
--
--    uji 7 — set_customer_on_won menulis DUA kolom:
--      UPDATE public.accounts SET pipeline_stage='WON' WHERE id=<prospect>;
--      -- HARAPAN: kedua kolom 'customer'
--
--    uji 8 — ⭐ TERPENTING. set_prospect_on_inquiry menulis dua kolom DAN akun
--            ber-tahap 'sql' IKUT turun ke prospect (= penyempitan #36 TIDAK
--            terbawa):
--      -- set satu akun ke 'sql', lalu buat inquiry baru untuknya
--      -- HARAPAN: kedua kolom jadi 'prospect'
--      -- Kalau akun 'sql' TETAP 'sql', berarti penyempitan ikut terselundup —
--      -- BERHENTI, itu bug yang justru dicegah migrasi ini.
--
--    uji 9 — set_customer_on_inquiry_won menulis dua kolom:
--      -- set sebuah inquiry ke status WON
--      -- HARAPAN: kedua kolom akun terkait 'customer'
--
--    uji 10 — backfill riwayat: jalankan VERIFIKASI (d) di atas.
--
-- ── T3. Sesudahnya ──────────────────────────────────────────────────────────
--    TIDAK perlu dibersihkan. Staging berakhir di keadaan TRANSISI (dua kolom,
--    sinkron) — persis keadaan yang akan dialami produksi, dan yang memang
--    dibutuhkan FE branch. Kalau ingin sekalian menguji penutupnya, jalankan
--    20260907000002 di staging SESUDAH seluruh uji di atas lolos.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- PEKERJAAN FE YANG MENYERTAI (bukan SQL — jangan lupa)
-- ═════════════════════════════════════════════════════════════════════════════
--   src/hooks/useCustomFields.js:33 memuat daftar kolom sistem yang dikecualikan
--   dari custom fields. `main` mencantumkan 'account_status', branch
--   'lifecycle_stage'. SELAMA KEDUA KOLOM HIDUP daftar itu HARUS memuat
--   KEDUANYA — kalau tidak, kolom seberang bisa muncul sebagai custom field di
--   UI. Satu baris, satu file. Salah satunya dicabut lagi di 20260907000002.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═════════════════════════════════════════════════════════════════════════════
--   ⚠️ Kembalikan KEEMPAT fungsi ke badan produksi (yang menulis account_status
--      saja) SEBELUM men-drop kolomnya — kalau tidak, fungsi merujuk kolom yang
--      sudah hilang.
--   1. CREATE OR REPLACE keempat fungsi dari
--      `git show main:supabase/schema_snapshot.sql`.
--   2. DROP TRIGGER IF EXISTS trg_z_log_lifecycle_change ON public.accounts;
--      DROP FUNCTION IF EXISTS public.log_lifecycle_change();
--      DROP TABLE IF EXISTS public.account_lifecycle_history;
--   3. DROP TRIGGER IF EXISTS trg_a_sync_lifecycle_columns ON public.accounts;
--      DROP FUNCTION IF EXISTS public.sync_lifecycle_columns();
--   4. ALTER TABLE public.accounts DROP CONSTRAINT IF EXISTS accounts_lifecycle_stage_check;
--      ALTER TABLE public.accounts DROP COLUMN IF EXISTS lifecycle_stage;
--      COMMENT ON COLUMN public.accounts.account_status IS NULL;

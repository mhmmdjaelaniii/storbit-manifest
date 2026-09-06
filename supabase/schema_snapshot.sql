--
-- PostgreSQL database dump
--

\restrict 3woiD72JOIOrITSz9owCfJJydeaRgnZE5b41SgztrxyVBLLq74hJESHzWPsasNu

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: add_picking_material(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_picking_material(p_picking_list_id uuid, p_product_id uuid, p_qty integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_company uuid := 'd2e5e565-5f67-4954-b8d9-5979a2a0c697';
        v_wh uuid; v_status text; v_no text; v_uid uuid := auth.uid();
        v_pname text; v_sku text; v_mid uuid;
BEGIN
  IF p_product_id IS NULL THEN RAISE EXCEPTION 'product_id wajib'; END IF;
  IF COALESCE(p_qty,0) <= 0 THEN RAISE EXCEPTION 'qty harus > 0'; END IF;
  SELECT status, warehouse_id, picking_no INTO v_status, v_wh, v_no FROM picking_lists WHERE id=p_picking_list_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Picking tidak ditemukan'; END IF;
  IF v_status <> 'done' THEN RAISE EXCEPTION 'Material hanya bisa dicatat saat picking selesai (status=%)', v_status; END IF;
  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak mencatat material packing';
  END IF;
  IF EXISTS (SELECT 1 FROM delivery_notes WHERE picking_list_id=p_picking_list_id AND status <> 'cancelled') THEN
    RAISE EXCEPTION 'Surat jalan sudah dibuat — material tak bisa ditambah lagi'; END IF;
  v_wh := COALESCE(v_wh, '303c3d4c-570e-40a1-b738-6b0ed1cb5078');
  SELECT name, code INTO v_pname, v_sku FROM products WHERE id=p_product_id;
  IF v_pname IS NULL THEN RAISE EXCEPTION 'Produk tidak ditemukan'; END IF;

  INSERT INTO picking_list_materials (picking_list_id, product_id, product_name, sku, qty, created_by)
  VALUES (p_picking_list_id, p_product_id, v_pname, COALESCE(v_sku,''), p_qty, v_uid)
  RETURNING id INTO v_mid;

  INSERT INTO stock_ledger
    (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
  VALUES (v_company, v_wh, p_product_id, 'outbound', -abs(p_qty), 'picking_material', v_mid, v_no, v_uid);

  RETURN v_mid;
END; $$;


ALTER FUNCTION public.add_picking_material(p_picking_list_id uuid, p_product_id uuid, p_qty integer) OWNER TO postgres;

--
-- Name: ar_ttfs_set_company(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.ar_ttfs_set_company() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.company_id IS NULL THEN
    NEW.company_id := COALESCE(
      (SELECT i.company_id FROM sp_invoices i WHERE i.id = NEW.invoice_id),
      (SELECT o.company_id FROM sp_orders   o WHERE o.id = NEW.sp_order_id),
      (SELECT a.company_id FROM accounts    a WHERE a.id = NEW.customer_id)
    );
  END IF;
  RETURN NEW;
END; $$;


ALTER FUNCTION public.ar_ttfs_set_company() OWNER TO postgres;

--
-- Name: attach_price_contract_info(uuid, text, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.attach_price_contract_info(p_history_id uuid, p_contract_no text, p_valid_from date, p_valid_until date) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.product_price_history
     SET contract_no = p_contract_no,
         valid_from  = p_valid_from,
         valid_until = p_valid_until
   WHERE id = p_history_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Baris riwayat harga % tidak ditemukan', p_history_id;
  END IF;
END;
$$;


ALTER FUNCTION public.attach_price_contract_info(p_history_id uuid, p_contract_no text, p_valid_from date, p_valid_until date) OWNER TO postgres;

--
-- Name: bulk_update_product_prices(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.bulk_update_product_prices(p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_row jsonb; v_product_id uuid; v_new_price numeric; v_category text;
  v_contract text; v_valid_until date; v_current numeric; v_company uuid; v_history_id uuid;
  v_updated int := 0; v_skipped int := 0; v_results jsonb := '[]'::jsonb;
begin
  if not is_super_admin() then
    raise exception 'Tidak diizinkan: hanya super_admin yang boleh bulk update harga';
  end if;
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_product_id  := (v_row->>'product_id')::uuid;
    v_new_price   := (v_row->>'new_price')::numeric;
    v_category    := coalesce(nullif(v_row->>'category',''), 'default');
    v_contract    := nullif(v_row->>'contract_no', '');
    v_valid_until := nullif(v_row->>'valid_until', '')::date;
    if v_product_id is null or v_new_price is null or v_new_price < 0 then
      raise exception 'Baris tidak valid (product_id/new_price kosong atau negatif): %', v_row;
    end if;
    if v_category not in ('default','semester','tahunan','project') then
      raise exception 'Kategori harga tidak valid: %', v_category;
    end if;
    select company_id,
           case v_category
             when 'semester' then price_semester
             when 'tahunan'  then price_tahunan
             when 'project'  then price_project
             else default_price
           end
      into v_company, v_current
      from products where id = v_product_id;
    if not found then
      raise exception 'Produk tidak ditemukan: %', v_product_id;
    end if;
    if v_current is distinct from v_new_price then
      if v_category = 'default' then
        update products set default_price = v_new_price where id = v_product_id;
        if v_contract is not null then
          select id into v_history_id from product_price_history
            where product_id = v_product_id order by changed_at desc limit 1;
          perform attach_price_contract_info(v_history_id, v_contract, current_date, v_valid_until);
        end if;
      else
        if v_category = 'semester' then
          update products set price_semester = v_new_price where id = v_product_id;
        elsif v_category = 'tahunan' then
          update products set price_tahunan = v_new_price where id = v_product_id;
        else
          update products set price_project = v_new_price where id = v_product_id;
        end if;
        insert into product_price_history
          (product_id, company_id, old_price, new_price, changed_by, source, price_category, contract_no, valid_from, valid_until)
        values
          (v_product_id, v_company, v_current, v_new_price, auth.uid(), 'bulk_category', v_category, v_contract, current_date, v_valid_until);
      end if;
      v_updated := v_updated + 1;
      v_results := v_results || jsonb_build_object(
        'product_id', v_product_id, 'category', v_category, 'status', 'updated',
        'old_price', v_current, 'new_price', v_new_price);
    else
      v_skipped := v_skipped + 1;
      v_results := v_results || jsonb_build_object(
        'product_id', v_product_id, 'category', v_category, 'status', 'skipped_same_price');
    end if;
  end loop;
  return jsonb_build_object('updated', v_updated, 'skipped', v_skipped, 'rows', v_results);
end;
$$;


ALTER FUNCTION public.bulk_update_product_prices(p_rows jsonb) OWNER TO postgres;

--
-- Name: cancel_delivery(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cancel_delivery(p_delivery_note_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_status text; v_uid uuid := auth.uid(); v_cust uuid; v_sp text;
BEGIN
  SELECT status, customer_id, sp_no INTO v_status, v_cust, v_sp FROM delivery_notes WHERE id=p_delivery_note_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Surat jalan tidak ditemukan'; END IF;
  IF v_status='cancelled' THEN RAISE EXCEPTION 'Surat jalan sudah dibatalkan'; END IF;
  IF v_status IN ('in_transit','delivered') THEN
    INSERT INTO stock_ledger
      (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
    SELECT company_id, warehouse_id, product_id, 'inbound', abs(qty), 'delivery_cancel', reference_id, reference_no, v_uid
    FROM stock_ledger
    WHERE reference_type='delivery' AND reference_id=p_delivery_note_id AND movement_type='outbound';

    WITH agg AS (
      SELECT pli.sp_item_id AS sp_item_id, SUM(dni.qty) AS qty
      FROM delivery_note_items dni
      JOIN picking_list_items pli ON pli.id = dni.picking_list_item_id
      WHERE dni.delivery_note_id = p_delivery_note_id AND COALESCE(dni.qty,0) > 0 AND pli.sp_item_id IS NOT NULL
      GROUP BY pli.sp_item_id
    )
    UPDATE sp_items si SET shipped_qty = GREATEST(si.shipped_qty - agg.qty, 0), updated_at = now()
    FROM agg WHERE si.id = agg.sp_item_id;

    -- ===== BARU: reversal shipped_qty ke sp_order_items (simetris) =====
    WITH agg AS (
      SELECT pli.sp_item_id AS sp_item_id, SUM(dni.qty) AS qty
      FROM delivery_note_items dni
      JOIN picking_list_items pli ON pli.id = dni.picking_list_item_id
      WHERE dni.delivery_note_id = p_delivery_note_id AND COALESCE(dni.qty,0) > 0 AND pli.sp_item_id IS NOT NULL
      GROUP BY pli.sp_item_id
    )
    UPDATE sp_order_items soi SET shipped_qty = GREATEST(soi.shipped_qty - agg.qty, 0), updated_at = now()
    FROM agg WHERE soi.legacy_sp_item_id = agg.sp_item_id;
  END IF;

  UPDATE delivery_notes SET status='cancelled', cancelled_at=now() WHERE id=p_delivery_note_id;

  IF v_cust IS NOT NULL AND v_sp IS NOT NULL THEN
    PERFORM sp_recompute_status(v_cust, v_sp);
  END IF;
END; $$;


ALTER FUNCTION public.cancel_delivery(p_delivery_note_id uuid) OWNER TO postgres;

--
-- Name: cancel_picking(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cancel_picking(p_picking_list_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_status text; v_uid uuid := auth.uid(); v_cust uuid; v_sp text;
BEGIN
  SELECT status, customer_id, sp_no INTO v_status, v_cust, v_sp FROM picking_lists WHERE id=p_picking_list_id;
  IF v_sp IS NULL THEN RAISE EXCEPTION 'Picking tidak ditemukan'; END IF;
  IF v_status NOT IN ('pending','in_progress') THEN
    RAISE EXCEPTION 'Hanya picking pending/in_progress yang bisa dibatalkan (status=%)', v_status; END IF;
  INSERT INTO stock_ledger
    (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
  SELECT company_id, warehouse_id, product_id, 'unreserved', qty, 'picking', reference_id, reference_no, v_uid
  FROM stock_ledger
  WHERE reference_type='picking' AND reference_id=p_picking_list_id AND movement_type='reserved';
  UPDATE picking_lists SET status='cancelled', cancelled_at=now() WHERE id=p_picking_list_id;
  UPDATE public.sp_orders SET had_cancelled_picking=true, updated_at=now()
    WHERE customer_id=v_cust AND sp_no=v_sp;
  PERFORM sp_recompute_status(v_cust, v_sp);
END; $$;


ALTER FUNCTION public.cancel_picking(p_picking_list_id uuid) OWNER TO postgres;

--
-- Name: capture_login_session(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.capture_login_session() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  BEGIN
    INSERT INTO public.user_login_logs (user_id, session_id, logged_in_at, ip, user_agent)
    VALUES (NEW.user_id, NEW.id, COALESCE(NEW.created_at, now()), host(NEW.ip), NEW.user_agent);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- kalau logging gagal, login TETEP jalan
  END;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.capture_login_session() OWNER TO postgres;

--
-- Name: check_similar_accounts(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_similar_accounts(p_name text, p_company_id uuid) RETURNS TABLE(id uuid, name text, similarity real)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH param AS (
    SELECT public.normalize_account_name(p_name) AS norm,
           0.6::real                             AS ambang
  )
  SELECT a.id,
         a.name,
         public.similarity(public.normalize_account_name(a.name), p.norm) AS similarity
  FROM public.accounts a
  CROSS JOIN param p
  WHERE a.company_id = p_company_id
    AND a.deleted_at IS NULL
    AND p.norm <> ''
    AND public.similarity(public.normalize_account_name(a.name), p.norm) >= p.ambang
  ORDER BY 3 DESC, a.name
  LIMIT 5;
$$;


ALTER FUNCTION public.check_similar_accounts(p_name text, p_company_id uuid) OWNER TO postgres;

--
-- Name: complete_picking(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.complete_picking(p_picking_list_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_status text; v_cust uuid; v_sp text;
BEGIN
  SELECT status, customer_id, sp_no INTO v_status, v_cust, v_sp FROM picking_lists WHERE id=p_picking_list_id;
  IF v_sp IS NULL THEN RAISE EXCEPTION 'Picking tidak ditemukan'; END IF;
  IF v_status NOT IN ('pending','in_progress') THEN
    RAISE EXCEPTION 'Hanya picking pending/in_progress yang bisa diselesaikan (status=%)', v_status; END IF;
  UPDATE picking_lists SET status='done', completed_at=now(), updated_at=now() WHERE id=p_picking_list_id;
  PERFORM sp_recompute_status(v_cust, v_sp);
END; $$;


ALTER FUNCTION public.complete_picking(p_picking_list_id uuid) OWNER TO postgres;

--
-- Name: create_invoice(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_invoice(p_sp_order_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_company_id   uuid; v_customer_id uuid; v_sp_no text; v_entity_code text;
  v_year         int := extract(year from now())::int;
  v_month_roman  text;
  v_seq          int; v_invoice_no text; v_invoice_id uuid;
  v_ordered      int; v_shipped int;
  v_total_dpp    numeric(18,2); v_total_ppn numeric(18,2); v_total_amount numeric(18,2);
  v_uid          uuid := auth.uid();
  v_total_ship   numeric(18,2);
  v_je_id        uuid;
  v_acc_ar       uuid;
  v_acc_rev      uuid;
  v_acc_ship     uuid;
  v_acc_ppn_out  uuid;
  c_code_ar      CONSTANT text := '1-1200';
  c_code_rev     CONSTANT text := '4-1000';
  c_code_ship    CONSTANT text := '4-1100';
  c_code_ppn_out CONSTANT text := '2-1200';
BEGIN
  IF NOT (is_super_admin() OR is_manager_or_above() OR has_role('finance_controller')) THEN
    RAISE EXCEPTION 'Tidak punya izin menerbitkan invoice.';
  END IF;

  SELECT company_id, customer_id, sp_no INTO v_company_id, v_customer_id, v_sp_no
    FROM sp_orders WHERE id = p_sp_order_id AND deleted_at IS NULL;
  IF v_company_id IS NULL THEN RAISE EXCEPTION 'SP tidak ditemukan.'; END IF;

  IF EXISTS (SELECT 1 FROM sp_invoices WHERE sp_order_id = p_sp_order_id AND status <> 'void') THEN
    RAISE EXCEPTION 'SP ini sudah punya invoice aktif.';
  END IF;

  SELECT COALESCE(SUM(qty),0), COALESCE(SUM(shipped_qty),0) INTO v_ordered, v_shipped
    FROM sp_order_items WHERE sp_order_id = p_sp_order_id;
  IF v_ordered = 0 OR v_shipped <> v_ordered THEN
    RAISE EXCEPTION 'SP belum terkirim penuh (Σshipped=%, Σqty=%) — invoice tidak bisa diterbitkan.', v_shipped, v_ordered;
  END IF;

  SELECT code INTO v_entity_code FROM companies WHERE id = v_company_id;
  v_seq := increment_document_sequence(v_company_id, 'INV', 'FIN', v_year, 0, 0);
  v_month_roman := CASE extract(month from now())::int
    WHEN 1 THEN 'I' WHEN 2 THEN 'II' WHEN 3 THEN 'III' WHEN 4 THEN 'IV'
    WHEN 5 THEN 'V' WHEN 6 THEN 'VI' WHEN 7 THEN 'VII' WHEN 8 THEN 'VIII'
    WHEN 9 THEN 'IX' WHEN 10 THEN 'X' WHEN 11 THEN 'XI' WHEN 12 THEN 'XII'
  END;
  v_invoice_no := v_entity_code || '-INV-' || v_month_roman || '-' || v_year || '-' || lpad(v_seq::text, 4, '0');

  INSERT INTO sp_invoices (company_id, sp_order_id, invoice_no, invoice_date, status, created_by)
  VALUES (v_company_id, p_sp_order_id, v_invoice_no, current_date, 'issued', v_uid)
  RETURNING id INTO v_invoice_id;

  INSERT INTO sp_invoice_lines (invoice_id, sp_order_item_id, dpp, ppn, qty, position)
  SELECT v_invoice_id, i.id,
         (i.unit_price * i.shipped_qty),
         ROUND((i.unit_price * i.shipped_qty + i.shipping_price) * 0.11),
         i.shipped_qty,
         row_number() OVER (ORDER BY i.created_at)
    FROM sp_order_items i WHERE i.sp_order_id = p_sp_order_id;

  SELECT COALESCE(SUM(dpp),0), COALESCE(SUM(ppn),0) INTO v_total_dpp, v_total_ppn
    FROM sp_invoice_lines WHERE invoice_id = v_invoice_id;
  SELECT v_total_dpp + v_total_ppn + COALESCE(SUM(shipping_price),0) INTO v_total_amount
    FROM sp_order_items WHERE sp_order_id = p_sp_order_id;

  UPDATE sp_invoices SET total_dpp = v_total_dpp, total_ppn = v_total_ppn, total_amount = v_total_amount
   WHERE id = v_invoice_id;

  SELECT COALESCE(SUM(shipping_price),0) INTO v_total_ship
    FROM sp_order_items WHERE sp_order_id = p_sp_order_id;

  SELECT id INTO v_acc_ar FROM chart_of_accounts
   WHERE company_id = v_company_id AND code = c_code_ar AND deleted_at IS NULL;
  IF v_acc_ar IS NULL THEN
    RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_ar;
  END IF;

  SELECT id INTO v_acc_rev FROM chart_of_accounts
   WHERE company_id = v_company_id AND code = c_code_rev AND deleted_at IS NULL;
  IF v_acc_rev IS NULL THEN
    RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_rev;
  END IF;

  SELECT id INTO v_acc_ppn_out FROM chart_of_accounts
   WHERE company_id = v_company_id AND code = c_code_ppn_out AND deleted_at IS NULL;
  IF v_acc_ppn_out IS NULL THEN
    RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_ppn_out;
  END IF;

  IF v_total_ship > 0 THEN
    SELECT id INTO v_acc_ship FROM chart_of_accounts
     WHERE company_id = v_company_id AND code = c_code_ship AND deleted_at IS NULL;
    IF v_acc_ship IS NULL THEN
      RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_ship;
    END IF;
  END IF;

  INSERT INTO journal_entries
    (company_id, entry_date, reference_type, reference_id, description, created_by)
  VALUES
    (v_company_id, current_date, 'invoice_issued', v_invoice_id,
     'Penerbitan invoice ' || v_invoice_no || ' (SP ' || v_sp_no || ')', v_uid)
  RETURNING id INTO v_je_id;

  INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
  VALUES (v_je_id, v_acc_ar, v_total_amount, 0);

  IF v_total_dpp > 0 THEN
    INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
    VALUES (v_je_id, v_acc_rev, 0, v_total_dpp);
  END IF;

  IF v_total_ship > 0 THEN
    INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
    VALUES (v_je_id, v_acc_ship, 0, v_total_ship);
  END IF;

  IF v_total_ppn > 0 THEN
    INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
    VALUES (v_je_id, v_acc_ppn_out, 0, v_total_ppn);
  END IF;

  PERFORM sp_recompute_status(v_customer_id, v_sp_no);
  RETURN v_invoice_id;
END; $$;


ALTER FUNCTION public.create_invoice(p_sp_order_id uuid) OWNER TO postgres;

--
-- Name: create_sp_order_dual(uuid, uuid, text, date, uuid, text, date, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_sp_order_dual(p_company_id uuid, p_customer_id uuid, p_sp_no text, p_sp_date date, p_dc_id uuid, p_status text, p_expired_date date, p_notes text, p_items jsonb) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  v_order_id uuid;
BEGIN
  INSERT INTO public.sp_orders
    (company_id, customer_id, sp_no, sp_date, dc_id, status, expired_date, notes, created_by)
  VALUES
    (p_company_id, p_customer_id, p_sp_no, p_sp_date, p_dc_id,
     COALESCE(NULLIF(p_status,''),'DRAFT'), p_expired_date, p_notes, auth.uid())
  RETURNING id INTO v_order_id;

  INSERT INTO public.sp_order_items
    (sp_order_id, company_id, product_id, product_name, sku, qty, shipped_qty,
     unit_price, price_category, shipping_price, legacy_sp_item_id)
  SELECT
    v_order_id, p_company_id,
    (e->>'product_id')::uuid,
    COALESCE(e->>'product_name',''),
    COALESCE(e->>'sku',''),
    (e->>'qty')::int,
    0,
    COALESCE((e->>'unit_price')::numeric, 0),
    NULLIF(e->>'price_category',''),
    COALESCE((e->>'shipping_price')::numeric, 0),
    NULLIF(e->>'legacy_sp_item_id','')::uuid
  FROM jsonb_array_elements(p_items) AS e;

  RETURN v_order_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'SP % sudah ada untuk customer ini (duplikat)', p_sp_no
      USING ERRCODE = 'unique_violation';
END;
$$;


ALTER FUNCTION public.create_sp_order_dual(p_company_id uuid, p_customer_id uuid, p_sp_no text, p_sp_date date, p_dc_id uuid, p_status text, p_expired_date date, p_notes text, p_items jsonb) OWNER TO postgres;

--
-- Name: delete_picking_material(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_picking_material(p_material_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_pick uuid; v_uid uuid := auth.uid(); v_company uuid;
BEGIN
  SELECT picking_list_id INTO v_pick FROM picking_list_materials WHERE id=p_material_id;
  IF v_pick IS NULL THEN RAISE EXCEPTION 'Material tidak ditemukan'; END IF;
  SELECT company_id INTO v_company FROM picking_lists WHERE id = v_pick;
  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak menghapus material packing';
  END IF;
  IF EXISTS (SELECT 1 FROM delivery_notes WHERE picking_list_id=v_pick AND status <> 'cancelled') THEN
    RAISE EXCEPTION 'Tak bisa hapus material: surat jalan sudah dibuat'; END IF;
  INSERT INTO stock_ledger
    (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
  SELECT company_id, warehouse_id, product_id, 'inbound', abs(qty), 'material_reverse', p_material_id, reference_no, v_uid
  FROM stock_ledger
  WHERE reference_type='picking_material' AND reference_id=p_material_id AND movement_type='outbound';
  DELETE FROM public.picking_list_materials WHERE id=p_material_id;
END; $$;


ALTER FUNCTION public.delete_picking_material(p_material_id uuid) OWNER TO postgres;

--
-- Name: delete_sp_dual(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_sp_dual(p_customer_id uuid, p_sp_no text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_status text;
BEGIN
  -- Guard 1: hanya super_admin
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Hanya super_admin yang boleh menghapus SP';
  END IF;

  -- Guard 2 (STRICT): hanya DRAFT
  SELECT status INTO v_status
  FROM sp_orders
  WHERE customer_id = p_customer_id AND sp_no = p_sp_no AND deleted_at IS NULL;

  IF v_status IS DISTINCT FROM 'DRAFT' THEN
    RAISE EXCEPTION 'SP % hanya bisa dihapus saat DRAFT (status: %)',
      p_sp_no, COALESCE(v_status, 'TIDAK ADA');
  END IF;

  DELETE FROM sp_orders WHERE customer_id = p_customer_id AND sp_no = p_sp_no;
  DELETE FROM sp_items  WHERE customer_id = p_customer_id AND sp_no = p_sp_no;
END;
$$;


ALTER FUNCTION public.delete_sp_dual(p_customer_id uuid, p_sp_no text) OWNER TO postgres;

--
-- Name: delete_sp_item_dual(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_sp_item_dual(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_company uuid; v_status text; v_cust uuid; v_sp text;
BEGIN
  SELECT o.company_id, o.status, si.customer_id, si.sp_no
    INTO v_company, v_status, v_cust, v_sp
    FROM sp_items si
    JOIN sp_orders o
      ON o.customer_id = si.customer_id
     AND o.sp_no       = si.sp_no
     AND o.deleted_at IS NULL
   WHERE si.id = p_id;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Item SP tidak ditemukan, atau SP induknya belum ada di sp_orders.';
  END IF;

  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND is_sp_item_writer())) THEN
    RAISE EXCEPTION 'Tidak berhak menghapus item SP ini';
  END IF;

  IF v_status NOT IN ('DRAFT','CONFIRMED','MENUNGGU_STOK') THEN
    RAISE EXCEPTION 'SP sudah berjalan (status %) — baris item tidak bisa dihapus.', v_status;
  END IF;

  IF (SELECT count(*) FROM sp_items
       WHERE customer_id = v_cust AND sp_no = v_sp) <= 1 THEN
    RAISE EXCEPTION 'Ini baris terakhir SP — hapus SP-nya lewat Danger Zone, bukan per item.';
  END IF;

  DELETE FROM sp_order_items WHERE legacy_sp_item_id = p_id;
  DELETE FROM sp_items       WHERE id = p_id;

  PERFORM sp_recompute_status(v_cust, v_sp);
END; $$;


ALTER FUNCTION public.delete_sp_item_dual(p_id uuid) OWNER TO postgres;

--
-- Name: FUNCTION delete_sp_item_dual(p_id uuid); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.delete_sp_item_dual(p_id uuid) IS 'Satu-satunya jalur sah menghapus SATU baris item SP. Menghapus sp_items DAN kembarannya di sp_order_items (legacy_sp_item_id TANPA FK) dalam satu transaksi — mencegah baris hantu yang membuat guard Sigma-shipped=Sigma-qty create_invoice mustahil terpenuhi. Hapus SP UTUH pakai delete_sp_dual().';


--
-- Name: dispatch_delivery(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.dispatch_delivery(p_delivery_note_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_company uuid := 'd2e5e565-5f67-4954-b8d9-5979a2a0c697';
        v_status text; v_pick uuid; v_wh uuid; v_no text; v_uid uuid := auth.uid();
        v_cust uuid; v_sp text;
BEGIN
  SELECT status, picking_list_id, do_no, customer_id, sp_no
    INTO v_status, v_pick, v_no, v_cust, v_sp
    FROM delivery_notes WHERE id=p_delivery_note_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Surat jalan tidak ditemukan'; END IF;
  IF v_status <> 'draft' THEN RAISE EXCEPTION 'Hanya surat jalan draft yang bisa diberangkatkan (status=%)', v_status; END IF;
  SELECT warehouse_id INTO v_wh FROM picking_lists WHERE id=v_pick;
  v_wh := COALESCE(v_wh, '303c3d4c-570e-40a1-b738-6b0ed1cb5078');

  INSERT INTO stock_ledger
    (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
  SELECT company_id, warehouse_id, product_id, 'unreserved', qty, 'picking', reference_id, reference_no, v_uid
  FROM stock_ledger
  WHERE reference_type='picking' AND reference_id=v_pick AND movement_type='reserved';

  INSERT INTO stock_ledger
    (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
  SELECT v_company, v_wh, dni.product_id, 'outbound', -abs(dni.qty), 'delivery', p_delivery_note_id, v_no, v_uid
  FROM delivery_note_items dni
  WHERE dni.delivery_note_id=p_delivery_note_id AND dni.product_id IS NOT NULL AND COALESCE(dni.qty,0) > 0;

  UPDATE delivery_notes SET status='in_transit', dispatched_at=now() WHERE id=p_delivery_note_id;

  WITH agg AS (
    SELECT pli.sp_item_id AS sp_item_id, SUM(dni.qty) AS qty
    FROM delivery_note_items dni
    JOIN picking_list_items pli ON pli.id = dni.picking_list_item_id
    WHERE dni.delivery_note_id = p_delivery_note_id AND COALESCE(dni.qty,0) > 0 AND pli.sp_item_id IS NOT NULL
    GROUP BY pli.sp_item_id
  )
  UPDATE sp_items si SET shipped_qty = si.shipped_qty + agg.qty, updated_at = now()
  FROM agg WHERE si.id = agg.sp_item_id;

  -- ===== BARU: jembatan shipped_qty ke sp_order_items (kanonik skema baru) =====
  WITH agg AS (
    SELECT pli.sp_item_id AS sp_item_id, SUM(dni.qty) AS qty
    FROM delivery_note_items dni
    JOIN picking_list_items pli ON pli.id = dni.picking_list_item_id
    WHERE dni.delivery_note_id = p_delivery_note_id AND COALESCE(dni.qty,0) > 0 AND pli.sp_item_id IS NOT NULL
    GROUP BY pli.sp_item_id
  )
  UPDATE sp_order_items soi SET shipped_qty = LEAST(soi.shipped_qty + agg.qty, soi.qty), updated_at = now()
  FROM agg WHERE soi.legacy_sp_item_id = agg.sp_item_id;

  PERFORM sp_recompute_status(v_cust, v_sp);
END; $$;


ALTER FUNCTION public.dispatch_delivery(p_delivery_note_id uuid) OWNER TO postgres;

--
-- Name: exec_sql(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.exec_sql(sql text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  EXECUTE sql;
END;
$$;


ALTER FUNCTION public.exec_sql(sql text) OWNER TO postgres;

--
-- Name: generate_customer_code(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_customer_code() RETURNS trigger
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


ALTER FUNCTION public.generate_customer_code() OWNER TO postgres;

--
-- Name: generate_delivery_from_picking(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_delivery_from_picking(p_picking_list_id uuid) RETURNS TABLE(delivery_note_id uuid, do_no text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_company_id uuid := 'd2e5e565-5f67-4954-b8d9-5979a2a0c697';
  v_entity text;
  v_year int := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Jakarta'))::int;
  v_seq int; v_no text; v_dn_id uuid; v_uid uuid := auth.uid();
  v_sp_no text; v_pick_status text;
  v_customer uuid; v_cust_name text; v_addr text;
  v_item_count int;
  v_sp_order_id uuid;
BEGIN
  SELECT sp_no, status, customer_id, sp_order_id
    INTO v_sp_no, v_pick_status, v_customer, v_sp_order_id
    FROM picking_lists WHERE id = p_picking_list_id;
  IF v_sp_no IS NULL THEN RAISE EXCEPTION 'Picking list tidak ditemukan'; END IF;
  IF v_pick_status <> 'done' THEN RAISE EXCEPTION 'Picking list belum selesai (status=%)', v_pick_status; END IF;
  IF NOT (is_super_admin() OR (v_company_id IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak membuat surat jalan untuk picking ini';
  END IF;
  IF EXISTS (SELECT 1 FROM delivery_notes WHERE picking_list_id = p_picking_list_id AND status <> 'cancelled') THEN
    RAISE EXCEPTION 'Surat jalan untuk picking ini sudah ada'; END IF;
  SELECT count(*) INTO v_item_count FROM picking_list_items
    WHERE picking_list_id = p_picking_list_id AND COALESCE(qty_picked,0) > 0;
  IF v_item_count = 0 THEN RAISE EXCEPTION 'Tak ada item ter-pick untuk dikirim'; END IF;
  IF v_customer IS NULL THEN
    SELECT si.customer_id INTO v_customer FROM sp_items si WHERE si.sp_no = v_sp_no LIMIT 1;
  END IF;
  SELECT a.name INTO v_cust_name FROM accounts a WHERE a.id = v_customer;
  IF v_sp_order_id IS NULL AND v_customer IS NOT NULL THEN
    SELECT id INTO v_sp_order_id FROM sp_orders
     WHERE customer_id = v_customer AND sp_no = v_sp_no AND deleted_at IS NULL;
  END IF;
  IF v_sp_order_id IS NOT NULL THEN
    SELECT NULLIF(btrim(dc.alamat), '')
      INTO v_addr
      FROM sp_orders so
      JOIN dc_master dc ON dc.id = so.dc_id
     WHERE so.id = v_sp_order_id;
  END IF;
  SELECT code INTO v_entity FROM companies WHERE id = v_company_id;
  v_seq := increment_document_sequence(v_company_id, 'SJ', 'WH', v_year, 0);
  v_no  := 'SJ/' || COALESCE(v_entity,'SOA') || '/WH/' || v_year || '/' || lpad(v_seq::text, 4, '0');
  INSERT INTO delivery_notes
    (company_id, do_no, sp_no, picking_list_id, customer_id, customer_name, destination_address, status, created_by, sp_order_id)
  VALUES (v_company_id, v_no, v_sp_no, p_picking_list_id, v_customer, v_cust_name, v_addr, 'draft', v_uid, v_sp_order_id)
  RETURNING id INTO v_dn_id;
  INSERT INTO delivery_note_items (delivery_note_id, picking_list_item_id, product_id, product_name, sku, qty)
  SELECT v_dn_id, pli.id, pli.product_id, pli.product_name, pli.sku, pli.qty_picked
  FROM picking_list_items pli
  WHERE pli.picking_list_id = p_picking_list_id AND COALESCE(pli.qty_picked,0) > 0;
  RETURN QUERY SELECT v_dn_id, v_no;
END;
$$;


ALTER FUNCTION public.generate_delivery_from_picking(p_picking_list_id uuid) OWNER TO postgres;

--
-- Name: generate_picking_from_sp(text, uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_picking_from_sp(p_sp_no text, p_customer_id uuid, p_warehouse_id uuid DEFAULT NULL::uuid) RETURNS TABLE(picking_list_id uuid, picking_no text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_company_id uuid := 'd2e5e565-5f67-4954-b8d9-5979a2a0c697';
  v_wh uuid := COALESCE(p_warehouse_id, '303c3d4c-570e-40a1-b738-6b0ed1cb5078');
  v_entity text; v_year int := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Jakarta'))::int;
  v_seq int; v_no text; v_pl_id uuid; v_uid uuid := auth.uid(); v_outstanding int;
  v_sp_order_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sp_items WHERE sp_no=p_sp_no AND customer_id=p_customer_id AND sp_status='confirmed') THEN
    RAISE EXCEPTION 'SP % tidak ditemukan atau belum confirmed', p_sp_no; END IF;
  IF NOT (is_super_admin() OR (v_company_id IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak membuat picking list untuk SP ini';
  END IF;
  IF EXISTS (SELECT 1 FROM picking_lists WHERE sp_no=p_sp_no AND customer_id=p_customer_id AND status IN ('pending','in_progress')) THEN
    RAISE EXCEPTION 'Picking list untuk SP % sudah ada', p_sp_no; END IF;
  IF EXISTS (
    SELECT 1 FROM picking_lists pl
    WHERE pl.sp_no = p_sp_no AND pl.customer_id = p_customer_id
      AND pl.status = 'done'
      AND NOT EXISTS (
        SELECT 1 FROM delivery_notes dn
        WHERE dn.picking_list_id = pl.id
          AND dn.dispatched_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'Picking list SP % sudah selesai tapi surat jalannya belum diberangkatkan - berangkatkan dulu sebelum membuat picking baru', p_sp_no; END IF;
  SELECT count(*) INTO v_outstanding FROM sp_items
    WHERE sp_no=p_sp_no AND customer_id=p_customer_id AND sp_status='confirmed' AND (qty - shipped_qty) > 0;
  IF v_outstanding = 0 THEN RAISE EXCEPTION 'SP % tidak punya item outstanding', p_sp_no; END IF;

  SELECT id INTO v_sp_order_id FROM sp_orders
   WHERE customer_id = p_customer_id AND sp_no = p_sp_no AND deleted_at IS NULL;

  SELECT code INTO v_entity FROM companies WHERE id = v_company_id;
  v_seq := increment_document_sequence(v_company_id,'PICK','WH',v_year,0);
  v_no  := 'PICK/'||COALESCE(v_entity,'SOA')||'/WH/'||v_year||'/'||lpad(v_seq::text,4,'0');
  INSERT INTO picking_lists (company_id, picking_no, sp_no, warehouse_id, status, created_by, customer_id, sp_order_id)
  VALUES (v_company_id, v_no, p_sp_no, v_wh, 'pending', v_uid, p_customer_id, v_sp_order_id)
  RETURNING id INTO v_pl_id;
  WITH src AS (
    SELECT si.id AS sp_item_id, si.product_id, si.product_name, si.sku,
           GREATEST(si.qty - si.shipped_qty, 0) AS req
    FROM sp_items si
    WHERE si.sp_no=p_sp_no AND si.customer_id=p_customer_id AND si.sp_status='confirmed' AND (si.qty - si.shipped_qty) > 0
  ),
  av AS (
    SELECT src.*,
           COALESCE((SELECT SUM(ss.available) FROM stock_summary ss
                     WHERE ss.company_id = v_company_id AND ss.product_id = src.product_id), 0) AS avail
    FROM src
  ),
  ins_items AS (
    INSERT INTO picking_list_items
      (picking_list_id, sp_item_id, product_id, product_name, sku, qty_requested, qty_short, location_detail)
    SELECT v_pl_id, sp_item_id, product_id, product_name, sku, req,
           CASE WHEN product_id IS NULL THEN 0 ELSE GREATEST(req - LEAST(req, avail), 0) END,
           (SELECT pwl.rack_location FROM product_warehouse_location pwl
             WHERE pwl.product_id = av.product_id AND pwl.warehouse_id = v_wh LIMIT 1)
    FROM av
    RETURNING 1
  )
  INSERT INTO stock_ledger
    (company_id, warehouse_id, product_id, movement_type, qty, reference_type, reference_id, reference_no, created_by)
  SELECT v_company_id, v_wh, product_id, 'reserved', LEAST(req, avail), 'picking', v_pl_id, v_no, v_uid
  FROM av
  WHERE product_id IS NOT NULL AND LEAST(req, avail) > 0;
  PERFORM sp_recompute_status(p_customer_id, p_sp_no);
  RETURN QUERY SELECT v_pl_id, v_no;
END; $$;


ALTER FUNCTION public.generate_picking_from_sp(p_sp_no text, p_customer_id uuid, p_warehouse_id uuid) OWNER TO postgres;

--
-- Name: get_linked_bnf_status(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_linked_bnf_status(p_daily_report_item_id uuid) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
DECLARE
  v_status text;
  v_created_by uuid;
  v_pulled_to uuid;
BEGIN
  SELECT created_by, pulled_to_bnf_report_id INTO v_created_by, v_pulled_to
  FROM daily_report_items WHERE id = p_daily_report_item_id;

  IF v_pulled_to IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_created_by != auth.uid() AND NOT is_bnf_authorized() THEN
    RETURN NULL;
  END IF;

  SELECT status INTO v_status FROM bnf_reports WHERE id = v_pulled_to;
  RETURN v_status;
END;
$$;


ALTER FUNCTION public.get_linked_bnf_status(p_daily_report_item_id uuid) OWNER TO postgres;

--
-- Name: get_storbit_dashboard_stats(uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_dashboard_stats(p_customer_id uuid DEFAULT NULL::uuid, p_price_category text DEFAULT NULL::text, p_company_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
sp AS (
  SELECT
    o.id,
    o.status,
    o.customer_id,
    o.sp_no,
    (SELECT MIN(si.expired_date)
       FROM public.sp_items si
      WHERE si.customer_id = o.customer_id
        AND si.sp_no       = o.sp_no
        AND si.expired_date IS NOT NULL) AS expired_date,
    EXISTS (SELECT 1 FROM public.sp_btb b
             WHERE b.sp_order_id = o.id AND b.deleted_at IS NULL) AS has_btb
  FROM public.sp_orders o, scope
  WHERE o.deleted_at IS NULL
    AND o.company_id = scope.cid
    AND (p_customer_id    IS NULL OR o.customer_id    = p_customer_id)
    AND (p_price_category IS NULL OR o.price_category = p_price_category)
),
sp_flag AS (
  SELECT
    s.*,
    EXISTS (
      SELECT 1 FROM public.delivery_notes dn
       WHERE dn.customer_id = s.customer_id
         AND dn.sp_no       = s.sp_no
         AND dn.status <> 'cancelled'
         AND dn.dispatched_at IS NOT NULL
         AND s.expired_date IS NOT NULL
         AND (dn.dispatched_at AT TIME ZONE 'Asia/Jakarta')::date > s.expired_date
    ) AS late_dispatch,
    EXISTS (
      SELECT 1 FROM public.delivery_notes dn
       WHERE dn.customer_id = s.customer_id
         AND dn.sp_no       = s.sp_no
         AND dn.status <> 'cancelled'
         AND dn.dispatched_at IS NOT NULL
    ) AS has_dispatch_data
  FROM sp s
),
manifest AS (
  SELECT
    COUNT(*) FILTER (WHERE status IN ('DRAFT','CONFIRMED','MENUNGGU_STOK','PICKING','PACKED')) AS pending_open,
    COUNT(*) FILTER (WHERE status IN ('DIKIRIM','SAMPAI','MENUNGGU_KONFIRMASI_DC'))            AS shipped,
    COUNT(*) FILTER (WHERE status IN ('SAMPAI','TERKIRIM_PENUH') AND NOT has_btb)               AS delivered_belum_btb,
    COUNT(*) FILTER (WHERE status = 'BTB_TERBIT')                                               AS btb_terbit,
    COUNT(*) FILTER (WHERE status = 'TERKIRIM_PENUH')                                           AS terkirim_penuh,
    COUNT(*) FILTER (WHERE status IN ('DRAFT','CONFIRMED','MENUNGGU_STOK','PICKING','PACKED')
                       AND expired_date < CURRENT_DATE)                                         AS expired,
    COUNT(*) FILTER (WHERE status IN ('DRAFT','CONFIRMED','MENUNGGU_STOK','PICKING','PACKED')
                       AND expired_date >= CURRENT_DATE
                       AND date_trunc('month', expired_date) = date_trunc('month', CURRENT_DATE))
                                                                                                AS mendekati_expired,
    COUNT(*) FILTER (WHERE late_dispatch AND status <> 'CANCELLED')                             AS pernah_risiko_pinalti,
    COUNT(*) FILTER (WHERE has_dispatch_data
                       AND status <> 'CANCELLED'
                       AND status IN ('DIKIRIM','SAMPAI','MENUNGGU_KONFIRMASI_DC',
                                      'BTB_TERBIT','TERKIRIM_PENUH',
                                      'INVOICED','SUBMITTED','LUNAS'))                          AS dispatch_data_tersedia,
    COUNT(*) FILTER (WHERE status <> 'CANCELLED'
                       AND status IN ('DIKIRIM','SAMPAI','MENUNGGU_KONFIRMASI_DC',
                                      'BTB_TERBIT','TERKIRIM_PENUH',
                                      'INVOICED','SUBMITTED','LUNAS'))                          AS dispatch_eligible,
    COUNT(*) FILTER (WHERE status IN ('INVOICED','SUBMITTED','LUNAS'))                          AS finance,
    COUNT(*) FILTER (WHERE status = 'CANCELLED')                                                AS cancelled,
    COUNT(*)                                                                                    AS total_sp
  FROM sp_flag
),
stock AS (
  SELECT
    p.reorder_point,
    COALESCE((SELECT SUM(ss.available) FROM public.stock_summary ss
               WHERE ss.product_id = p.id
                 AND ss.company_id = p.company_id), 0) AS available
  FROM public.products p, scope
  WHERE p.deleted_at IS NULL
    AND p.company_id = scope.cid
    AND p.is_service = false
    AND p.is_active  = true
),
warehouse AS (
  SELECT
    COUNT(*) FILTER (WHERE reorder_point IS NOT NULL AND available < reorder_point) AS danger_stock,
    COUNT(*) FILTER (WHERE available <= 0)                                          AS zero_stock,
    COUNT(*) FILTER (WHERE reorder_point IS NULL)                                   AS rop_belum_diisi,
    COUNT(*)                                                                        AS total_produk
  FROM stock
)
SELECT jsonb_build_object(
  'manifest', jsonb_build_object(
    'pending_open',        (SELECT pending_open        FROM manifest),
    'shipped',             (SELECT shipped             FROM manifest),
    'delivered_belum_btb', (SELECT delivered_belum_btb FROM manifest),
    'btb_terbit',          (SELECT btb_terbit          FROM manifest),
    'terkirim_penuh',      (SELECT terkirim_penuh      FROM manifest),
    'expired',             (SELECT expired             FROM manifest),
    'mendekati_expired',   (SELECT mendekati_expired   FROM manifest),
    'pernah_risiko_pinalti',  (SELECT pernah_risiko_pinalti  FROM manifest),
    'dispatch_data_tersedia', (SELECT dispatch_data_tersedia FROM manifest),
    'dispatch_eligible',      (SELECT dispatch_eligible      FROM manifest),
    'finance',             (SELECT finance             FROM manifest),
    'cancelled',           (SELECT cancelled           FROM manifest),
    'total_sp',            (SELECT total_sp            FROM manifest)
  ),
  'warehouse', jsonb_build_object(
    'danger_stock',    (SELECT danger_stock    FROM warehouse),
    'zero_stock',      (SELECT zero_stock      FROM warehouse),
    'rop_belum_diisi', (SELECT rop_belum_diisi FROM warehouse),
    'total_produk',    (SELECT total_produk    FROM warehouse)
  ),
  'generated_at', now()
);
$$;


ALTER FUNCTION public.get_storbit_dashboard_stats(p_customer_id uuid, p_price_category text, p_company_id uuid) OWNER TO postgres;

--
-- Name: get_storbit_outstanding_summary(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_outstanding_summary(p_company_id uuid DEFAULT NULL::uuid, p_customer_id uuid DEFAULT NULL::uuid, p_price_category text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
sp AS (
  SELECT o.id, o.customer_id, o.sp_no
  FROM public.sp_orders o, scope
  WHERE o.deleted_at IS NULL
    AND o.company_id = scope.cid
    AND o.status NOT IN ('CANCELLED','DRAFT')
    AND (p_customer_id    IS NULL OR o.customer_id    = p_customer_id)
    AND (p_price_category IS NULL OR o.price_category = p_price_category)
),
it AS (
  SELECT s.id AS sp_id,
         si.qty, si.shipped_qty, si.unit_price, si.shipping_price
  FROM sp s
  JOIN public.sp_items si
    ON si.customer_id = s.customer_id
   AND si.sp_no       = s.sp_no
),
-- ── TOTAL SP (baru) ─────────────────────────────────────────────────────────
-- BRUTO: x1.11 mencerminkan rate 0.11 di create_invoice. Basis `qty` (nilai
-- PESANAN), bukan shipped_qty (nilai yang layak difaktur).
sp_total AS (
  SELECT it.sp_id,
         COALESCE(SUM((it.qty * it.unit_price) + it.shipping_price), 0) * 1.11 AS nilai
  FROM it
  GROUP BY it.sp_id
),
total_sp AS (
  SELECT COUNT(*)::int                                AS jml_sp,
         COALESCE(ROUND(SUM(t.nilai), 2), 0)::numeric AS nilai
  FROM sp_total t
),
-- ── KIRIM ───────────────────────────────────────────────────────────────────
kirim AS (
  SELECT COUNT(DISTINCT it.sp_id)::int AS jml_sp,
         COALESCE(SUM(GREATEST(it.qty - it.shipped_qty, 0) * it.unit_price), 0)::numeric AS nilai
  FROM it
  WHERE it.qty > it.shipped_qty
),
-- ── TAGIH ───────────────────────────────────────────────────────────────────
-- ⚠️ Syarat invoice SENGAJA hanya `status <> 'void'`, TANPA `deleted_at IS
--    NULL` — cermin persis guard di create_invoice. Kartu tidak boleh
--    menjanjikan angka yang sistemnya sendiri akan tolak. JANGAN "diperbaiki"
--    tanpa mengubah create_invoice lebih dulu.
tagih_sp AS (
  SELECT s.id
  FROM sp s
  WHERE EXISTS (SELECT 1 FROM public.sp_btb b
                 WHERE b.sp_order_id = s.id AND b.deleted_at IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.sp_invoices inv
                     WHERE inv.sp_order_id = s.id AND inv.status <> 'void')
),
tagih AS (
  SELECT COUNT(DISTINCT t.id)::int AS jml_sp,
         (COALESCE(SUM(it.shipped_qty * it.unit_price), 0)
        + COALESCE(SUM(it.shipping_price), 0))::numeric AS nilai
  FROM tagih_sp t
  JOIN it ON it.sp_id = t.id
),
-- ── PIUTANG ─────────────────────────────────────────────────────────────────
piutang AS (
  SELECT COUNT(*)::int AS jml_invoice,
         COALESCE(SUM(inv.total_amount - COALESCE(pay.dibayar, 0)), 0)::numeric AS nilai
  FROM public.sp_invoices inv
  JOIN sp s ON s.id = inv.sp_order_id
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(p.amount + p.pph), 0) AS dibayar
    FROM public.sp_payments p
    WHERE p.invoice_id = inv.id
  ) pay ON true
  WHERE inv.deleted_at IS NULL
    AND inv.status <> 'void'
)
SELECT jsonb_build_object(
  'total_sp', jsonb_build_object('jml_sp',      (SELECT jml_sp      FROM total_sp),
                                 'nilai',       (SELECT nilai       FROM total_sp)),
  'kirim',    jsonb_build_object('jml_sp',      (SELECT jml_sp      FROM kirim),
                                 'nilai',       (SELECT nilai       FROM kirim)),
  'tagih',    jsonb_build_object('jml_sp',      (SELECT jml_sp      FROM tagih),
                                 'nilai',       (SELECT nilai       FROM tagih)),
  'piutang',  jsonb_build_object('jml_invoice', (SELECT jml_invoice FROM piutang),
                                 'nilai',       (SELECT nilai       FROM piutang)),
  'generated_at', now()
);
$$;


ALTER FUNCTION public.get_storbit_outstanding_summary(p_company_id uuid, p_customer_id uuid, p_price_category text) OWNER TO postgres;

--
-- Name: FUNCTION get_storbit_outstanding_summary(p_company_id uuid, p_customer_id uuid, p_price_category text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.get_storbit_outstanding_summary(p_company_id uuid, p_customer_id uuid, p_price_category text) IS 'Empat angka Storbit. DUA BRUTO, DUA DPP — jangan dijumlahkan lintas basis.

  BRUTO (sudah termasuk PPN):
    total_sp = nilai kontrak SELURUH SP dalam lingkup,
               Sigma per SP dari ((qty x unit_price) + shipping_price) x 1.11.
               Basis qty (pesanan), BUKAN shipped_qty.
    piutang  = sisa tagihan invoice hidup,
               Sigma (total_amount - Sigma(amount + pph)).

  DPP (BELUM termasuk PPN):
    kirim = nilai barang belum dikirim,
            Sigma GREATEST(qty - shipped_qty,0) x unit_price.
    tagih = nilai SP ber-BTB aktif yang belum punya invoice hidup,
            Sigma (shipped_qty x unit_price) + Sigma shipping_price.

Sumber angka sp_items (bukan sp_order_items).';


--
-- Name: get_storbit_product_report(uuid, uuid, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_product_report(p_product_id uuid, p_company_id uuid DEFAULT NULL::uuid, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
sp AS (
  SELECT o.id, o.customer_id, o.sp_no, o.sp_date
  FROM public.sp_orders o, scope
  WHERE o.deleted_at IS NULL
    AND o.company_id = scope.cid
    AND o.status NOT IN ('CANCELLED','DRAFT')
    AND (p_date_from IS NULL OR o.sp_date >= p_date_from)
    AND (p_date_to   IS NULL OR o.sp_date <= p_date_to)
),
it AS (
  SELECT s.id AS sp_id, s.customer_id,
         si.qty, si.shipped_qty, si.unit_price
  FROM sp s
  JOIN public.sp_items si
    ON si.customer_id = s.customer_id
   AND si.sp_no       = s.sp_no
  WHERE si.product_id = p_product_id
),
-- CTE dinamai `satuan`, BUKAN `uom`, supaya tak bertabrakan dengan products.uom
satuan AS (
  SELECT COALESCE(NULLIF(btrim(p.unit), ''), NULLIF(btrim(p.uom), '')) AS s
  FROM public.products p
  WHERE p.id = p_product_id
),
-- Nilai PENUH tiap SP yang memuat produk ini — SELURUH itemnya.
sp_total AS (
  SELECT s.id,
         COALESCE(SUM((si.qty * si.unit_price) + si.shipping_price), 0) * 1.11 AS nilai
  FROM (SELECT DISTINCT it.sp_id FROM it) d
  JOIN sp s ON s.id = d.sp_id
  JOIN public.sp_items si
    ON si.customer_id = s.customer_id
   AND si.sp_no       = s.sp_no
  GROUP BY s.id
),
stok AS (
  SELECT COALESCE(ROUND(SUM(ss.available)), 0)::int AS tersedia
  FROM public.stock_summary ss, scope
  WHERE ss.product_id = p_product_id
    AND ss.company_id = scope.cid
),
sum_all AS (
  SELECT
    COALESCE(SUM(it.qty), 0)::int                            AS qty_ordered,
    COALESCE(SUM(it.shipped_qty), 0)::int                    AS qty_shipped,
    COALESCE(SUM(GREATEST(it.qty - it.shipped_qty, 0)), 0)::int AS qty_outstanding,
    COALESCE(SUM(GREATEST(it.qty - it.shipped_qty, 0) * it.unit_price), 0)::numeric
                                                             AS nilai_outstanding,
    COUNT(DISTINCT it.sp_id)::int                            AS jml_sp,
    COUNT(DISTINCT it.customer_id)::int                      AS jml_customer
  FROM it
),
per_cust AS (
  SELECT
    it.customer_id,
    COALESCE(a.name, '(Tanpa nama)')                            AS customer_name,
    COALESCE(SUM(GREATEST(it.qty - it.shipped_qty, 0)), 0)::int AS qty_outstanding,
    COALESCE(SUM(GREATEST(it.qty - it.shipped_qty, 0) * it.unit_price), 0)::numeric
                                                                AS nilai_outstanding,
    COUNT(DISTINCT it.sp_id)::int                               AS jml_sp
  FROM it
  LEFT JOIN public.accounts a ON a.id = it.customer_id
  GROUP BY it.customer_id, a.name
)
SELECT jsonb_build_object(
  'summary', jsonb_build_object(
    'qty_ordered',       (SELECT qty_ordered       FROM sum_all),
    'qty_shipped',       (SELECT qty_shipped       FROM sum_all),
    'qty_outstanding',   (SELECT qty_outstanding   FROM sum_all),
    'nilai_outstanding', (SELECT nilai_outstanding FROM sum_all),
    'stok_tersedia',     (SELECT tersedia          FROM stok),
    'defisit',           GREATEST((SELECT qty_outstanding FROM sum_all)
                               - (SELECT tersedia         FROM stok), 0),
    'jml_sp',            (SELECT jml_sp            FROM sum_all),
    'jml_customer',      (SELECT jml_customer      FROM sum_all),
    'uom',               (SELECT s FROM satuan),
    'nilai_total_sp',    COALESCE((SELECT ROUND(SUM(t.nilai), 2) FROM sp_total t), 0)
  ),
  'per_customer', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'customer_id',       pc.customer_id,
             'customer_name',     pc.customer_name,
             'qty_outstanding',   pc.qty_outstanding,
             'nilai_outstanding', pc.nilai_outstanding,
             'jml_sp',            pc.jml_sp
           ) ORDER BY pc.nilai_outstanding DESC, pc.customer_name)
    FROM per_cust pc
  ), '[]'::jsonb),
  'generated_at', now()
);
$$;


ALTER FUNCTION public.get_storbit_product_report(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date) OWNER TO postgres;

--
-- Name: FUNCTION get_storbit_product_report(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.get_storbit_product_report(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date) IS 'Laporan satu produk: ringkasan + rincian per customer.
BASIS PAJAK CAMPURAN — baca per kunci:
  nilai_outstanding = DPP, BELUM termasuk PPN.
  nilai_total_sp    = BRUTO, SUDAH termasuk PPN (x1.11 mencerminkan
                      create_invoice); nilai PENUH seluruh SP yang memuat
                      produk ini, basis qty (pesanan), bukan shipped_qty.
uom = COALESCE(NULLIF(btrim(products.unit),''''), NULLIF(btrim(products.uom),'''')).
Sumber angka sp_items (bukan sp_order_items).
stok_tersedia = SUM(stock_summary.available) lintas gudang; angka SAAT INI,
tidak terpengaruh p_date_from/p_date_to.';


--
-- Name: get_storbit_product_sp_list(uuid, uuid, date, date, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid DEFAULT NULL::uuid, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_limit integer DEFAULT 200) RETURNS TABLE(sp_no text, customer_id uuid, customer_name text, dc_nama text, sp_date date, expired_date date, status text, qty integer, shipped_qty integer, sisa integer, nilai_sisa numeric, umur_hari integer)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
-- LINGKUP BARIS BERSAMA — identik di 1a/1b/1c/1d.
sp AS (
  SELECT o.id, o.customer_id, o.sp_no, o.sp_date, o.dc_id, o.status
  FROM public.sp_orders o, scope
  WHERE o.deleted_at IS NULL
    AND o.company_id = scope.cid
    AND o.status NOT IN ('CANCELLED','DRAFT')
    AND (p_date_from IS NULL OR o.sp_date >= p_date_from)
    AND (p_date_to   IS NULL OR o.sp_date <= p_date_to)
),
-- Satu SP bisa memuat lebih dari satu baris produk yang sama -> diagregasi per
-- SP supaya tabelnya satu baris per SP.
agg AS (
  SELECT
    s.id, s.customer_id, s.sp_no, s.sp_date, s.dc_id, s.status,
    SUM(si.qty)::int                            AS qty,
    SUM(si.shipped_qty)::int                    AS shipped_qty,
    SUM(GREATEST(si.qty - si.shipped_qty, 0))::int AS sisa,
    SUM(GREATEST(si.qty - si.shipped_qty, 0) * si.unit_price)::numeric AS nilai_sisa
  FROM sp s
  JOIN public.sp_items si
    ON si.customer_id = s.customer_id
   AND si.sp_no       = s.sp_no
  WHERE si.product_id = p_product_id
  GROUP BY s.id, s.customer_id, s.sp_no, s.sp_date, s.dc_id, s.status
)
SELECT
  g.sp_no,
  -- customer_id KHUSUS untuk navigasi ke Detail SP: jalur existing memakai
  -- komposit {spNo, customerId}, BUKAN sp_orders.id. Jangan dicabut.
  g.customer_id,
  COALESCE(a.name, '(Tanpa nama)') AS customer_name,
  dm.nama                          AS dc_nama,
  g.sp_date,
  -- Tenggat = MIN(sp_items.expired_date) SELURUH item SP itu — cermin
  -- get_storbit_dashboard_stats. sp_orders.expired_date bisa divergen (TD-201).
  (SELECT MIN(si2.expired_date)
     FROM public.sp_items si2
    WHERE si2.customer_id = g.customer_id
      AND si2.sp_no       = g.sp_no
      AND si2.expired_date IS NOT NULL) AS expired_date,
  g.status,
  g.qty,
  g.shipped_qty,
  g.sisa,
  g.nilai_sisa,
  (CURRENT_DATE - g.sp_date)::int AS umur_hari
FROM agg g
LEFT JOIN public.accounts  a  ON a.id  = g.customer_id
LEFT JOIN public.dc_master dm ON dm.id = g.dc_id
ORDER BY g.nilai_sisa DESC, g.sp_date DESC NULLS LAST, g.sp_no
LIMIT GREATEST(COALESCE(p_limit, 200), 1);
$$;


ALTER FUNCTION public.get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date, p_limit integer) OWNER TO postgres;

--
-- Name: FUNCTION get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date, p_limit integer); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date, p_limit integer) IS 'Daftar SP yang memuat satu produk, satu baris per SP.
nilai_sisa DPP — BELUM TERMASUK PPN.
expired_date = MIN(sp_items.expired_date) SELURUH item SP tsb, bukan
sp_orders.expired_date.
customer_id dikembalikan untuk navigasi komposit {sp_no, customer_id} ke
Detail SP; jangan dicabut walau tak dipakai sebagai kolom tampilan.';


--
-- Name: get_storbit_sp_drilldown(text, uuid, text, uuid, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_sp_drilldown(p_category text, p_customer_id uuid DEFAULT NULL::uuid, p_price_category text DEFAULT NULL::text, p_company_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200) RETURNS TABLE(sp_no text, customer_id uuid, customer_name text, dc_nama text, sp_date date, status text, expired_date date)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
sp AS (
  SELECT
    o.id, o.status, o.customer_id, o.sp_no, o.sp_date, o.dc_id,
    (SELECT MIN(si.expired_date)
       FROM public.sp_items si
      WHERE si.customer_id = o.customer_id
        AND si.sp_no       = o.sp_no
        AND si.expired_date IS NOT NULL) AS expired_date,
    EXISTS (SELECT 1 FROM public.sp_btb b
             WHERE b.sp_order_id = o.id AND b.deleted_at IS NULL) AS has_btb
  FROM public.sp_orders o, scope
  WHERE o.deleted_at IS NULL
    AND o.company_id = scope.cid
    AND (p_customer_id    IS NULL OR o.customer_id    = p_customer_id)
    AND (p_price_category IS NULL OR o.price_category = p_price_category)
),
sp_flag AS (
  SELECT s.*,
    EXISTS (
      SELECT 1 FROM public.delivery_notes dn
       WHERE dn.customer_id = s.customer_id
         AND dn.sp_no       = s.sp_no
         AND dn.status <> 'cancelled'
         AND dn.dispatched_at IS NOT NULL
         AND s.expired_date IS NOT NULL
         AND (dn.dispatched_at AT TIME ZONE 'Asia/Jakarta')::date > s.expired_date
    ) AS late_dispatch
  FROM sp s
)
SELECT
  f.sp_no,
  f.customer_id,
  a.name    AS customer_name,
  dm.nama   AS dc_nama,
  f.sp_date,
  f.status,
  f.expired_date
FROM sp_flag f
LEFT JOIN public.accounts  a  ON a.id  = f.customer_id
LEFT JOIN public.dc_master dm ON dm.id = f.dc_id
WHERE CASE p_category
  WHEN 'pending_open'          THEN f.status IN ('DRAFT','CONFIRMED','MENUNGGU_STOK','PICKING','PACKED')
  WHEN 'shipped'               THEN f.status IN ('DIKIRIM','SAMPAI','MENUNGGU_KONFIRMASI_DC')
  WHEN 'delivered_belum_btb'   THEN f.status IN ('SAMPAI','TERKIRIM_PENUH') AND NOT f.has_btb
  WHEN 'btb_terbit'            THEN f.status = 'BTB_TERBIT'
  WHEN 'terkirim_penuh'        THEN f.status = 'TERKIRIM_PENUH'
  WHEN 'expired'               THEN f.status IN ('DRAFT','CONFIRMED','MENUNGGU_STOK','PICKING','PACKED')
                                    AND f.expired_date < CURRENT_DATE
  WHEN 'mendekati_expired'     THEN f.status IN ('DRAFT','CONFIRMED','MENUNGGU_STOK','PICKING','PACKED')
                                    AND f.expired_date >= CURRENT_DATE
                                    AND date_trunc('month', f.expired_date) = date_trunc('month', CURRENT_DATE)
  WHEN 'pernah_risiko_pinalti' THEN f.late_dispatch AND f.status <> 'CANCELLED'
  WHEN 'finance'               THEN f.status IN ('INVOICED','SUBMITTED','LUNAS')
  WHEN 'cancelled'             THEN f.status = 'CANCELLED'
  ELSE false
END
ORDER BY f.sp_date DESC NULLS LAST, f.sp_no
LIMIT GREATEST(COALESCE(p_limit, 200), 1);
$$;


ALTER FUNCTION public.get_storbit_sp_drilldown(p_category text, p_customer_id uuid, p_price_category text, p_company_id uuid, p_limit integer) OWNER TO postgres;

--
-- Name: get_storbit_stock_drilldown(text, uuid, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_stock_drilldown(p_category text, p_company_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200) RETURNS TABLE(product_id uuid, sku text, product_name text, available numeric, reorder_point numeric)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
stock AS (
  SELECT
    p.id         AS product_id,
    p.code::text AS sku,
    p.name::text AS product_name,
    p.reorder_point,
    COALESCE((SELECT SUM(ss.available) FROM public.stock_summary ss
               WHERE ss.product_id = p.id
                 AND ss.company_id = p.company_id), 0) AS available
  FROM public.products p, scope
  WHERE p.deleted_at IS NULL
    AND p.company_id = scope.cid
    AND p.is_service = false
    AND p.is_active  = true
)
SELECT s.product_id, s.sku, s.product_name, s.available, s.reorder_point
FROM stock s
WHERE CASE p_category
  WHEN 'danger_stock'    THEN s.reorder_point IS NOT NULL AND s.available < s.reorder_point
  WHEN 'zero_stock'      THEN s.available <= 0
  WHEN 'rop_belum_diisi' THEN s.reorder_point IS NULL
  ELSE false
END
ORDER BY s.available ASC, s.product_name
LIMIT GREATEST(COALESCE(p_limit, 200), 1);
$$;


ALTER FUNCTION public.get_storbit_stock_drilldown(p_category text, p_company_id uuid, p_limit integer) OWNER TO postgres;

--
-- Name: get_storbit_top_outstanding_products(uuid, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_storbit_top_outstanding_products(p_company_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 10) RETURNS TABLE(product_id uuid, code text, product_name text, uom text, qty_outstanding integer, nilai_outstanding numeric, stok_tersedia integer, jml_sp integer)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
WITH scope AS (
  SELECT COALESCE(p_company_id, public.get_user_company_id()) AS cid
),
sp AS (
  SELECT o.id, o.customer_id, o.sp_no
  FROM public.sp_orders o, scope
  WHERE o.deleted_at IS NULL
    AND o.company_id = scope.cid
    AND o.status NOT IN ('CANCELLED','DRAFT')
),
-- SENGAJA TANPA filter "sisa > 0": ini juga sumber tunggal isi combobox FE.
agg AS (
  SELECT
    si.product_id,
    SUM(GREATEST(si.qty - si.shipped_qty, 0))::int AS qty_outstanding,
    SUM(GREATEST(si.qty - si.shipped_qty, 0) * si.unit_price)::numeric AS nilai_outstanding,
    COUNT(DISTINCT s.id)::int                      AS jml_sp
  FROM sp s
  JOIN public.sp_items si
    ON si.customer_id = s.customer_id
   AND si.sp_no       = s.sp_no
  WHERE si.product_id IS NOT NULL
  GROUP BY si.product_id
)
SELECT
  g.product_id,
  p.code::text AS code,
  p.name::text AS product_name,
  -- Referensi SELALU diqualify (p.unit / p.uom) supaya tak bertabrakan dengan
  -- kolom keluaran bernama `uom` di RETURNS TABLE.
  COALESCE(NULLIF(btrim(p.unit), ''), NULLIF(btrim(p.uom), ''))::text AS uom,
  g.qty_outstanding,
  g.nilai_outstanding,
  COALESCE((SELECT ROUND(SUM(ss.available))::int
              FROM public.stock_summary ss, scope
             WHERE ss.product_id = g.product_id
               AND ss.company_id = scope.cid), 0) AS stok_tersedia,
  g.jml_sp
FROM agg g
LEFT JOIN public.products p ON p.id = g.product_id
ORDER BY g.nilai_outstanding DESC, p.name
LIMIT GREATEST(COALESCE(p_limit, 10), 1);
$$;


ALTER FUNCTION public.get_storbit_top_outstanding_products(p_company_id uuid, p_limit integer) OWNER TO postgres;

--
-- Name: FUNCTION get_storbit_top_outstanding_products(p_company_id uuid, p_limit integer); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.get_storbit_top_outstanding_products(p_company_id uuid, p_limit integer) IS 'Produk dengan nilai outstanding terbesar.
nilai_outstanding DPP — BELUM TERMASUK PPN.
uom = COALESCE(NULLIF(btrim(products.unit),''''), NULLIF(btrim(products.uom),'''')).
SENGAJA tidak memfilter sisa > 0: dengan p_limit tinggi fungsi ini sekaligus
menjadi daftar SELURUH produk yang pernah muncul di SP, dan FE memakainya
sebagai sumber tunggal isi combobox produk.';


--
-- Name: get_table_columns(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_table_columns(p_table text) RETURNS TABLE(column_name text, data_type text)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT column_name::text, data_type::text
  FROM information_schema.columns
  WHERE table_schema = 'public'
  AND table_name = p_table
  ORDER BY ordinal_position;
$$;


ALTER FUNCTION public.get_table_columns(p_table text) OWNER TO postgres;

--
-- Name: get_user_company_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_user_company_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT company_id
  FROM   profiles
  WHERE  id = auth.uid()
$$;


ALTER FUNCTION public.get_user_company_id() OWNER TO postgres;

--
-- Name: FUNCTION get_user_company_id(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.get_user_company_id() IS 'Returns the company_id of the authenticated user from profiles. NULL before Phase 1.0F backfill. Used in all company-scoped RLS policies.';


--
-- Name: get_user_company_ids(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_user_company_ids() RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT DISTINCT company_id
  FROM user_roles
  WHERE user_id = auth.uid() AND is_active = true
$$;


ALTER FUNCTION public.get_user_company_ids() OWNER TO postgres;

--
-- Name: FUNCTION get_user_company_ids(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.get_user_company_ids() IS 'Returns every company_id where the authenticated user holds an active role (user_roles.is_active = true). Multi-company counterpart to get_user_company_id(), which returns only the home company (profiles.company_id) — keep using that one for policies that must stay single-value (e.g. user_login_logs).';


--
-- Name: get_user_role_code(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_user_role_code() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT r.code
  FROM user_roles ur
  JOIN roles r ON r.id = ur.role_id
  WHERE ur.user_id = auth.uid()
    AND ur.is_active = true
    AND (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  ORDER BY 
    CASE r.code 
      WHEN 'super_admin' THEN 1
      WHEN 'admin' THEN 2
      ELSE 3
    END
  LIMIT 1
$$;


ALTER FUNCTION public.get_user_role_code() OWNER TO postgres;

--
-- Name: guard_bnf_department_scope_not_home(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.guard_bnf_department_scope_not_home() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM bnf_departments
    WHERE id = NEW.department_id AND company_id = NEW.company_id
  ) THEN
    RAISE EXCEPTION 'company_id % adalah home company departemen %, tidak perlu ditulis di scope', NEW.company_id, NEW.department_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.guard_bnf_department_scope_not_home() OWNER TO postgres;

--
-- Name: guard_bnf_division_scope_not_home(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.guard_bnf_division_scope_not_home() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM bnf_divisions
    WHERE id = NEW.division_id AND company_id = NEW.company_id
  ) THEN
    RAISE EXCEPTION 'company_id % adalah home company divisi %, tidak perlu ditulis di scope', NEW.company_id, NEW.division_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.guard_bnf_division_scope_not_home() OWNER TO postgres;

--
-- Name: guard_bnf_reports_field_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.guard_bnf_reports_field_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.id          IS DISTINCT FROM OLD.id
     OR NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.report_no  IS DISTINCT FROM OLD.report_no
     OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'Field id/company_id/report_no/created_by/created_at bersifat permanen — tidak bisa diubah lewat UPDATE aplikasi. Perbaikan data harus lewat SQL Editor.';
  END IF;

  IF OLD.created_by = auth.uid() OR public.is_admin_or_above() THEN
    RETURN NEW;
  END IF;

  IF NEW.division_id            IS DISTINCT FROM OLD.division_id
     OR NEW.department_id         IS DISTINCT FROM OLD.department_id
     OR NEW.description           IS DISTINCT FROM OLD.description
     OR NEW.root_cause            IS DISTINCT FROM OLD.root_cause
     OR NEW.solution              IS DISTINCT FROM OLD.solution
     OR NEW.target_date           IS DISTINCT FROM OLD.target_date
     OR NEW.escalation_level      IS DISTINCT FROM OLD.escalation_level
     OR NEW.deleted_at            IS DISTINCT FROM OLD.deleted_at
  THEN
    RAISE EXCEPTION 'Hanya pelapor asli atau admin yang boleh mengubah field ini pada laporan BNF';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.guard_bnf_reports_field_update() OWNER TO postgres;

--
-- Name: FUNCTION guard_bnf_reports_field_update(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.guard_bnf_reports_field_update() IS 'BEFORE UPDATE guard on bnf_reports, 4 tiers: (0) auth.uid() IS NULL (SQL Editor/migrations/service-role) bypasses everything; (1) id/company_id/report_no/created_by/created_at always locked, no exceptions; (2) created_by = auth.uid() or is_admin_or_above() may edit remaining report-content columns; (3) everyone else in the company (existing bnf_reports_update RLS row-scope, unchanged) may only edit status/updated_by/closed_at. Fase G (2026-08-05): related_department_id removed from Tier 2 list — moved to bnf_report_related_departments junction table with its own RLS.';


--
-- Name: guard_daily_report_items_field_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.guard_daily_report_items_field_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT is_bnf_authorized() THEN
    IF NEW.insiden_resolution IS DISTINCT FROM OLD.insiden_resolution
       OR NEW.resolved_by IS DISTINCT FROM OLD.resolved_by
       OR NEW.pulled_to_bnf_report_id IS DISTINCT FROM OLD.pulled_to_bnf_report_id THEN
      RAISE EXCEPTION 'hanya head atau orang yang diizinkan yang boleh mengubah resolusi insiden';
    END IF;
  END IF;
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.guard_daily_report_items_field_update() OWNER TO postgres;

--
-- Name: guard_quotation_prf_consistency(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.guard_quotation_prf_consistency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_prf_inquiry uuid;
begin
  if new.prf_id is null then
    return new;
  end if;

  select inquiry_id into v_prf_inquiry
  from public.prf
  where id = new.prf_id;

  if v_prf_inquiry is null then
    raise exception 'PRF % tidak punya inquiry_id, tidak bisa jadi dasar quotation', new.prf_id;
  end if;

  if new.inquiry_id is null then
    new.inquiry_id := v_prf_inquiry;
  elsif new.inquiry_id <> v_prf_inquiry then
    raise exception 'inquiry_id quotation (%) tidak cocok dengan inquiry_id PRF (%)',
      new.inquiry_id, v_prf_inquiry;
  end if;

  return new;
end;
$$;


ALTER FUNCTION public.guard_quotation_prf_consistency() OWNER TO postgres;

--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_full_name       text;
    v_company_code    text;
    v_branch_code     text;
    v_department_code text;
    v_company_id      uuid;
    v_branch_id       uuid;
    v_department_id   uuid;
BEGIN
    v_full_name       := COALESCE(NEW.raw_user_meta_data->>'full_name',       '');
    v_company_code    := COALESCE(NEW.raw_user_meta_data->>'company_code',    'MSI');
    v_branch_code     := COALESCE(NEW.raw_user_meta_data->>'branch_code',     'HO');
    v_department_code := COALESCE(NEW.raw_user_meta_data->>'department_code', 'IT');

    SELECT id INTO v_company_id
      FROM public.companies WHERE code = v_company_code;

    IF v_company_id IS NULL THEN
        RAISE EXCEPTION
            'handle_new_user: company not found for code "%". '
            'Ensure the company exists in public.companies before creating '
            'auth users for that entity. Valid codes: MSI, JCI, SBI.',
            v_company_code;
    END IF;

    SELECT id INTO v_branch_id
      FROM public.branches
     WHERE company_id = v_company_id AND code = v_branch_code;

    SELECT id INTO v_department_id
      FROM public.departments
     WHERE company_id = v_company_id AND code = v_department_code;

    INSERT INTO public.profiles (
        id,
        full_name,
        active,
        company_id,
        branch_id,
        department_id,
        mfa_required
    )
    VALUES (
        NEW.id,
        v_full_name,
        true,
        v_company_id,
        v_branch_id,
        v_department_id,
        false
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

--
-- Name: FUNCTION handle_new_user(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.handle_new_user() IS 'Auth trigger: creates a profiles row when a new Supabase Auth user is created. Reads company_code, branch_code, department_code from raw_user_meta_data with defaults MSI / HO / IT. Resolves company_id (required), branch_id and department_id (optional) from master data tables before inserting. Raises an exception if company_code is not found in public.companies. ON CONFLICT (id) DO NOTHING makes it safe to re-run. SECURITY DEFINER + SET search_path = public prevents hijacking. Patched in migration 016 after profiles.company_id became NOT NULL (Phase 1.0F).';


--
-- Name: has_permission(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.has_permission(module_code text, action_code text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles     ur
    JOIN   roles           r   ON r.id  = ur.role_id
    JOIN   role_permissions rp ON rp.role_id = r.id
    JOIN   permissions      p  ON p.id  = rp.permission_id
    WHERE  ur.user_id      = auth.uid()
      AND  ur.is_active     = true
      AND  (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
      AND  p.module         = module_code
      AND  p.action         = action_code
  )
$$;


ALTER FUNCTION public.has_permission(module_code text, action_code text) OWNER TO postgres;

--
-- Name: FUNCTION has_permission(module_code text, action_code text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.has_permission(module_code text, action_code text) IS 'True if the current user holds the given {module}.{action} permission through any active role. Performs 3 JOINs — use for mutation checks, not bulk SELECT policies.';


--
-- Name: has_role(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.has_role(role_code text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles       r  ON r.id  = ur.role_id
    WHERE  ur.user_id      = auth.uid()
      AND  ur.is_active     = true
      AND  r.code           = role_code
      AND  (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  )
$$;


ALTER FUNCTION public.has_role(role_code text) OWNER TO postgres;

--
-- Name: FUNCTION has_role(role_code text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.has_role(role_code text) IS 'True if the current user holds the specified role code in any active user_roles assignment. Does not fall back to legacy roles.';


--
-- Name: hrga_submit_approval(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.hrga_submit_approval(p_request_id uuid, p_action text, p_comment text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_status   text; v_level int; v_total int;
  v_company  uuid; v_type uuid;
  v_cfg_role text; v_cfg_user uuid;
  v_action   text; v_new_status text;
BEGIN
  IF p_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'Aksi tidak valid: % (hanya approve/reject).', p_action;
  END IF;
  v_action := CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END;

  SELECT status, current_level, total_levels, company_id, request_type_id
    INTO v_status, v_level, v_total, v_company, v_type
    FROM hrga_requests
   WHERE id = p_request_id AND deleted_at IS NULL;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Request tidak ditemukan.';
  END IF;
  IF v_status NOT IN ('submitted', 'under_review') THEN
    RAISE EXCEPTION 'Request sudah tidak bisa di-approve/reject (status=%).', v_status;
  END IF;

  -- Lookup ini melayani DUA hal sekaligus: sumber otorisasi DAN sumber
  -- approver_role yang NOT NULL di hrga_request_approvals.
  SELECT approver_role, approver_user_id
    INTO v_cfg_role, v_cfg_user
    FROM hrga_approval_configs
   WHERE request_type_id = v_type
     AND level           = v_level
     AND company_id      = v_company
     AND is_active       = true
   LIMIT 1;

  IF v_cfg_role IS NULL THEN
    RAISE EXCEPTION 'Belum ada konfigurasi approver untuk tipe request ini di level %.', v_level;
  END IF;

  IF NOT (is_super_admin()
          OR has_role(v_cfg_role)
          OR (v_cfg_user IS NOT NULL AND v_cfg_user = v_uid)) THEN
    RAISE EXCEPTION 'Anda bukan approver untuk request ini di level %.', v_level;
  END IF;

  INSERT INTO hrga_request_approvals
    (request_id, level, approver_id, approver_role, action, comment, actioned_at)
  VALUES
    (p_request_id, v_level, v_uid, v_cfg_role, v_action,
     NULLIF(btrim(COALESCE(p_comment, '')), ''), now());

  IF v_action = 'rejected' THEN
    v_new_status := 'rejected';
  ELSIF v_level >= v_total THEN
    v_new_status := 'approved';
  ELSE
    v_new_status := 'under_review';
  END IF;

  UPDATE hrga_requests SET
    status        = v_new_status,
    updated_by    = v_uid,
    approved_at   = CASE WHEN v_new_status = 'approved'     THEN now()      ELSE approved_at   END,
    rejected_at   = CASE WHEN v_new_status = 'rejected'     THEN now()      ELSE rejected_at   END,
    current_level = CASE WHEN v_new_status = 'under_review' THEN v_level + 1 ELSE current_level END
  WHERE id = p_request_id;
END; $$;


ALTER FUNCTION public.hrga_submit_approval(p_request_id uuid, p_action text, p_comment text) OWNER TO postgres;

--
-- Name: increment_document_sequence(uuid, text, text, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.increment_document_sequence(p_company_id uuid, p_document_type text, p_department_code text, p_year integer, p_month integer DEFAULT 0, p_day integer DEFAULT 0) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_new_seq integer;
BEGIN
  UPDATE document_sequences
  SET    last_sequence = last_sequence + 1
  WHERE  company_id      = p_company_id
    AND  document_type   = p_document_type
    AND  department_code = p_department_code
    AND  year            = p_year
    AND  month           = p_month
    AND  day             = p_day
  RETURNING last_sequence INTO v_new_seq;

  IF NOT FOUND THEN
    INSERT INTO document_sequences
      (company_id, document_type, department_code, year, month, day, last_sequence)
    VALUES
      (p_company_id, p_document_type, p_department_code, p_year, p_month, p_day, 1)
    ON CONFLICT (company_id, document_type, department_code, year, month, day)
    DO UPDATE SET last_sequence = document_sequences.last_sequence + 1
    RETURNING last_sequence INTO v_new_seq;
  END IF;

  RETURN v_new_seq;
END;
$$;


ALTER FUNCTION public.increment_document_sequence(p_company_id uuid, p_document_type text, p_department_code text, p_year integer, p_month integer, p_day integer) OWNER TO postgres;

--
-- Name: indomarco_dashboard_stats(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.indomarco_dashboard_stats(p_customer_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  WITH base AS (
    SELECT
      sp_no,
      qty,
      shipped_qty,
      NULLIF(trim(dc), '') AS dc_trim,
      sp_date::date        AS sp_date
    FROM public.sp_items
    WHERE customer_id = p_customer_id
  ),
  kpi AS (
    SELECT
      COUNT(DISTINCT sp_no) FILTER (WHERE sp_no IS NOT NULL AND sp_no <> '') AS total_sp,
      COALESCE(SUM(qty), 0)         AS total_ordered,
      COALESCE(SUM(shipped_qty), 0) AS total_realized,
      COUNT(DISTINCT dc_trim)       AS dc_count,
      MIN(sp_date)                  AS period_min,
      MAX(sp_date)                  AS period_max
    FROM base
  ),
  dc_vol AS (
    SELECT dc_trim AS dc, COALESCE(SUM(qty), 0) AS volume
    FROM base
    WHERE dc_trim IS NOT NULL
    GROUP BY dc_trim
  ),
  monthly AS (
    SELECT to_char(sp_date, 'YYYY-MM') AS ym,
           COUNT(DISTINCT sp_no) FILTER (WHERE sp_no IS NOT NULL AND sp_no <> '') AS sp_count
    FROM base
    WHERE sp_date IS NOT NULL
    GROUP BY to_char(sp_date, 'YYYY-MM')
  )
  SELECT jsonb_build_object(
    'total_sp',       (SELECT total_sp       FROM kpi),
    'total_ordered',  (SELECT total_ordered  FROM kpi),
    'total_realized', (SELECT total_realized FROM kpi),
    'dc_count',       (SELECT dc_count       FROM kpi),
    'period_min',     (SELECT period_min     FROM kpi),
    'period_max',     (SELECT period_max     FROM kpi),
    'dc_volumes',     COALESCE((SELECT jsonb_agg(jsonb_build_object('dc', dc, 'volume', volume)) FROM dc_vol), '[]'::jsonb),
    'monthly',        COALESCE((SELECT jsonb_agg(jsonb_build_object('ym', ym, 'sp_count', sp_count)) FROM monthly), '[]'::jsonb)
  );
$$;


ALTER FUNCTION public.indomarco_dashboard_stats(p_customer_id uuid) OWNER TO postgres;

--
-- Name: int_to_roman(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.int_to_roman(num integer) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
declare
  vals int[]  := array[1000,900,500,400,100,90,50,40,10,9,5,4,1];
  syms text[] := array['M','CM','D','CD','C','XC','L','XL','X','IX','V','IV','I'];
  result text := '';
  i int;
begin
  if num is null or num <= 0 then return null; end if;
  for i in 1..array_length(vals,1) loop
    while num >= vals[i] loop
      result := result || syms[i];
      num := num - vals[i];
    end loop;
  end loop;
  return result;
end; $$;


ALTER FUNCTION public.int_to_roman(num integer) OWNER TO postgres;

--
-- Name: is_admin_or_above(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_admin_or_above() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles r ON r.id = ur.role_id
    WHERE  ur.user_id     = auth.uid()
      AND  ur.is_active   = true
      AND  r.code         IN ('super_admin', 'admin')
      AND  (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  )
$$;


ALTER FUNCTION public.is_admin_or_above() OWNER TO postgres;

--
-- Name: FUNCTION is_admin_or_above(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.is_admin_or_above() IS 'True if current user is admin or super_admin. Includes legacy profiles.role=''super'' fallback for Phase 1.0D→1.0F transition.';


--
-- Name: is_admin_tier_role(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_admin_tier_role(p_role_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.roles r
    WHERE r.id = p_role_id
      AND r.code IN ('super_admin', 'admin')
  )
$$;


ALTER FUNCTION public.is_admin_tier_role(p_role_id uuid) OWNER TO postgres;

--
-- Name: FUNCTION is_admin_tier_role(p_role_id uuid); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.is_admin_tier_role(p_role_id uuid) IS 'True if the given role_id resolves to super_admin or admin. SECURITY DEFINER so the check is independent of caller''s RLS visibility into roles. Used to gate user_roles writes — see user_roles_insert/update.';


--
-- Name: is_bnf_authorized(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_bnf_authorized() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT is_super_admin()
    OR EXISTS (SELECT 1 FROM bnf_departments WHERE head_profile_id = auth.uid() AND deleted_at IS NULL)
    OR EXISTS (SELECT 1 FROM bnf_divisions WHERE director_profile_id = auth.uid() AND deleted_at IS NULL)
    OR EXISTS (
      SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
      WHERE ur.user_id = auth.uid() AND ur.is_active = true
        AND r.code IN ('ceo', 'gm', 'gm_bd', 'manager', 'finance_controller')
    )
    OR EXISTS (
      SELECT 1 FROM bnf_authorized_users a
      WHERE a.profile_id = auth.uid()
        AND a.company_id = get_user_company_id()
        AND a.revoked_at IS NULL
    );
$$;


ALTER FUNCTION public.is_bnf_authorized() OWNER TO postgres;

--
-- Name: is_manager_or_above(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_manager_or_above() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid()
      AND r.code IN ('super_admin','admin','ceo','gm','gm_bd','manager','supervisor')
      AND ur.is_active = true
      AND (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  );
$$;


ALTER FUNCTION public.is_manager_or_above() OWNER TO postgres;

--
-- Name: is_sp_item_writer(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_sp_item_writer() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid()
      AND r.code IN ('super_admin','admin','manager','operations')
      AND ur.is_active = true
      AND (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  );
$$;


ALTER FUNCTION public.is_sp_item_writer() OWNER TO postgres;

--
-- Name: FUNCTION is_sp_item_writer(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.is_sp_item_writer() IS 'Izin TULIS baris item SP (sp_items/sp_order_items). Sengaja TIDAK memakai is_manager_or_above(): ceo/gm/gm_bd VIEW-ONLY di konteks ini (keputusan Den 2 Sep 2026, sejalan 04_ROLE_PERMISSION_MATRIX baris Logistics: ceo=R, gm_bd=tanpa akses). Jangan tambah role tanpa memperbarui matrix itu juga.';


--
-- Name: is_super_admin(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_super_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles r ON r.id = ur.role_id
    WHERE  ur.user_id     = auth.uid()
      AND  ur.is_active   = true
      AND  r.code         = 'super_admin'
      AND  (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  )
$$;


ALTER FUNCTION public.is_super_admin() OWNER TO postgres;

--
-- Name: FUNCTION is_super_admin(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.is_super_admin() IS 'True if the current user holds super_admin role (new user_roles table) or legacy profiles.role=''super''. Legacy fallback removed after Phase 1.0F.';


--
-- Name: lock_inquiry_owner_when_closed(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.lock_inquiry_owner_when_closed() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id
     AND OLD.status IN ('WON', 'LOST', 'CANCELLED') THEN
    RAISE EXCEPTION
      'Pemilik deal terkunci: inquiry % sudah berstatus %. Kepemilikan tidak bisa dipindahkan setelah deal ditutup, demi menjaga angka Sales Performance dan Win Rate historis tetap utuh.',
      COALESCE(OLD.inquiry_no, OLD.id::text), OLD.status;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.lock_inquiry_owner_when_closed() OWNER TO postgres;

--
-- Name: FUNCTION lock_inquiry_owner_when_closed(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.lock_inquiry_owner_when_closed() IS 'Menolak perubahan inquiries.owner_id ketika status LAMA sudah WON/LOST/CANCELLED. Sengaja RAISE EXCEPTION, bukan silent revert. Dipasang oleh migrasi 20260830000002.';


--
-- Name: log_inquiry_status_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_inquiry_status_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_last_at   timestamptz;
  v_start     timestamptz;
  v_duration  integer;
BEGIN
  SELECT h.changed_at INTO v_last_at
    FROM inquiry_status_history h
   WHERE h.inquiry_id = NEW.id
   ORDER BY h.changed_at DESC
   LIMIT 1;

  v_start := COALESCE(v_last_at, OLD.created_at);

  IF v_start IS NOT NULL THEN
    v_duration := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_start))::int);
  END IF;

  INSERT INTO inquiry_status_history
    (inquiry_id, from_status, to_status, changed_by, reason, duration_seconds)
  VALUES
    (NEW.id, OLD.status, NEW.status, auth.uid(),
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


ALTER FUNCTION public.log_inquiry_status_change() OWNER TO postgres;

--
-- Name: log_lifecycle_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_lifecycle_change() RETURNS trigger
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


ALTER FUNCTION public.log_lifecycle_change() OWNER TO postgres;

--
-- Name: log_product_price_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_product_price_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.product_price_history
    (product_id, company_id, old_price, new_price, changed_by, source)
  VALUES
    (NEW.id, NEW.company_id, OLD.default_price, NEW.default_price, auth.uid(), 'product_update');
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.log_product_price_change() OWNER TO postgres;

--
-- Name: mark_delivery_delivered(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.mark_delivery_delivered(p_delivery_note_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_status text; v_cust uuid; v_sp text;
BEGIN
  SELECT status, customer_id, sp_no INTO v_status, v_cust, v_sp
    FROM delivery_notes WHERE id=p_delivery_note_id;
  IF v_sp IS NULL THEN RAISE EXCEPTION 'Surat jalan tidak ditemukan'; END IF;
  IF v_status <> 'in_transit' THEN
    RAISE EXCEPTION 'Hanya surat jalan in_transit yang bisa ditandai terkirim (status=%)', v_status; END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles       r ON r.id = ur.role_id
    WHERE  ur.user_id  = auth.uid()
      AND  ur.is_active = true
      AND  (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
      AND  r.code = ANY (ARRAY['super_admin','admin','ceo','gm','gm_bd',
                               'manager','supervisor','operations'])
  ) THEN
    RAISE EXCEPTION 'Tidak berhak menandai surat jalan sebagai terkirim. Butuh salah satu role: super_admin, admin, ceo, gm, gm_bd, manager, supervisor, atau operations.';
  END IF;
  UPDATE delivery_notes SET status='delivered', delivered_at=now() WHERE id=p_delivery_note_id;
  PERFORM sp_recompute_status(v_cust, v_sp);
END; $$;


ALTER FUNCTION public.mark_delivery_delivered(p_delivery_note_id uuid) OWNER TO postgres;

--
-- Name: mark_inquiry_won(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.mark_inquiry_won(p_inquiry_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_status      text;
  v_created_by  uuid;
  v_prospect_id uuid;
  v_customer_id uuid;
  v_inquiry_no  text;
  v_company_id  uuid;
  v_account_id  uuid;
  v_user_email  text;
  v_user_role   text;
BEGIN
  SELECT status, created_by, prospect_id, customer_id, inquiry_no, company_id
    INTO v_status, v_created_by, v_prospect_id, v_customer_id, v_inquiry_no, v_company_id
  FROM public.inquiries
  WHERE id = p_inquiry_id
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inquiry tidak ditemukan.';
  END IF;

  IF v_created_by IS DISTINCT FROM auth.uid() AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Anda bukan pembuat inquiry ini — tidak bisa menandai WON.';
  END IF;

  IF v_status = 'WON' THEN
    RAISE EXCEPTION 'Inquiry ini sudah WON.';
  END IF;

  UPDATE public.inquiries
  SET status = 'WON', updated_at = now()
  WHERE id = p_inquiry_id;

  v_account_id := COALESCE(v_prospect_id, v_customer_id);
  IF v_account_id IS NOT NULL THEN
    UPDATE public.accounts
    SET pipeline_stage = 'WON'
    WHERE id = v_account_id
      AND deleted_at IS NULL;
  END IF;

  SELECT email INTO v_user_email FROM public.profiles WHERE id = auth.uid();

  SELECT r.code INTO v_user_role
  FROM public.user_roles ur
  JOIN public.roles r ON r.id = ur.role_id
  WHERE ur.user_id = auth.uid()
    AND ur.is_active = true
    AND (ur.valid_until IS NULL OR ur.valid_until >= CURRENT_DATE)
  ORDER BY ur.granted_at DESC
  LIMIT 1;

  INSERT INTO public.audit_logs (
    user_id, user_email, user_role, company_id,
    action, entity_type, entity_id, entity_label,
    old_data, new_data, notes
  ) VALUES (
    auth.uid(), v_user_email, v_user_role, v_company_id,
    'MARK_INQUIRY_WON', 'INQUIRY', p_inquiry_id, v_inquiry_no,
    jsonb_build_object('status', v_status),
    jsonb_build_object('status', 'WON'),
    'Ditandai WON manual dari Inquiry Detail'
  );
END;
$$;


ALTER FUNCTION public.mark_inquiry_won(p_inquiry_id uuid) OWNER TO postgres;

--
-- Name: mark_ttf_received(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.mark_ttf_received(p_invoice_id uuid, p_received_by text, p_ttf_no text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_status      text;
  v_invoice_no  text;
  v_sp_order_id uuid;
  v_customer_id uuid;
  v_sp_no       text;
  v_ttf_id      uuid;
BEGIN
  IF NOT (is_super_admin() OR is_manager_or_above() OR has_role('finance_controller')) THEN
    RAISE EXCEPTION 'Tidak punya izin mencatat penerimaan TTF.';
  END IF;

  IF p_received_by IS NULL OR btrim(p_received_by) = '' THEN
    RAISE EXCEPTION 'Nama penerima wajib diisi.';
  END IF;

  SELECT i.status, i.invoice_no, i.sp_order_id
    INTO v_status, v_invoice_no, v_sp_order_id
    FROM sp_invoices i
   WHERE i.id = p_invoice_id AND i.deleted_at IS NULL;

  IF v_status IS NULL   THEN RAISE EXCEPTION 'Invoice tidak ditemukan.'; END IF;
  IF v_status = 'void'  THEN RAISE EXCEPTION 'Invoice sudah void.';      END IF;
  IF v_status = 'draft' THEN
    RAISE EXCEPTION 'Invoice masih draft — terbitkan dulu sebelum menandai TTF diterima.';
  END IF;

  SELECT o.customer_id, o.sp_no INTO v_customer_id, v_sp_no
    FROM sp_orders o WHERE o.id = v_sp_order_id AND o.deleted_at IS NULL;

  SELECT t.id INTO v_ttf_id
    FROM ar_ttfs t
   WHERE t.invoice_id = p_invoice_id
   ORDER BY t.created_at
   LIMIT 1;

  IF v_ttf_id IS NULL THEN
    INSERT INTO ar_ttfs (
      no_ttf, tanggal_ttf, tanggal_menerima, no_inv, no_sp,
      customer_id, notes, sp_order_id, invoice_id, diterima_oleh
    ) VALUES (
      COALESCE(NULLIF(btrim(p_ttf_no), ''), ''),
      CURRENT_DATE,
      CURRENT_DATE,
      COALESCE(v_invoice_no, ''),
      COALESCE(v_sp_no, ''),
      v_customer_id,
      COALESCE(NULLIF(btrim(p_notes), ''), ''),
      v_sp_order_id,
      p_invoice_id,
      btrim(p_received_by)
    )
    RETURNING id INTO v_ttf_id;
  ELSE
    UPDATE ar_ttfs SET
      tanggal_menerima = CURRENT_DATE,
      diterima_oleh    = btrim(p_received_by),
      no_ttf = COALESCE(NULLIF(btrim(p_ttf_no), ''), no_ttf),
      notes  = COALESCE(NULLIF(btrim(p_notes),  ''), notes),
      sp_order_id = COALESCE(sp_order_id, v_sp_order_id),
      customer_id = COALESCE(customer_id, v_customer_id),
      no_inv = CASE WHEN no_inv = '' THEN COALESCE(v_invoice_no, '') ELSE no_inv END,
      no_sp  = CASE WHEN no_sp  = '' THEN COALESCE(v_sp_no, '')      ELSE no_sp  END
     WHERE id = v_ttf_id;
  END IF;

  RETURN v_ttf_id;
END;
$$;


ALTER FUNCTION public.mark_ttf_received(p_invoice_id uuid, p_received_by text, p_ttf_no text, p_notes text) OWNER TO postgres;

--
-- Name: normalize_account_name(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.normalize_account_name(p_name text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  SELECT lower(regexp_replace(
           regexp_replace(coalesce(p_name,''), '\y(PT|CV|TBK)\y\.?', '', 'gi'),
           '[^a-zA-Z0-9]', '', 'g'));
$$;


ALTER FUNCTION public.normalize_account_name(p_name text) OWNER TO postgres;

--
-- Name: notify_sp_milestone(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_sp_milestone(p_sp_order_id uuid, p_milestone text, p_old_status text, p_new_status text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  PERFORM net.http_post(
    url := 'https://untmpqceexwxzuhlmyrg.supabase.co/functions/v1/notify-sp-milestone',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret FROM vault.decrypted_secrets
        WHERE name = 'aging_pipeline_key'
      )
    ),
    body := jsonb_build_object(
      'sp_order_id', p_sp_order_id,
      'milestone', p_milestone,
      'old_status', p_old_status,
      'new_status', p_new_status
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[notify_sp_milestone] gagal enqueue notifikasi utk sp_order % (%->%): %',
    p_sp_order_id, p_old_status, p_new_status, SQLERRM;
END;
$$;


ALTER FUNCTION public.notify_sp_milestone(p_sp_order_id uuid, p_milestone text, p_old_status text, p_new_status text) OWNER TO postgres;

--
-- Name: prf_claim(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prf_claim(p_prf_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_company uuid;
  v_status  text;
  v_ack     uuid;
BEGIN
  SELECT company_id, status, acknowledged_by
    INTO v_company, v_status, v_ack
  FROM prf WHERE id = p_prf_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRF tidak ditemukan';
  END IF;

  IF NOT (is_super_admin() OR (v_company = get_user_company_id() AND has_role('procurement'))) THEN
    RAISE EXCEPTION 'Tidak berhak mengambil PRF ini';
  END IF;

  IF v_status <> 'SUBMITTED' THEN
    RAISE EXCEPTION 'PRF harus berstatus SUBMITTED (sekarang: %)', v_status;
  END IF;

  IF v_ack IS NOT NULL THEN
    RAISE EXCEPTION 'PRF sudah diambil orang lain';
  END IF;

  UPDATE prf
  SET status = 'ACKNOWLEDGED', acknowledged_by = v_uid, acknowledged_at = now()
  WHERE id = p_prf_id;
END;
$$;


ALTER FUNCTION public.prf_claim(p_prf_id uuid) OWNER TO postgres;

--
-- Name: prf_mark_quoted(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prf_mark_quoted(p_prf_id uuid, p_waiver_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_company uuid;
  v_status  text;
  v_ack     uuid;
  v_offers  int;
  v_reason  text := NULLIF(TRIM(COALESCE(p_waiver_reason, '')), '');
BEGIN
  SELECT company_id, status, acknowledged_by
    INTO v_company, v_status, v_ack
  FROM prf WHERE id = p_prf_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRF tidak ditemukan';
  END IF;

  IF NOT (is_super_admin() OR (v_company = get_user_company_id() AND v_ack = v_uid)) THEN
    RAISE EXCEPTION 'Hanya pemegang PRF yang boleh menyatakan penawaran siap';
  END IF;

  IF v_status <> 'ACKNOWLEDGED' THEN
    RAISE EXCEPTION 'PRF harus berstatus ACKNOWLEDGED (sekarang: %)', v_status;
  END IF;

  SELECT count(*) INTO v_offers
  FROM prf_vendor_offers
  WHERE prf_id = p_prf_id AND deleted_at IS NULL;

  IF v_offers < 1 THEN
    RAISE EXCEPTION 'Belum ada penawaran vendor sama sekali';
  END IF;

  IF v_offers < 3 AND v_reason IS NULL THEN
    RAISE EXCEPTION 'Baru % penawaran. Minimum 3, atau isi alasan kenapa kurang', v_offers;
  END IF;

  UPDATE prf
  SET status = 'QUOTED',
      min_offers_waiver_reason = CASE WHEN v_offers < 3 THEN v_reason ELSE NULL END
  WHERE id = p_prf_id;
END;
$$;


ALTER FUNCTION public.prf_mark_quoted(p_prf_id uuid, p_waiver_reason text) OWNER TO postgres;

--
-- Name: prf_release(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prf_release(p_prf_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_company uuid;
  v_status  text;
  v_ack     uuid;
BEGIN
  SELECT company_id, status, acknowledged_by
    INTO v_company, v_status, v_ack
  FROM prf WHERE id = p_prf_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRF tidak ditemukan';
  END IF;

  IF v_status <> 'ACKNOWLEDGED' THEN
    RAISE EXCEPTION 'PRF tidak sedang dikerjakan siapa pun (status: %)', v_status;
  END IF;

  IF NOT (
    is_super_admin()
    OR (v_company = get_user_company_id() AND (v_ack = v_uid OR is_manager_or_above()))
  ) THEN
    RAISE EXCEPTION 'Hanya pemegang PRF atau manager yang boleh melepas';
  END IF;

  UPDATE prf
  SET status = 'SUBMITTED', acknowledged_by = NULL, acknowledged_at = NULL
  WHERE id = p_prf_id;
END;
$$;


ALTER FUNCTION public.prf_release(p_prf_id uuid) OWNER TO postgres;

--
-- Name: prf_select_offer(uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prf_select_offer(p_prf_id uuid, p_offer_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_company uuid;
  v_status  text;
  v_owner   uuid;
  v_ok      boolean;
BEGIN
  SELECT company_id, status, created_by
    INTO v_company, v_status, v_owner
  FROM prf WHERE id = p_prf_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRF tidak ditemukan';
  END IF;

  IF NOT (
    is_super_admin()
    OR (v_company = get_user_company_id() AND (v_owner = v_uid OR is_manager_or_above()))
  ) THEN
    RAISE EXCEPTION 'Hanya sales pemilik PRF atau manager yang boleh memilih penawaran';
  END IF;

  IF v_status <> 'QUOTED' THEN
    RAISE EXCEPTION 'Penawaran belum siap dipilih (status: %)', v_status;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM prf_vendor_offers
    WHERE id = p_offer_id AND prf_id = p_prf_id AND deleted_at IS NULL
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Penawaran tidak ditemukan atau bukan milik PRF ini';
  END IF;

  UPDATE prf
  SET selected_offer_id = p_offer_id,
      selected_by = v_uid,
      selected_at = now()
  WHERE id = p_prf_id;
END;
$$;


ALTER FUNCTION public.prf_select_offer(p_prf_id uuid, p_offer_id uuid) OWNER TO postgres;

--
-- Name: record_payment(uuid, numeric, date, text, numeric, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_payment(p_invoice_id uuid, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_reference text DEFAULT NULL::text, p_pph numeric DEFAULT 0, p_bukti_potong_url text DEFAULT NULL::text, p_bukti_potong_no text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  c_code_bank   CONSTANT text := '1-1101';  -- Bank
  c_code_ar     CONSTANT text := '1-1200';  -- Piutang Usaha
  c_code_pph23  CONSTANT text := '1-1300';  -- PPh 23 Dibayar Dimuka
  c_tolerance   CONSTANT numeric := 1;

  v_uid         uuid := auth.uid();
  v_company_id  uuid;
  v_sp_order_id uuid;
  v_total       numeric(18,2);
  v_inv_status  text;
  v_invoice_no  text;
  v_customer_id uuid;
  v_sp_no       text;
  v_payment_id  uuid;
  v_settled     numeric(18,2);
  v_new_status  text;
  v_je_id       uuid;
  v_acc_bank    uuid;
  v_acc_ar      uuid;
  v_acc_pph     uuid;
BEGIN
  IF NOT (is_super_admin() OR has_role('finance_controller')) THEN
    RAISE EXCEPTION 'Tidak punya izin mencatat pembayaran.';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Nominal pembayaran harus lebih besar dari nol.';
  END IF;
  IF COALESCE(p_pph, 0) < 0 THEN
    RAISE EXCEPTION 'PPh tidak boleh negatif.';
  END IF;

  SELECT i.company_id, i.sp_order_id, i.total_amount, i.status, i.invoice_no
    INTO v_company_id, v_sp_order_id, v_total, v_inv_status, v_invoice_no
    FROM sp_invoices i
   WHERE i.id = p_invoice_id AND i.deleted_at IS NULL;

  IF v_company_id IS NULL  THEN RAISE EXCEPTION 'Invoice tidak ditemukan.'; END IF;
  IF v_inv_status = 'void' THEN
    RAISE EXCEPTION 'Invoice sudah void — pembayaran tidak bisa dicatat.';
  END IF;
  IF v_inv_status = 'draft' THEN
    RAISE EXCEPTION 'Invoice masih draft — terbitkan dulu sebelum mencatat pembayaran.';
  END IF;

  SELECT id INTO v_acc_bank FROM chart_of_accounts
   WHERE company_id = v_company_id AND code = c_code_bank AND deleted_at IS NULL;
  IF v_acc_bank IS NULL THEN
    RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_bank;
  END IF;

  SELECT id INTO v_acc_ar FROM chart_of_accounts
   WHERE company_id = v_company_id AND code = c_code_ar AND deleted_at IS NULL;
  IF v_acc_ar IS NULL THEN
    RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_ar;
  END IF;

  IF COALESCE(p_pph, 0) > 0 THEN
    SELECT id INTO v_acc_pph FROM chart_of_accounts
     WHERE company_id = v_company_id AND code = c_code_pph23 AND deleted_at IS NULL;
    IF v_acc_pph IS NULL THEN
      RAISE EXCEPTION 'Akun [%] belum ada di chart_of_accounts untuk company ini — hubungi Finance Controller.', c_code_pph23;
    END IF;
  END IF;

  INSERT INTO sp_payments
    (invoice_id, payment_date, amount, pph, reference, bukti_potong_url, bukti_potong_no, created_by)
  VALUES
    (p_invoice_id, COALESCE(p_payment_date, CURRENT_DATE), p_amount,
     COALESCE(p_pph, 0), p_reference, p_bukti_potong_url, p_bukti_potong_no, v_uid)
  RETURNING id INTO v_payment_id;

  SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(pph), 0)
    INTO v_settled
    FROM sp_payments WHERE invoice_id = p_invoice_id;

  v_new_status := CASE
    WHEN v_settled >= (v_total - c_tolerance) THEN 'paid'
    WHEN v_settled > 0                        THEN 'partial'
    ELSE v_inv_status END;

  IF v_new_status IS DISTINCT FROM v_inv_status THEN
    UPDATE sp_invoices
       SET status = v_new_status, updated_at = now()
     WHERE id = p_invoice_id;
  END IF;

  INSERT INTO journal_entries
    (company_id, entry_date, reference_type, reference_id, description, created_by)
  VALUES
    (v_company_id, COALESCE(p_payment_date, CURRENT_DATE), 'payment_received', v_payment_id,
     'Penerimaan pembayaran invoice ' || COALESCE(v_invoice_no, '(tanpa nomor)'), v_uid)
  RETURNING id INTO v_je_id;

  INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
  VALUES (v_je_id, v_acc_bank, p_amount, 0);

  IF COALESCE(p_pph, 0) > 0 THEN
    INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
    VALUES (v_je_id, v_acc_pph, p_pph, 0);
  END IF;

  INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
  VALUES (v_je_id, v_acc_ar, 0, p_amount + COALESCE(p_pph, 0));

  IF v_new_status = 'paid' THEN
    SELECT customer_id, sp_no INTO v_customer_id, v_sp_no
      FROM sp_orders WHERE id = v_sp_order_id AND deleted_at IS NULL;
    IF v_customer_id IS NOT NULL THEN
      PERFORM sp_recompute_status(v_customer_id, v_sp_no);
    END IF;
  END IF;

  RETURN v_payment_id;
END;
$$;


ALTER FUNCTION public.record_payment(p_invoice_id uuid, p_amount numeric, p_payment_date date, p_reference text, p_pph numeric, p_bukti_potong_url text, p_bukti_potong_no text) OWNER TO postgres;

--
-- Name: save_prf_pricing(uuid, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.save_prf_pricing(p_prf_id uuid, p_header jsonb, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  v_count   int;
  v_vendors int;
BEGIN
  -- 1) Header jawaban harga (RLS prf_update_status: procurement + SUBMITTED/ACKNOWLEDGED).
  UPDATE public.prf SET
    suggested_rate = NULLIF(p_header->>'suggested_rate','')::numeric,
    rate_currency  = COALESCE(NULLIF(p_header->>'rate_currency',''), 'IDR'),
    valid_from     = NULLIF(p_header->>'valid_from','')::date,
    valid_until    = NULLIF(p_header->>'valid_until','')::date,
    pricing_notes  = NULLIF(p_header->>'pricing_notes',''),
    exchange_rates = COALESCE(p_header->'exchange_rates', exchange_rates),
    answered_by    = auth.uid(),
    answered_at    = now()
  WHERE id = p_prf_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'PRF tidak ditemukan atau tidak ada izin menyimpan jawaban harga (RLS).';
  END IF;

  IF p_items IS NOT NULL AND jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'save_prf_pricing: p_items harus jsonb array (atau NULL), tetapi menerima jsonb_typeof = %', jsonb_typeof(p_items);
  END IF;

  -- Guard aturan bisnis: satu PRF hanya boleh punya SATU vendor pemenang.
  IF p_items IS NOT NULL THEN
    SELECT count(DISTINCT it->>'vendor_id') INTO v_vendors
    FROM jsonb_array_elements(p_items) AS it
    WHERE COALESCE(NULLIF(it->>'is_awarded','')::boolean, true) = true
      AND NULLIF(it->>'vendor_id','') IS NOT NULL;

    IF v_vendors > 1 THEN
      RAISE EXCEPTION 'save_prf_pricing: hanya boleh satu vendor pemenang per PRF, tetapi menerima % vendor ter-award.', v_vendors;
    END IF;
  END IF;

  -- 2) Replace rincian biaya WARISAN saja.
  -- ⭐ 27 Jul 2026: DELETE dibatasi ke baris ber-offer_id NULL. Tanpa syarat ini,
  -- panel "Jawaban Harga" lama akan MENGHAPUS seluruh baris biaya milik
  -- prf_vendor_offers (modul Penawaran Vendor) secara diam-diam.
  DELETE FROM public.prf_cost_items
  WHERE prf_id = p_prf_id AND offer_id IS NULL;

  IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    INSERT INTO public.prf_cost_items (
      prf_id, component, cost_type, amount, currency, sort_order, notes,
      vendor_id, item_group, is_awarded, exchange_rate
    )
    SELECT p_prf_id,
      it->>'component',
      CASE WHEN (it->>'cost_type') = 'internal' THEN 'internal' ELSE 'vendor' END,
      COALESCE(NULLIF(it->>'amount','')::numeric, 0),
      COALESCE(NULLIF(it->>'currency',''), 'IDR'),
      COALESCE(NULLIF(it->>'sort_order','')::int, 0),
      NULLIF(it->>'notes',''),
      NULLIF(it->>'vendor_id','')::uuid,
      NULLIF(it->>'item_group',''),
      COALESCE(NULLIF(it->>'is_awarded','')::boolean, true),
      COALESCE(NULLIF(it->>'exchange_rate','')::numeric, 1)
    FROM jsonb_array_elements(p_items) AS it;
  END IF;

  RETURN jsonb_build_object('ok', true, 'prf_id', p_prf_id);
END;
$$;


ALTER FUNCTION public.save_prf_pricing(p_prf_id uuid, p_header jsonb, p_items jsonb) OWNER TO postgres;

--
-- Name: save_quotation(uuid, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.save_quotation(p_quotation_id uuid, p_header jsonb, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE v_count int;
BEGIN
  UPDATE public.quotations SET
    quotation_no     = COALESCE(p_header->>'quotation_no', quotation_no),
    quote_date       = COALESCE(NULLIF(p_header->>'quote_date','')::date, quote_date),
    inquiry_id       = COALESCE(NULLIF(p_header->>'inquiry_id','')::uuid, inquiry_id),
    prospect_id      = COALESCE(NULLIF(p_header->>'prospect_id','')::uuid, prospect_id),
    customer_id      = COALESCE(NULLIF(p_header->>'customer_id','')::uuid, customer_id),
    service_type     = COALESCE(p_header->>'service_type', service_type),
    valid_until      = COALESCE(NULLIF(p_header->>'valid_until','')::date, valid_until),
    payment_terms_id = COALESCE(NULLIF(p_header->>'payment_terms_id','')::uuid, payment_terms_id),
    currency_code    = COALESCE(p_header->>'currency_code', currency_code),
    exchange_rates   = CASE WHEN p_header ? 'exchange_rates' THEN p_header->'exchange_rates' ELSE exchange_rates END,
    notes            = CASE WHEN p_header ? 'notes'          THEN p_header->>'notes'          ELSE notes          END,
    terms            = CASE WHEN p_header ? 'terms'          THEN p_header->>'terms'          ELSE terms          END,
    internal_notes   = CASE WHEN p_header ? 'internal_notes' THEN p_header->>'internal_notes' ELSE internal_notes END,
    route            = CASE WHEN p_header ? 'route'          THEN p_header->>'route'          ELSE route          END,
    subtotal         = COALESCE(NULLIF(p_header->>'subtotal','')::numeric, subtotal),
    tax_amount       = COALESCE(NULLIF(p_header->>'tax_amount','')::numeric, tax_amount),
    total_amount     = COALESCE(NULLIF(p_header->>'total_amount','')::numeric, total_amount),
    vat_rate         = COALESCE(NULLIF(p_header->>'vat_rate','')::numeric, vat_rate),
    status           = COALESCE(p_header->>'status', status),
    usd_rate         = COALESCE(NULLIF(p_header->>'usd_rate','')::numeric, usd_rate),
    discount_pct     = COALESCE(NULLIF(p_header->>'discount_pct','')::numeric, discount_pct),
    margin_floor     = COALESCE(NULLIF(p_header->>'margin_floor','')::numeric, margin_floor),
    pricing_done_at  = COALESCE(NULLIF(p_header->>'pricing_done_at','')::timestamptz, pricing_done_at),
    attention_to     = CASE WHEN p_header ? 'attention_to'     THEN p_header->>'attention_to'     ELSE attention_to     END,
    pickup_address   = CASE WHEN p_header ? 'pickup_address'   THEN p_header->>'pickup_address'   ELSE pickup_address   END,
    delivery_address = CASE WHEN p_header ? 'delivery_address' THEN p_header->>'delivery_address' ELSE delivery_address END,
    cargo_mode       = CASE WHEN p_header ? 'cargo_mode'       THEN p_header->>'cargo_mode'       ELSE cargo_mode       END,
    gw               = CASE WHEN p_header ? 'gw'               THEN p_header->>'gw'               ELSE gw               END,
    dimension        = CASE WHEN p_header ? 'dimension'        THEN p_header->>'dimension'        ELSE dimension        END,
    cw               = CASE WHEN p_header ? 'cw'               THEN p_header->>'cw'               ELSE cw               END,
    cbm              = CASE WHEN p_header ? 'cbm'              THEN p_header->>'cbm'              ELSE cbm              END,
    container_type   = CASE WHEN p_header ? 'container_type'   THEN p_header->>'container_type'   ELSE container_type   END,
    container_qty    = CASE WHEN p_header ? 'container_qty'    THEN NULLIF(p_header->>'container_qty','')::int ELSE container_qty END,
    updated_at       = now(),
    updated_by       = auth.uid()
  WHERE id = p_quotation_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'Quotation tidak ditemukan atau tidak ada izin edit (RLS).';
  END IF;

  DELETE FROM public.quotation_items WHERE quotation_id = p_quotation_id;

  IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    INSERT INTO public.quotation_items (
      quotation_id, sort_order, description, qty, unit, unit_price, notes,
      group_name, currency, unit_label, exchange_rate, total, cost_price,
      if_any
    )
    SELECT p_quotation_id,
      COALESCE(NULLIF(it->>'sort_order','')::int, 0),
      it->>'description',
      NULLIF(it->>'qty','')::numeric,
      it->>'unit',
      NULLIF(it->>'unit_price','')::numeric,
      it->>'notes',
      it->>'group_name',
      it->>'currency',
      it->>'unit_label',
      NULLIF(it->>'exchange_rate','')::numeric,
      NULLIF(it->>'total','')::numeric,
      NULLIF(it->>'cost_price','')::numeric,
      COALESCE((it->>'if_any')::boolean, false)
    FROM jsonb_array_elements(p_items) AS it;
  END IF;

  RETURN jsonb_build_object('ok', true, 'quotation_id', p_quotation_id);
END;
$$;


ALTER FUNCTION public.save_quotation(p_quotation_id uuid, p_header jsonb, p_items jsonb) OWNER TO postgres;

--
-- Name: set_customer_on_inquiry_won(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_customer_on_inquiry_won() RETURNS trigger
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
    AND COALESCE(account_status,'')  <> 'customer'
    AND deleted_at IS NULL;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_customer_on_inquiry_won() OWNER TO postgres;

--
-- Name: set_customer_on_won(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_customer_on_won() RETURNS trigger
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


ALTER FUNCTION public.set_customer_on_won() OWNER TO postgres;

--
-- Name: set_daily_report_items_defaults(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_daily_report_items_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.category = 'task' AND NEW.task_status IS NULL THEN
    NEW.task_status := 'pending';
  END IF;
  IF NEW.category = 'insiden' AND NEW.insiden_resolution IS NULL THEN
    NEW.insiden_resolution := 'pending_review';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_daily_report_items_defaults() OWNER TO postgres;

--
-- Name: set_inquiry_quoted_on_quotation_sent(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_inquiry_quoted_on_quotation_sent() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.status = 'SENT'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'SENT')
     AND NEW.inquiry_id IS NOT NULL THEN
    UPDATE public.inquiries
    SET status = 'QUOTED', updated_at = now()
    WHERE id = NEW.inquiry_id
      AND deleted_at IS NULL
      AND status IN ('OPEN','IN_REVIEW');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_inquiry_quoted_on_quotation_sent() OWNER TO postgres;

--
-- Name: set_inquiry_review_on_prf_submit(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_inquiry_review_on_prf_submit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.status = 'SUBMITTED'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'SUBMITTED')
     AND NEW.inquiry_id IS NOT NULL THEN
    UPDATE public.inquiries
    SET status = 'IN_REVIEW', updated_at = now()
    WHERE id = NEW.inquiry_id
      AND deleted_at IS NULL
      AND status = 'OPEN';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_inquiry_review_on_prf_submit() OWNER TO postgres;

--
-- Name: set_inquiry_won_on_so(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_inquiry_won_on_so() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.status <> 'SENT' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'SENT' THEN RETURN NEW; END IF;
  IF NEW.inquiry_id IS NULL THEN RETURN NEW; END IF;

  UPDATE public.inquiries
  SET status = 'WON', updated_at = now()
  WHERE id = NEW.inquiry_id
    AND deleted_at IS NULL
    AND status IN ('OPEN','IN_REVIEW','QUOTED','NEGOTIATION');

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_inquiry_won_on_so() OWNER TO postgres;

--
-- Name: set_product_category_prices(uuid, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_product_category_prices(p_product_id uuid, p_semester numeric, p_tahunan numeric, p_project numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_company uuid; v_cur numeric;
        v_cols text[] := ARRAY['semester','tahunan','project'];
        v_new  numeric[]; v_c text; v_i int;
BEGIN
  SELECT company_id INTO v_company FROM products WHERE id = p_product_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produk tidak ditemukan: %', p_product_id; END IF;
  IF NOT (is_super_admin() OR (v_company = get_user_company_id() AND is_admin_or_above())) THEN
    RAISE EXCEPTION 'Tidak diizinkan mengubah harga produk ini';
  END IF;
  IF (p_semester IS NOT NULL AND p_semester < 0)
     OR (p_tahunan IS NOT NULL AND p_tahunan < 0)
     OR (p_project IS NOT NULL AND p_project < 0) THEN
    RAISE EXCEPTION 'Harga tidak boleh negatif';
  END IF;
  v_new := ARRAY[p_semester, p_tahunan, p_project];
  FOR v_i IN 1..3 LOOP
    v_c := v_cols[v_i];
    SELECT CASE v_c WHEN 'semester' THEN price_semester
                    WHEN 'tahunan'  THEN price_tahunan
                    ELSE price_project END
      INTO v_cur FROM products WHERE id = p_product_id;
    IF v_cur IS DISTINCT FROM v_new[v_i] THEN
      IF v_c = 'semester' THEN UPDATE products SET price_semester = v_new[v_i] WHERE id = p_product_id;
      ELSIF v_c = 'tahunan' THEN UPDATE products SET price_tahunan = v_new[v_i] WHERE id = p_product_id;
      ELSE UPDATE products SET price_project = v_new[v_i] WHERE id = p_product_id; END IF;
      INSERT INTO product_price_history
        (product_id, company_id, old_price, new_price, changed_by, source, price_category)
      VALUES (p_product_id, v_company, v_cur, v_new[v_i], auth.uid(), 'category_edit', v_c);
    END IF;
  END LOOP;
END; $$;


ALTER FUNCTION public.set_product_category_prices(p_product_id uuid, p_semester numeric, p_tahunan numeric, p_project numeric) OWNER TO postgres;

--
-- Name: set_prospect_on_inquiry(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_prospect_on_inquiry() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.accounts
  SET account_status  = 'prospect',
      lifecycle_stage = 'prospect'
  WHERE id = COALESCE(NEW.prospect_id, NEW.customer_id)
    AND lifecycle_stage IN ('lead','mql','sql')
    AND account_status  IN ('lead','mql','sql');
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_prospect_on_inquiry() OWNER TO postgres;

--
-- Name: set_sp_expired_date(uuid, text, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_sp_expired_date(p_customer_id uuid, p_sp_no text, p_expired_date date) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_sp_order_id uuid; v_company uuid; v_status text;
BEGIN
  IF p_expired_date IS NULL THEN
    RAISE EXCEPTION 'Tanggal expired wajib diisi.';
  END IF;
  SELECT id, company_id, status
    INTO v_sp_order_id, v_company, v_status
    FROM sp_orders
   WHERE customer_id = p_customer_id
     AND sp_no       = p_sp_no
     AND deleted_at IS NULL;
  IF v_sp_order_id IS NULL THEN
    RAISE EXCEPTION 'SP % untuk customer ini tidak ditemukan.', p_sp_no;
  END IF;
  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak mengubah tenggat SP ini';
  END IF;
  IF v_status = 'CANCELLED' THEN
    RAISE EXCEPTION 'SP sudah dibatalkan — tenggat tidak bisa diubah.';
  END IF;
  UPDATE sp_orders
     SET expired_date = p_expired_date, updated_at = now()
   WHERE id = v_sp_order_id;
  UPDATE sp_items
     SET expired_date = p_expired_date, updated_at = now()
   WHERE customer_id = p_customer_id
     AND sp_no       = p_sp_no;
END; $$;


ALTER FUNCTION public.set_sp_expired_date(p_customer_id uuid, p_sp_no text, p_expired_date date) OWNER TO postgres;

--
-- Name: set_sp_finance_docs(uuid, text, boolean, boolean, boolean, boolean, date, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_sp_order_id uuid; v_company uuid; v_status text;
BEGIN
  SELECT id, company_id, status
    INTO v_sp_order_id, v_company, v_status
    FROM sp_orders
   WHERE customer_id = p_customer_id AND sp_no = p_sp_no AND deleted_at IS NULL;
  IF v_sp_order_id IS NULL THEN
    RAISE EXCEPTION 'SP % untuk customer ini tidak ditemukan.', p_sp_no;
  END IF;

  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND (has_role('finance_controller') OR has_role('finance')))) THEN
    RAISE EXCEPTION 'Tidak berhak mengubah status dokumen SP ini';
  END IF;

  IF v_status = 'CANCELLED' THEN
    RAISE EXCEPTION 'SP sudah dibatalkan — status dokumen tidak bisa diubah.';
  END IF;

  UPDATE sp_orders
     SET inv = p_inv, fp = p_fp, submit = p_submit, kirim = p_kirim,
         submit_date = p_submit_date,
         email_status = NULLIF(btrim(p_email_status), ''),
         updated_at = now()
   WHERE id = v_sp_order_id;

  UPDATE sp_items
     SET inv = p_inv, fp = p_fp, submit = p_submit, kirim = p_kirim,
         submit_date = p_submit_date,
         email_status = NULLIF(btrim(p_email_status), ''),
         updated_at = now()
   WHERE customer_id = p_customer_id AND sp_no = p_sp_no;
END; $$;


ALTER FUNCTION public.set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text) OWNER TO postgres;

--
-- Name: FUNCTION set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text) IS 'Satu-satunya penulis sah inv/fp/submit/kirim/submit_date/email_status. Menulis sp_orders (sumber kebenaran) DAN menyinkronkan ke SEMUA sp_items se-SP dalam satu transaksi. Guard sumbu FINANCE (super_admin / finance_controller / finance) — SENGAJA tanpa is_manager_or_above(): matrix baris Finance menaruh manager di R, bukan CRUD.';


--
-- Name: set_sp_status(text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_sp_status(p_sp_no text, p_status text, p_reason text, p_customer_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_uid uuid := auth.uid(); v_count integer; v_sp_id uuid; v_old_status text;
BEGIN
  IF p_status NOT IN ('draft','confirmed','cancelled') THEN RAISE EXCEPTION 'invalid sp_status: %', p_status; END IF;
  UPDATE public.sp_items
     SET sp_status=p_status,
         confirmed_at = CASE WHEN p_status='confirmed' THEN now()    ELSE confirmed_at  END,
         confirmed_by = CASE WHEN p_status='confirmed' THEN v_uid    ELSE confirmed_by  END,
         cancelled_at = CASE WHEN p_status='cancelled' THEN now()    ELSE cancelled_at  END,
         cancelled_by = CASE WHEN p_status='cancelled' THEN v_uid    ELSE cancelled_by  END,
         cancel_reason= CASE WHEN p_status='cancelled' THEN p_reason ELSE cancel_reason END,
         updated_at   = now()
   WHERE sp_no = p_sp_no AND customer_id = p_customer_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF p_status = 'cancelled' THEN
    SELECT id, status INTO v_sp_id, v_old_status
      FROM public.sp_orders WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND deleted_at IS NULL;
    UPDATE public.sp_orders
       SET status='CANCELLED', cancelled_at=now(), cancelled_by=v_uid, cancel_reason=p_reason, updated_at=now()
     WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status <> 'CANCELLED';
    IF FOUND AND v_sp_id IS NOT NULL THEN
      PERFORM public.notify_sp_milestone(v_sp_id, 'CANCELLED', v_old_status, 'CANCELLED');
    END IF;
  ELSE
    IF p_status='confirmed' THEN
      UPDATE public.sp_orders
         SET confirmed_at=COALESCE(confirmed_at,now()), confirmed_by=COALESCE(confirmed_by,v_uid), updated_at=now()
       WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status <> 'CANCELLED';
    END IF;
    PERFORM sp_recompute_status(p_customer_id, p_sp_no);
  END IF;
  RETURN v_count;
END; $$;


ALTER FUNCTION public.set_sp_status(p_sp_no text, p_status text, p_reason text, p_customer_id uuid) OWNER TO postgres;

--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_updated_at() OWNER TO postgres;

--
-- Name: FUNCTION set_updated_at(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.set_updated_at() IS 'Trigger function: sets updated_at = now() before every UPDATE. Defined in migration 000 (legacy baseline) and reused by all subsequent migrations via CREATE OR REPLACE — safe to re-run.';


--
-- Name: sp_delete_btb(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sp_delete_btb(p_btb_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_cust uuid; v_sp text; v_company uuid;
BEGIN
  SELECT b.customer_id, o.sp_no, o.company_id INTO v_cust, v_sp, v_company
    FROM sp_btb b JOIN sp_orders o ON o.id = b.sp_order_id
   WHERE b.id = p_btb_id AND b.deleted_at IS NULL;
  IF v_sp IS NULL THEN RAISE EXCEPTION 'BTB tidak ditemukan atau sudah dihapus.'; END IF;
  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak menghapus BTB ini';
  END IF;
  UPDATE sp_btb SET deleted_at = now() WHERE id = p_btb_id;
  PERFORM sp_recompute_status(v_cust, v_sp);
END; $$;


ALTER FUNCTION public.sp_delete_btb(p_btb_id uuid) OWNER TO postgres;

--
-- Name: sp_issue_btb(uuid, text, text, integer, date, uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sp_issue_btb(p_customer_id uuid, p_sp_no text, p_btb_no text, p_qty integer DEFAULT NULL::integer, p_btb_date date DEFAULT NULL::date, p_delivery_note_id uuid DEFAULT NULL::uuid, p_remarks text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_company uuid; v_sp_order_id uuid; v_uid uuid := auth.uid();
  v_btb_id uuid; v_existing uuid;
BEGIN
  IF btrim(COALESCE(p_btb_no,'')) = '' THEN
    RAISE EXCEPTION 'Nomor BTB wajib diisi.'; END IF;
  SELECT id, company_id INTO v_sp_order_id, v_company
    FROM sp_orders
   WHERE customer_id = p_customer_id AND sp_no = p_sp_no AND deleted_at IS NULL;
  IF v_sp_order_id IS NULL THEN
    RAISE EXCEPTION 'SP % untuk customer ini tidak ditemukan.', p_sp_no; END IF;
  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND (is_manager_or_above() OR has_role('operations')))) THEN
    RAISE EXCEPTION 'Tidak berhak menerbitkan BTB untuk SP ini';
  END IF;
  IF p_delivery_note_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM delivery_notes
        WHERE id = p_delivery_note_id AND customer_id = p_customer_id AND sp_no = p_sp_no) THEN
    RAISE EXCEPTION 'Surat jalan bukan milik SP ini.'; END IF;
  SELECT id INTO v_existing FROM sp_btb
   WHERE customer_id = p_customer_id AND btb_no = btrim(p_btb_no) AND deleted_at IS NULL;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  INSERT INTO sp_btb (company_id, sp_order_id, delivery_note_id, customer_id,
                      btb_no, btb_date, qty, received_at, received_by, remarks)
  VALUES (v_company, v_sp_order_id, p_delivery_note_id, p_customer_id,
          btrim(p_btb_no), p_btb_date, p_qty, now(), v_uid,
          NULLIF(btrim(COALESCE(p_remarks,'')),''))
  RETURNING id INTO v_btb_id;
  PERFORM sp_recompute_status(p_customer_id, p_sp_no);
  RETURN v_btb_id;
END; $$;


ALTER FUNCTION public.sp_issue_btb(p_customer_id uuid, p_sp_no text, p_btb_no text, p_qty integer, p_btb_date date, p_delivery_note_id uuid, p_remarks text) OWNER TO postgres;

--
-- Name: sp_recompute_status(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sp_recompute_status(p_customer_id uuid, p_sp_no text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_company uuid := 'd2e5e565-5f67-4954-b8d9-5979a2a0c697';
  v_id uuid; v_status text; v_new text;
  v_confirmed bool; v_has_done bool; v_has_active bool; v_short bool;
  v_ordered int; v_shipped int; v_has_dispatch bool; v_has_delivered bool;
  v_in_transit bool; v_all_delivered bool;
  v_has_btb bool; v_has_invoice bool; v_submitted bool;
  v_paid bool;
BEGIN
  SELECT id, status INTO v_id, v_status
    FROM sp_orders WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND deleted_at IS NULL;
  IF v_id IS NULL THEN RETURN; END IF;
  IF v_status IN ('CANCELLED','LUNAS') THEN RETURN; END IF;
  v_confirmed  := EXISTS(SELECT 1 FROM sp_items WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND sp_status='confirmed');
  v_has_done   := EXISTS(SELECT 1 FROM picking_lists WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status='done');
  v_has_active := EXISTS(SELECT 1 FROM picking_lists WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status IN ('pending','in_progress'));
  v_short := EXISTS(
    SELECT 1 FROM sp_items si
     WHERE si.customer_id=p_customer_id AND si.sp_no=p_sp_no
       AND si.sp_status='confirmed' AND (si.qty - si.shipped_qty) > 0
       AND (si.qty - si.shipped_qty) > COALESCE(
             (SELECT SUM(ss.available) FROM stock_summary ss
               WHERE ss.company_id=v_company AND ss.product_id=si.product_id), 0));
  SELECT COALESCE(SUM(qty),0), COALESCE(SUM(shipped_qty),0) INTO v_ordered, v_shipped
    FROM sp_items WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND sp_status='confirmed';
  v_has_dispatch  := EXISTS(SELECT 1 FROM delivery_notes WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status IN ('in_transit','delivered'));
  v_has_delivered := EXISTS(SELECT 1 FROM delivery_notes WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status='delivered');
  v_in_transit    := EXISTS(SELECT 1 FROM delivery_notes WHERE customer_id=p_customer_id AND sp_no=p_sp_no AND status='in_transit');
  v_all_delivered := v_has_delivered AND NOT v_in_transit;
  v_has_btb     := EXISTS(SELECT 1 FROM sp_btb      WHERE sp_order_id=v_id AND deleted_at IS NULL);
  v_has_invoice := EXISTS(SELECT 1 FROM sp_invoices WHERE sp_order_id=v_id AND status <> 'void');
  v_submitted   := EXISTS(SELECT 1 FROM sp_invoices WHERE sp_order_id=v_id AND submitted_at IS NOT NULL AND status <> 'void');
  v_paid        := EXISTS(SELECT 1 FROM sp_invoices WHERE sp_order_id=v_id AND status='paid');
  v_new := CASE
    WHEN v_paid                                   THEN 'LUNAS'
    WHEN v_submitted                              THEN 'SUBMITTED'
    WHEN v_has_invoice                            THEN 'INVOICED'
    WHEN v_has_btb                                THEN 'BTB_TERBIT'
    WHEN v_ordered > 0 AND v_shipped >= v_ordered
         AND (v_all_delivered OR NOT v_has_dispatch) THEN 'TERKIRIM_PENUH'
    WHEN v_ordered > 0 AND v_shipped >= v_ordered    THEN 'MENUNGGU_KONFIRMASI_DC'
    WHEN v_all_delivered                             THEN 'SAMPAI'
    WHEN v_has_dispatch                              THEN 'DIKIRIM'
    WHEN v_has_done                               THEN 'PACKED'
    WHEN v_has_active                             THEN 'PICKING'
    WHEN v_confirmed AND v_short                  THEN 'MENUNGGU_STOK'
    WHEN v_confirmed                              THEN 'CONFIRMED'
    ELSE 'DRAFT' END;
  IF v_new IS DISTINCT FROM v_status THEN
    UPDATE sp_orders SET status=v_new, updated_at=now() WHERE id=v_id AND status <> 'CANCELLED';
    IF FOUND AND v_new IN ('CONFIRMED','MENUNGGU_KONFIRMASI_DC','BTB_TERBIT','SUBMITTED') THEN
      PERFORM public.notify_sp_milestone(v_id, v_new, v_status, v_new);
    END IF;
  END IF;
END; $$;


ALTER FUNCTION public.sp_recompute_status(p_customer_id uuid, p_sp_no text) OWNER TO postgres;

--
-- Name: stamp_inquiry_closure(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.stamp_inquiry_closure() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  NEW.closed_at := COALESCE(NEW.closed_at, now());
  NEW.closed_by := COALESCE(NEW.closed_by, auth.uid());
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.stamp_inquiry_closure() OWNER TO postgres;

--
-- Name: storbit_sp_customers(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.storbit_sp_customers() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('customer_id', customer_id, 'name', name)
      ORDER BY name
    ),
    '[]'::jsonb
  )
  FROM (
    SELECT DISTINCT a.id AS customer_id, a.name AS name
    FROM public.sp_items s
    JOIN public.accounts a ON a.id = s.customer_id
    WHERE s.customer_id IS NOT NULL
      AND a.company_id = 'd2e5e565-5f67-4954-b8d9-5979a2a0c697'
  ) t;
$$;


ALTER FUNCTION public.storbit_sp_customers() OWNER TO postgres;

--
-- Name: submit_invoice(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_invoice(p_invoice_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_sp_order_id uuid; v_customer_id uuid; v_sp_no text; v_status text;
  v_company_id uuid; v_invoice_date date;
  v_override_days int; v_term_days int; v_due_date date;
BEGIN
  IF NOT (is_super_admin() OR is_manager_or_above() OR has_role('finance_controller')) THEN
    RAISE EXCEPTION 'Tidak punya izin submit invoice.';
  END IF;

  SELECT sp_order_id, status, company_id, invoice_date
    INTO v_sp_order_id, v_status, v_company_id, v_invoice_date
    FROM sp_invoices WHERE id = p_invoice_id AND deleted_at IS NULL;
  IF v_sp_order_id IS NULL THEN RAISE EXCEPTION 'Invoice tidak ditemukan.'; END IF;
  IF v_status <> 'issued' THEN
    RAISE EXCEPTION 'Invoice berstatus % — cuma invoice "issued" yang bisa di-submit.', v_status;
  END IF;

  SELECT customer_id, sp_no INTO v_customer_id, v_sp_no FROM sp_orders WHERE id = v_sp_order_id;

  SELECT invoice_payment_terms_days INTO v_override_days FROM accounts WHERE id = v_customer_id;

  IF v_override_days IS NOT NULL THEN
    v_term_days := v_override_days;
  ELSE
    SELECT (CASE WHEN pt.is_active THEN pt.days_due ELSE NULL END) INTO v_term_days
      FROM entity_finance_settings efs
      LEFT JOIN payment_terms pt ON pt.id = efs.default_payment_term_id
      WHERE efs.company_id = v_company_id;
    IF v_term_days IS NULL THEN
      SELECT default_payment_terms INTO v_term_days FROM entity_finance_settings WHERE company_id = v_company_id;
    END IF;
    v_term_days := COALESCE(v_term_days, 30);
  END IF;

  v_due_date := v_invoice_date + v_term_days;

  UPDATE sp_invoices SET status = 'submitted', submitted_at = now(), updated_at = now(), due_date = v_due_date
   WHERE id = p_invoice_id;

  PERFORM sp_recompute_status(v_customer_id, v_sp_no);
END; $$;


ALTER FUNCTION public.submit_invoice(p_invoice_id uuid) OWNER TO postgres;

--
-- Name: sync_deal_value_on_quotation_accept(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_deal_value_on_quotation_accept() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Hanya trigger kalau status berubah jadi 'ACCEPTED'
  IF NEW.status = 'ACCEPTED' AND (OLD.status IS DISTINCT FROM 'ACCEPTED') THEN
    -- Update estimated_value di accounts via prospect_id
    IF NEW.prospect_id IS NOT NULL THEN
      UPDATE public.accounts
      SET estimated_value = NEW.total_amount,
          updated_at = now()
      WHERE id = NEW.prospect_id;
    END IF;
    -- Update juga via customer_id kalau prospect_id null
    IF NEW.prospect_id IS NULL AND NEW.customer_id IS NOT NULL THEN
      UPDATE public.accounts
      SET estimated_value = NEW.total_amount,
          updated_at = now()
      WHERE id = NEW.customer_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.sync_deal_value_on_quotation_accept() OWNER TO postgres;

--
-- Name: sync_last_activity_on_account(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_last_activity_on_account() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_account_id uuid;
BEGIN
  v_account_id := COALESCE(NEW.account_id, OLD.account_id);
  IF v_account_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  UPDATE accounts a
  SET last_activity_at = (
    SELECT max(COALESCE(act.completed_at, act.created_at))
    FROM activities act
    WHERE act.account_id = v_account_id
      AND act.deleted_at IS NULL
  )
  WHERE a.id = v_account_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION public.sync_last_activity_on_account() OWNER TO postgres;

--
-- Name: sync_lifecycle_columns(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_lifecycle_columns() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.lifecycle_stage IS NULL THEN
      NEW.lifecycle_stage := NEW.account_status;
    ELSE
      NEW.account_status  := NEW.lifecycle_stage;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    NEW.lifecycle_stage := NEW.account_status;
  END IF;

  IF NEW.lifecycle_stage IS DISTINCT FROM OLD.lifecycle_stage THEN
    NEW.account_status := NEW.lifecycle_stage;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.sync_lifecycle_columns() OWNER TO postgres;

--
-- Name: FUNCTION sync_lifecycle_columns(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.sync_lifecycle_columns() IS 'Menjaga accounts.account_status dan accounts.lifecycle_stage identik selama transisi jalur B. Sengaja tanpa tie-break: nol jalur tulis menyentuh keduanya (diukur 7 Sep 2026). Dicabut oleh migrasi 20260907000002.';


--
-- Name: sync_profile_email(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_profile_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  NEW.email = (SELECT email FROM auth.users WHERE id = NEW.id);
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.sync_profile_email() OWNER TO postgres;

--
-- Name: track_stage_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.track_stage_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.pipeline_stage IS DISTINCT FROM OLD.pipeline_stage THEN
    NEW.stage_changed_at = now();
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.track_stage_change() OWNER TO postgres;

--
-- Name: update_sp_item_dual(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_sp_item_dual(p_id uuid, p_item jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_rec sp_items%ROWTYPE; v_company uuid;
BEGIN
  v_rec := jsonb_populate_record(null::sp_items, p_item);
  SELECT o.company_id INTO v_company
    FROM sp_items si
    JOIN sp_orders o
      ON o.customer_id = si.customer_id
     AND o.sp_no       = si.sp_no
     AND o.deleted_at IS NULL
   WHERE si.id = p_id;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Item SP tidak ditemukan, atau SP induknya belum ada di sp_orders.';
  END IF;

  IF NOT (is_super_admin() OR (v_company IN (SELECT get_user_company_ids())
          AND is_sp_item_writer())) THEN
    RAISE EXCEPTION 'Tidak berhak mengubah item SP ini';
  END IF;

  UPDATE sp_items SET
    sp_date = v_rec.sp_date, sp_no = v_rec.sp_no, customer_id = v_rec.customer_id,
    product_id = v_rec.product_id, product_name = v_rec.product_name, sku = v_rec.sku,
    qty = v_rec.qty, shipped_qty = v_rec.shipped_qty,
    exp_date = v_rec.exp_date, dc = v_rec.dc,
    shipping_date = v_rec.shipping_date, sla_days = v_rec.sla_days,
    estimated_delivery_date = v_rec.estimated_delivery_date, arrival_date = v_rec.arrival_date,
    unit_price = v_rec.unit_price, shipping_price = v_rec.shipping_price,
    notes = v_rec.notes,
    updated_at = now()
  WHERE id = p_id;

  UPDATE sp_order_items SET
    qty = v_rec.qty,
    sla_days = v_rec.sla_days,
    estimated_delivery_date = v_rec.estimated_delivery_date,
    shipping_price = v_rec.shipping_price,
    notes = v_rec.notes,
    updated_at = now()
  WHERE legacy_sp_item_id = p_id;
END; $$;


ALTER FUNCTION public.update_sp_item_dual(p_id uuid, p_item jsonb) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_lifecycle_history; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.account_lifecycle_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    from_stage character varying(50),
    to_stage character varying(50) NOT NULL,
    reason text,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.account_lifecycle_history OWNER TO postgres;

--
-- Name: TABLE account_lifecycle_history; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.account_lifecycle_history IS 'Riwayat perubahan accounts.lifecycle_stage. Audit-only: ditulis EKSKLUSIF oleh trg_z_log_lifecycle_change (SECURITY DEFINER), nol policy tulis untuk authenticated.';


--
-- Name: COLUMN account_lifecycle_history.changed_by; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.account_lifecycle_history.changed_by IS 'auth.uid() saat perubahan. NULL bila perubahan datang dari trigger SECURITY DEFINER tanpa konteks user (mis. promosi otomatis dari inquiry).';


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    legal_name character varying,
    customer_type character varying,
    tax_id character varying,
    address text,
    city character varying,
    country character varying DEFAULT 'Indonesia'::character varying,
    phone character varying,
    email character varying,
    pic_name character varying,
    pic_phone character varying,
    pic_email character varying,
    source character varying,
    assigned_to uuid,
    pipeline_stage character varying DEFAULT 'NEW'::character varying,
    lost_reason text,
    converted_at timestamp with time zone,
    converted_to uuid,
    payment_terms_id uuid,
    currency_code character varying DEFAULT 'IDR'::character varying,
    credit_limit numeric,
    notes text,
    is_active boolean DEFAULT true,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    estimated_closing_date date,
    assigned_profile uuid,
    company_prefix text,
    won_reason text,
    bant_commodity text,
    bant_origin text,
    bant_destination text,
    bant_frequency text,
    bant_current_vendor text,
    bant_payment text,
    bant_decision_maker text,
    bant_score integer DEFAULT 0,
    account_status character varying(50) DEFAULT 'lead'::character varying,
    owner_company_id uuid,
    tier character varying(20),
    code text,
    nomor_kontrak text,
    default_dc text,
    last_activity_at timestamp with time zone DEFAULT now(),
    became_customer_at timestamp with time zone,
    estimated_value numeric DEFAULT 0,
    bant_budget smallint DEFAULT 0,
    bant_authority smallint DEFAULT 0,
    bant_need smallint DEFAULT 0,
    bant_timeline smallint DEFAULT 0,
    stage_changed_at timestamp with time zone DEFAULT now(),
    is_in_lead_pool boolean DEFAULT false,
    lead_pool_reason text,
    lead_pool_at timestamp with time zone,
    pull_justification text,
    pull_requested_at timestamp with time zone,
    pull_approved_by uuid,
    pull_approved_at timestamp with time zone,
    pull_status text,
    is_odoo_customer boolean DEFAULT false NOT NULL,
    invoice_payment_terms_days integer,
    lifecycle_stage character varying(50),
    CONSTRAINT accounts_account_status_check CHECK (((account_status)::text = ANY ((ARRAY['lead'::character varying, 'mql'::character varying, 'sql'::character varying, 'prospect'::character varying, 'customer'::character varying, 'free_agent'::character varying, 'lost'::character varying])::text[]))),
    CONSTRAINT accounts_bant_authority_check CHECK (((bant_authority IS NULL) OR ((bant_authority >= 0) AND (bant_authority <= 3)))),
    CONSTRAINT accounts_bant_budget_check CHECK (((bant_budget IS NULL) OR ((bant_budget >= 0) AND (bant_budget <= 3)))),
    CONSTRAINT accounts_bant_need_check CHECK (((bant_need IS NULL) OR ((bant_need >= 0) AND (bant_need <= 3)))),
    CONSTRAINT accounts_bant_timeline_check CHECK (((bant_timeline IS NULL) OR ((bant_timeline >= 0) AND (bant_timeline <= 3)))),
    CONSTRAINT accounts_lifecycle_stage_check CHECK (((lifecycle_stage)::text = ANY (ARRAY[('lead'::character varying)::text, ('mql'::character varying)::text, ('sql'::character varying)::text, ('prospect'::character varying)::text, ('customer'::character varying)::text, ('free_agent'::character varying)::text, ('lost'::character varying)::text]))),
    CONSTRAINT accounts_pull_status_check CHECK ((pull_status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text]))),
    CONSTRAINT prospects_source_check CHECK (((source)::text = ANY (ARRAY['sales_visit'::text, 'cold_call'::text, 'referral'::text, 'existing_network'::text, 'exhibition'::text, 'instagram'::text, 'linkedin'::text, 'tiktok'::text, 'website'::text, 'walk_in'::text, 'other'::text])))
);


ALTER TABLE public.accounts OWNER TO postgres;

--
-- Name: COLUMN accounts.account_status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.accounts.account_status IS 'DIPENSIUNKAN sejak 7 Sep 2026 — digantikan lifecycle_stage. Selama transisi keduanya disinkronkan otomatis: tulis ke salah satu, yang lain ikut. Di-drop di migrasi 20260907000002 setelah branch CRM v3 merge & stabil di produksi.';


--
-- Name: COLUMN accounts.lifecycle_stage; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.accounts.lifecycle_stage IS 'Sumbu LIFECYCLE akun. Tujuh nilai: lead, mql, sql, prospect, customer, free_agent, lost. Gerbang yang hidup: prospect lewat inquiry masuk, customer lewat WON. free_agent dan lost adalah exit manual. URUTAN TAHAP TIDAK DIKLAIM DI SINI — dua sumber bertentangan, lihat Keputusan Terbuka #37. Urutan nilai di CHECK/array BUKAN bukti urutan tahap. Berdampingan dengan account_status selama transisi jalur B; disinkronkan trg_a_sync_lifecycle_columns. TANPA default selama transisi. account_status di-drop di 20260907000002.';


--
-- Name: activities; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.activities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    account_id uuid,
    inquiry_id uuid,
    quotation_id uuid,
    assigned_to uuid,
    type text NOT NULL,
    status text DEFAULT 'todo'::text NOT NULL,
    scheduled_for date,
    activity_time time without time zone,
    completed_at timestamp with time zone,
    prospect_name text,
    contact_name text,
    contact_phone text,
    outcome text,
    notes text,
    next_action text,
    next_action_date date,
    details jsonb DEFAULT '{}'::jsonb,
    migrated_from text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    contact_id uuid
);


ALTER TABLE public.activities OWNER TO postgres;

--
-- Name: activity_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.activity_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    activity_id uuid NOT NULL,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now(),
    from_status text,
    to_status text,
    notes text
);


ALTER TABLE public.activity_logs OWNER TO postgres;

--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.app_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    category text NOT NULL,
    key text NOT NULL,
    value jsonb,
    updated_at timestamp with time zone DEFAULT now(),
    updated_by uuid
);


ALTER TABLE public.app_settings OWNER TO postgres;

--
-- Name: approval_delegations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.approval_delegations (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    delegator_id uuid NOT NULL,
    delegate_id uuid NOT NULL,
    document_types jsonb DEFAULT '[]'::jsonb NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone NOT NULL,
    reason text,
    approved_by uuid,
    approved_at timestamp with time zone,
    is_active boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_delegations_dates_valid CHECK ((valid_until > valid_from)),
    CONSTRAINT approval_delegations_no_self_delegate CHECK ((delegator_id <> delegate_id))
);


ALTER TABLE public.approval_delegations OWNER TO postgres;

--
-- Name: TABLE approval_delegations; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.approval_delegations IS 'Temporary approval authority delegation. Must be approved by Admin before taking effect.';


--
-- Name: COLUMN approval_delegations.delegator_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_delegations.delegator_id IS 'The user who is delegating their approval authority (e.g. a manager going on leave).';


--
-- Name: COLUMN approval_delegations.delegate_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_delegations.delegate_id IS 'The user receiving temporary approval authority.';


--
-- Name: COLUMN approval_delegations.document_types; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_delegations.document_types IS 'JSON array of document type codes this delegation covers. Empty array [] = all types.';


--
-- Name: COLUMN approval_delegations.is_active; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_delegations.is_active IS 'False = pending Admin approval. True = delegation is in effect. Auto-expires at valid_until.';


--
-- Name: approval_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.approval_logs (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    document_type character varying(20) NOT NULL,
    document_id uuid NOT NULL,
    document_no character varying(100),
    action character varying(30) NOT NULL,
    from_status character varying(50) NOT NULL,
    to_status character varying(50) NOT NULL,
    actor_id uuid NOT NULL,
    sequence_level smallint DEFAULT 1 NOT NULL,
    notes text,
    acted_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_logs_action_check CHECK (((action)::text = ANY ((ARRAY['submit'::character varying, 'approve'::character varying, 'reject'::character varying, 'revision_requested'::character varying, 'revise'::character varying, 'cancel'::character varying, 'delegate'::character varying, 'on_hold'::character varying, 'resume'::character varying])::text[])))
);


ALTER TABLE public.approval_logs OWNER TO postgres;

--
-- Name: TABLE approval_logs; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.approval_logs IS 'Immutable approval action audit trail. Append-only — never UPDATE or DELETE rows. One row per approval action.';


--
-- Name: COLUMN approval_logs.document_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_logs.document_id IS 'UUID of the document row in its own table (quotations.id, sales_orders.id, etc.). Not a hard FK — keeps the engine module-agnostic.';


--
-- Name: COLUMN approval_logs.document_no; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_logs.document_no IS 'Human-readable document number (e.g. QT/MSI/SLS/2026/0001). Stored for fast display without a join.';


--
-- Name: COLUMN approval_logs.action; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_logs.action IS 'What happened: submit, approve, reject, revision_requested, revise, cancel, delegate, on_hold, resume.';


--
-- Name: COLUMN approval_logs.sequence_level; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_logs.sequence_level IS 'Which approval level was actioned (1 = first approver, 2 = second, etc.).';


--
-- Name: approval_rules; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.approval_rules (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    document_type character varying(20) NOT NULL,
    department_id uuid,
    min_amount numeric(18,2) DEFAULT 0,
    max_amount numeric(18,2),
    approver_role_id uuid,
    approver_user_id uuid,
    backup_approver_id uuid,
    sequence_order smallint DEFAULT 1 NOT NULL,
    deadline_hours smallint,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_rules_approver_required CHECK (((approver_role_id IS NOT NULL) OR (approver_user_id IS NOT NULL)))
);


ALTER TABLE public.approval_rules OWNER TO postgres;

--
-- Name: TABLE approval_rules; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.approval_rules IS 'Reusable approval engine rules. Company-scoped, module-agnostic. Multi-level supported via sequence_order. See docs/workflow/approval-engine.md.';


--
-- Name: COLUMN approval_rules.document_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_rules.document_type IS 'Document type code (e.g. QT, SP, PO). Stored as varchar — NOT a FK to document_types to keep the engine decoupled.';


--
-- Name: COLUMN approval_rules.department_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_rules.department_id IS 'If set, rule applies only to documents from this department. NULL = applies to all departments.';


--
-- Name: COLUMN approval_rules.min_amount; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_rules.min_amount IS 'Minimum document amount this rule applies to. 0 or NULL = no lower bound.';


--
-- Name: COLUMN approval_rules.max_amount; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_rules.max_amount IS 'Maximum document amount this rule applies to. NULL = no upper limit.';


--
-- Name: COLUMN approval_rules.sequence_order; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_rules.sequence_order IS 'Approval level sequence. Level 1 must complete before Level 2 is triggered.';


--
-- Name: COLUMN approval_rules.deadline_hours; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.approval_rules.deadline_hours IS 'Hours within which the approver must act. NULL = no deadline. Enables escalation on overdue.';


--
-- Name: approval_workflow_steps; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.approval_workflow_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workflow_id uuid NOT NULL,
    step_order integer NOT NULL,
    approver_type character varying DEFAULT 'role'::character varying NOT NULL,
    approver_role character varying,
    approver_user_id uuid,
    is_required boolean DEFAULT true NOT NULL,
    timeout_hours integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_workflow_steps_approver_type_check CHECK (((approver_type)::text = ANY ((ARRAY['role'::character varying, 'user'::character varying, 'position'::character varying])::text[])))
);


ALTER TABLE public.approval_workflow_steps OWNER TO postgres;

--
-- Name: approval_workflows; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.approval_workflows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    document_type character varying NOT NULL,
    name character varying NOT NULL,
    amount_threshold_min numeric(15,2),
    amount_threshold_max numeric(15,2),
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.approval_workflows OWNER TO postgres;

--
-- Name: ar_btbs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ar_btbs (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    ttf_id uuid NOT NULL,
    no_btb text DEFAULT ''::text NOT NULL,
    dpp_ppn numeric(18,2) DEFAULT 0 NOT NULL,
    pph numeric(18,2) DEFAULT 0 NOT NULL,
    payment numeric(18,2) DEFAULT 0 NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.ar_btbs OWNER TO postgres;

--
-- Name: TABLE ar_btbs; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.ar_btbs IS 'AR Tracker BTB line items. Child of ar_ttfs (ON DELETE CASCADE). Update strategy: DELETE all rows for the TTF, then re-INSERT — never UPDATE individual BTB rows. Therefore no updated_at trigger needed.';


--
-- Name: COLUMN ar_btbs.dpp_ppn; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ar_btbs.dpp_ppn IS 'DPP (Dasar Pengenaan Pajak) + PPN combined amount.';


--
-- Name: COLUMN ar_btbs.pph; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ar_btbs.pph IS 'PPh (Pajak Penghasilan) withholding tax.';


--
-- Name: COLUMN ar_btbs."position"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ar_btbs."position" IS 'Sort order index. TTF detail display sorts by position ASC.';


--
-- Name: ar_ttfs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ar_ttfs (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    no_ttf text DEFAULT ''::text NOT NULL,
    tanggal_ttf date,
    tanggal_menerima date,
    no_inv text DEFAULT ''::text NOT NULL,
    no_sp text DEFAULT ''::text NOT NULL,
    customer_id uuid,
    tgl_pembayaran date,
    notes text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    sp_order_id uuid,
    invoice_id uuid,
    diterima_oleh text,
    company_id uuid
);


ALTER TABLE public.ar_ttfs OWNER TO postgres;

--
-- Name: TABLE ar_ttfs; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.ar_ttfs IS 'AR Tracker TTF (Tanda Terima Faktur) headers. Parent of ar_btbs (cascade delete). tgl_pembayaran = NULL means unpaid; used for payment status calculation in calcAR().';


--
-- Name: COLUMN ar_ttfs.tgl_pembayaran; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ar_ttfs.tgl_pembayaran IS 'Payment receipt date. NULL = not yet paid. calcAR() in App.jsx uses this to determine status: Lunas / Partial / Belum Bayar.';


--
-- Name: COLUMN ar_ttfs.diterima_oleh; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ar_ttfs.diterima_oleh IS 'Nama orang di pihak customer yang menerima faktur. Teks bebas — orang di luar sistem Nexus, sengaja BUKAN FK ke profiles.';


--
-- Name: COLUMN ar_ttfs.company_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ar_ttfs.company_id IS 'Entitas pemilik TTF. Diisi otomatis trigger trg_ar_ttfs_set_company dari invoice -> sp_order -> customer. SENGAJA nullable: baris warisan yang ketiga jalurnya kosong tak boleh menggagalkan migrasi — lihat query yatim di STEP 3.';


--
-- Name: asset_categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_categories (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    useful_life_years smallint,
    depreciation_method character varying(20) DEFAULT 'straight_line'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT asset_categories_depreciation_method_check CHECK (((depreciation_method)::text = ANY ((ARRAY['straight_line'::character varying, 'double_declining'::character varying, 'none'::character varying])::text[]))),
    CONSTRAINT asset_categories_useful_life_years_check CHECK ((useful_life_years > 0))
);


ALTER TABLE public.asset_categories OWNER TO postgres;

--
-- Name: TABLE asset_categories; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.asset_categories IS 'P3 — Phase 4.2 only. Asset classification with depreciation parameters. Schema defined in Phase 1.0B for completeness.';


--
-- Name: COLUMN asset_categories.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.asset_categories.code IS 'Category code, unique per company. e.g. IT-EQP, FURN, VEH, BLDG.';


--
-- Name: COLUMN asset_categories.useful_life_years; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.asset_categories.useful_life_years IS 'Expected useful life in years. Drives depreciation schedule calculation.';


--
-- Name: COLUMN asset_categories.depreciation_method; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.asset_categories.depreciation_method IS 'straight_line: equal annual depreciation. double_declining: accelerated. none: non-depreciable assets (land).';


--
-- Name: asset_fuel_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_fuel_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    fill_date date NOT NULL,
    spbu character varying(150),
    liters numeric(8,2) NOT NULL,
    price_per_liter numeric(10,2) NOT NULL,
    total_cost numeric(12,2) GENERATED ALWAYS AS ((liters * price_per_liter)) STORED,
    odometer integer,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT asset_fuel_logs_liters_check CHECK ((liters > (0)::numeric)),
    CONSTRAINT asset_fuel_logs_price_per_liter_check CHECK ((price_per_liter > (0)::numeric))
);


ALTER TABLE public.asset_fuel_logs OWNER TO postgres;

--
-- Name: asset_locations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_locations (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.asset_locations OWNER TO postgres;

--
-- Name: TABLE asset_locations; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.asset_locations IS 'P3 — Phase 4.2 only. Physical asset placement registry per branch. Schema defined in Phase 1.0B for completeness.';


--
-- Name: COLUMN asset_locations.branch_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.asset_locations.branch_id IS 'Branch where this location exists. Required — assets are always at a branch.';


--
-- Name: COLUMN asset_locations.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.asset_locations.code IS 'Location code, unique per company. e.g. HO-IT-ROOM, HO-FIN-DESK.';


--
-- Name: asset_maintenance_records; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_maintenance_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    asset_id uuid NOT NULL,
    company_id uuid NOT NULL,
    maintenance_date date NOT NULL,
    maintenance_type character varying(20) DEFAULT 'preventif'::character varying NOT NULL,
    description text,
    technician_name character varying(150),
    duration_minutes integer,
    cost numeric(14,2),
    status character varying(20) DEFAULT 'selesai'::character varying NOT NULL,
    next_scheduled_date date,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT asset_maintenance_records_maintenance_type_check CHECK (((maintenance_type)::text = ANY ((ARRAY['preventif'::character varying, 'korektif'::character varying, 'upgrade'::character varying, 'inspeksi'::character varying])::text[]))),
    CONSTRAINT asset_maintenance_records_status_check CHECK (((status)::text = ANY ((ARRAY['selesai'::character varying, 'dalam_proses'::character varying, 'dijadwalkan'::character varying, 'dibatalkan'::character varying])::text[])))
);


ALTER TABLE public.asset_maintenance_records OWNER TO postgres;

--
-- Name: asset_network; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_network (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    asset_id uuid NOT NULL,
    company_id uuid NOT NULL,
    ip_address character varying(50),
    ipv6_address character varying(100),
    mac_wifi character varying(20),
    mac_lan character varying(20),
    hostname character varying(100),
    gateway character varying(50),
    dns_primary character varying(50),
    dns_secondary character varying(50),
    vlan character varying(50),
    domain_workgroup character varying(100),
    last_seen_at timestamp with time zone,
    is_online boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.asset_network OWNER TO postgres;

--
-- Name: asset_software_licenses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_software_licenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    asset_id uuid NOT NULL,
    company_id uuid NOT NULL,
    software_name character varying(150) NOT NULL,
    version character varying(50),
    category character varying(50),
    license_type character varying(30) DEFAULT 'OEM'::character varying NOT NULL,
    license_key_masked character varying(100),
    expiry_date date,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT asset_software_licenses_license_type_check CHECK (((license_type)::text = ANY ((ARRAY['OEM'::character varying, 'Volume'::character varying, 'Subscription'::character varying, 'Open Source'::character varying, 'Freeware'::character varying, 'Trial'::character varying])::text[]))),
    CONSTRAINT asset_software_licenses_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'expired'::character varying, 'soon'::character varying, 'cancelled'::character varying])::text[])))
);


ALTER TABLE public.asset_software_licenses OWNER TO postgres;

--
-- Name: asset_specifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.asset_specifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    asset_id uuid NOT NULL,
    company_id uuid NOT NULL,
    cpu_model character varying(150),
    cpu_cores smallint,
    cpu_threads smallint,
    cpu_base_ghz numeric(4,2),
    cpu_turbo_ghz numeric(4,2),
    cpu_cache_mb smallint,
    ram_gb smallint,
    ram_type character varying(20),
    ram_slots_used smallint,
    ram_slots_total smallint,
    storage_gb integer,
    storage_type character varying(20),
    storage_interface character varying(50),
    storage_used_pct smallint,
    display_size_inch numeric(4,1),
    display_resolution character varying(20),
    display_refresh_hz smallint,
    gpu_model character varying(100),
    os_name character varying(100),
    os_version character varying(50),
    os_build character varying(50),
    os_arch character varying(10),
    os_license_type character varying(30),
    battery_capacity_wh numeric(5,1),
    battery_health_pct smallint,
    battery_cycle_count integer,
    webcam_desc character varying(100),
    keyboard_desc character varying(100),
    ports_desc text,
    wireless_desc character varying(100),
    weight_kg numeric(4,2),
    color character varying(50),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT asset_specifications_storage_type_check CHECK (((storage_type)::text = ANY ((ARRAY['SSD'::character varying, 'HDD'::character varying, 'NVMe'::character varying, 'eMMC'::character varying, 'other'::character varying])::text[])))
);


ALTER TABLE public.asset_specifications OWNER TO postgres;

--
-- Name: assets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.assets (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    asset_no character varying(50) NOT NULL,
    name character varying(150) NOT NULL,
    description text,
    category_id uuid NOT NULL,
    location_id uuid,
    purchase_date date,
    purchase_price numeric(18,2) DEFAULT 0,
    useful_life_years smallint,
    depreciation_method character varying(20),
    accumulated_depreciation numeric(18,2) DEFAULT 0 NOT NULL,
    book_value numeric(18,2) DEFAULT 0,
    status character varying(30) DEFAULT 'active'::character varying NOT NULL,
    assigned_to_user_id uuid,
    disposal_date date,
    disposal_notes text,
    coa_asset_account_id uuid,
    coa_depreciation_account_id uuid,
    coa_expense_account_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    asset_code character varying(30),
    serial_number character varying(100),
    model character varying(150),
    asset_subtype character varying(20),
    assigned_to_name character varying(150),
    vendor_name character varying(150),
    purchase_invoice_no character varying(100),
    plate_number character varying(20),
    color character varying(50),
    manufacture_year smallint,
    fuel_type character varying(20),
    vin character varying(30),
    engine_number character varying(30),
    km_odometer integer DEFAULT 0,
    condition character varying,
    department_id uuid,
    brand character varying,
    assignment_status character varying DEFAULT 'available'::character varying,
    CONSTRAINT assets_asset_subtype_check CHECK (((asset_subtype)::text = ANY ((ARRAY['laptop'::character varying, 'desktop'::character varying, 'server'::character varying, 'printer'::character varying, 'network'::character varying, 'peripheral'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT assets_depreciation_method_check CHECK (((depreciation_method)::text = ANY ((ARRAY['straight_line'::character varying, 'double_declining'::character varying, 'none'::character varying])::text[]))),
    CONSTRAINT assets_fuel_type_check CHECK (((fuel_type)::text = ANY ((ARRAY['solar'::character varying, 'bensin'::character varying, 'pertamax'::character varying, 'pertalite'::character varying, 'listrik'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT assets_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'disposed'::character varying, 'in_repair'::character varying, 'retired'::character varying, 'transferred'::character varying])::text[])))
);


ALTER TABLE public.assets OWNER TO postgres;

--
-- Name: TABLE assets; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.assets IS 'P3 — Phase 4.2 only. Fixed asset register. Disposal requires approval workflow — never hard delete. Schema defined in Phase 1.0B for completeness.';


--
-- Name: COLUMN assets.asset_no; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.asset_no IS 'Document number in standard format: AST/{ENTITY}/{DEPT}/{YYYY}/{SEQ}. Generated via document_sequences.';


--
-- Name: COLUMN assets.useful_life_years; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.useful_life_years IS 'Overrides the category default if set. Otherwise inherits from asset_categories.useful_life_years.';


--
-- Name: COLUMN assets.book_value; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.book_value IS 'Current book value = purchase_price - accumulated_depreciation. Updated each depreciation run.';


--
-- Name: COLUMN assets.status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.status IS 'Asset lifecycle status: active, disposed, in_repair, retired, transferred.';


--
-- Name: COLUMN assets.coa_asset_account_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.coa_asset_account_id IS 'Nullable FK to chart_of_accounts. Asset acquisition posting account. Set when COA is configured in Phase 3.';


--
-- Name: COLUMN assets.coa_depreciation_account_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.coa_depreciation_account_id IS 'Nullable FK to chart_of_accounts. Accumulated depreciation contra-asset account.';


--
-- Name: COLUMN assets.coa_expense_account_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.assets.coa_expense_account_id IS 'Nullable FK to chart_of_accounts. Depreciation expense posting account.';


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid,
    user_email text,
    user_role text,
    company_id uuid,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    entity_label text,
    old_data jsonb,
    new_data jsonb,
    ip_address text,
    user_agent text,
    notes text
);


ALTER TABLE public.audit_logs OWNER TO postgres;

--
-- Name: backfill_sp_order_items_20260808; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backfill_sp_order_items_20260808 (
    sp_order_item_id uuid,
    sp_order_id uuid,
    sp_item_id uuid,
    sp_no text,
    customer_id uuid,
    qty_lama integer,
    shipped_qty_lama integer,
    sla_days_lama integer,
    estimated_delivery_date_lama date,
    shipping_price_lama numeric(18,2),
    notes_lama text
);


ALTER TABLE public.backfill_sp_order_items_20260808 OWNER TO postgres;

--
-- Name: backup_b4_inquiries_20260725; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_b4_inquiries_20260725 (
    id uuid,
    company_id uuid,
    inquiry_no text,
    prospect_id uuid,
    customer_id uuid,
    service_type character varying,
    route text,
    commodity text,
    estimated_volume text,
    notes text,
    status character varying,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deadline_quote date,
    pol text,
    pod text,
    incoterms text[],
    container_types text[],
    goods_name text,
    hs_code text,
    weight_kg numeric(12,2),
    volume_cbm numeric(12,2),
    cargo_types text[],
    un_number text,
    imo_class text,
    has_msds text,
    additional_services text[],
    dimension text,
    pickup_address text,
    delivery_address text,
    won_reason text,
    lost_reason text,
    estimated_value numeric
);


ALTER TABLE public.backup_b4_inquiries_20260725 OWNER TO postgres;

--
-- Name: backup_dedup_accounts_20260725; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_dedup_accounts_20260725 (
    id uuid,
    company_id uuid,
    name text,
    legal_name character varying,
    customer_type character varying,
    tax_id character varying,
    address text,
    city character varying,
    country character varying,
    phone character varying,
    email character varying,
    pic_name character varying,
    pic_phone character varying,
    pic_email character varying,
    source character varying,
    assigned_to uuid,
    pipeline_stage character varying,
    lost_reason text,
    converted_at timestamp with time zone,
    converted_to uuid,
    payment_terms_id uuid,
    currency_code character varying,
    credit_limit numeric,
    notes text,
    is_active boolean,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    estimated_closing_date date,
    assigned_profile uuid,
    company_prefix text,
    won_reason text,
    bant_commodity text,
    bant_origin text,
    bant_destination text,
    bant_frequency text,
    bant_current_vendor text,
    bant_payment text,
    bant_decision_maker text,
    bant_score integer,
    account_status character varying(50),
    owner_company_id uuid,
    tier character varying(20),
    code text,
    nomor_kontrak text,
    default_dc text,
    last_activity_at timestamp with time zone,
    became_customer_at timestamp with time zone,
    estimated_value numeric,
    bant_budget smallint,
    bant_authority smallint,
    bant_need smallint,
    bant_timeline smallint,
    stage_changed_at timestamp with time zone,
    is_in_lead_pool boolean,
    lead_pool_reason text,
    lead_pool_at timestamp with time zone,
    pull_justification text,
    pull_requested_at timestamp with time zone,
    pull_approved_by uuid,
    pull_approved_at timestamp with time zone,
    pull_status text,
    is_odoo_customer boolean
);


ALTER TABLE public.backup_dedup_accounts_20260725 OWNER TO postgres;

--
-- Name: backup_dedup_activities_20260725; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_dedup_activities_20260725 (
    id uuid,
    company_id uuid,
    account_id uuid,
    inquiry_id uuid,
    quotation_id uuid,
    assigned_to uuid,
    type text,
    status text,
    scheduled_for date,
    activity_time time without time zone,
    completed_at timestamp with time zone,
    prospect_name text,
    contact_name text,
    contact_phone text,
    outcome text,
    notes text,
    next_action text,
    next_action_date date,
    details jsonb,
    migrated_from text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


ALTER TABLE public.backup_dedup_activities_20260725 OWNER TO postgres;

--
-- Name: backup_dedup_alliance_20260725; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_dedup_alliance_20260725 (
    id uuid,
    company_id uuid,
    name text,
    legal_name character varying,
    customer_type character varying,
    tax_id character varying,
    address text,
    city character varying,
    country character varying,
    phone character varying,
    email character varying,
    pic_name character varying,
    pic_phone character varying,
    pic_email character varying,
    source character varying,
    assigned_to uuid,
    pipeline_stage character varying,
    lost_reason text,
    converted_at timestamp with time zone,
    converted_to uuid,
    payment_terms_id uuid,
    currency_code character varying,
    credit_limit numeric,
    notes text,
    is_active boolean,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    estimated_closing_date date,
    assigned_profile uuid,
    company_prefix text,
    won_reason text,
    bant_commodity text,
    bant_origin text,
    bant_destination text,
    bant_frequency text,
    bant_current_vendor text,
    bant_payment text,
    bant_decision_maker text,
    bant_score integer,
    account_status character varying(50),
    owner_company_id uuid,
    tier character varying(20),
    code text,
    nomor_kontrak text,
    default_dc text,
    last_activity_at timestamp with time zone,
    became_customer_at timestamp with time zone,
    estimated_value numeric,
    bant_budget smallint,
    bant_authority smallint,
    bant_need smallint,
    bant_timeline smallint,
    stage_changed_at timestamp with time zone,
    is_in_lead_pool boolean,
    lead_pool_reason text,
    lead_pool_at timestamp with time zone,
    pull_justification text,
    pull_requested_at timestamp with time zone,
    pull_approved_by uuid,
    pull_approved_at timestamp with time zone,
    pull_status text,
    is_odoo_customer boolean
);


ALTER TABLE public.backup_dedup_alliance_20260725 OWNER TO postgres;

--
-- Name: backup_dedup_inquiries_20260725; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_dedup_inquiries_20260725 (
    id uuid,
    company_id uuid,
    inquiry_no text,
    prospect_id uuid,
    customer_id uuid,
    service_type character varying,
    route text,
    commodity text,
    estimated_volume text,
    notes text,
    status character varying,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deadline_quote date,
    pol text,
    pod text,
    incoterms text[],
    container_types text[],
    goods_name text,
    hs_code text,
    weight_kg numeric(12,2),
    volume_cbm numeric(12,2),
    cargo_types text[],
    un_number text,
    imo_class text,
    has_msds text,
    additional_services text[],
    dimension text,
    pickup_address text,
    delivery_address text,
    won_reason text,
    lost_reason text,
    estimated_value numeric
);


ALTER TABLE public.backup_dedup_inquiries_20260725 OWNER TO postgres;

--
-- Name: backup_dedup_quotations_20260725; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_dedup_quotations_20260725 (
    id uuid,
    company_id uuid,
    quotation_no text,
    revision integer,
    inquiry_id uuid,
    prospect_id uuid,
    customer_id uuid,
    service_type character varying,
    valid_until date,
    payment_terms_id uuid,
    currency_code character varying,
    notes text,
    terms text,
    subtotal numeric(15,2),
    tax_amount numeric(15,2),
    total_amount numeric(15,2),
    status character varying,
    sent_at timestamp with time zone,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    usd_rate numeric(15,2),
    route text,
    pricing_done_at timestamp with time zone,
    quote_sent_at timestamp with time zone,
    discount_pct numeric,
    margin_floor numeric,
    internal_notes text,
    quote_date date,
    vat_rate numeric,
    attention_to text,
    pickup_address text,
    delivery_address text,
    cargo_mode text,
    gw text,
    dimension text,
    cw text,
    cbm text,
    container_type text,
    container_qty integer,
    exchange_rates jsonb,
    prf_id uuid
);


ALTER TABLE public.backup_dedup_quotations_20260725 OWNER TO postgres;

--
-- Name: backup_leadpool_c1_won_20260724; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_leadpool_c1_won_20260724 (
    id uuid,
    company_id uuid,
    name text,
    legal_name character varying,
    customer_type character varying,
    tax_id character varying,
    address text,
    city character varying,
    country character varying,
    phone character varying,
    email character varying,
    pic_name character varying,
    pic_phone character varying,
    pic_email character varying,
    source character varying,
    assigned_to uuid,
    pipeline_stage character varying,
    lost_reason text,
    converted_at timestamp with time zone,
    converted_to uuid,
    payment_terms_id uuid,
    currency_code character varying,
    credit_limit numeric,
    notes text,
    is_active boolean,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    estimated_closing_date date,
    assigned_profile uuid,
    company_prefix text,
    won_reason text,
    bant_commodity text,
    bant_origin text,
    bant_destination text,
    bant_frequency text,
    bant_current_vendor text,
    bant_payment text,
    bant_decision_maker text,
    bant_score integer,
    account_status character varying(50),
    owner_company_id uuid,
    tier character varying(20),
    code text,
    nomor_kontrak text,
    default_dc text,
    last_activity_at timestamp with time zone,
    became_customer_at timestamp with time zone,
    estimated_value numeric,
    bant_budget smallint,
    bant_authority smallint,
    bant_need smallint,
    bant_timeline smallint,
    stage_changed_at timestamp with time zone,
    is_in_lead_pool boolean,
    lead_pool_reason text,
    lead_pool_at timestamp with time zone,
    pull_justification text,
    pull_requested_at timestamp with time zone,
    pull_approved_by uuid,
    pull_approved_at timestamp with time zone,
    pull_status text,
    is_odoo_customer boolean
);


ALTER TABLE public.backup_leadpool_c1_won_20260724 OWNER TO postgres;

--
-- Name: backup_leadpool_trap_20260724; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_leadpool_trap_20260724 (
    id uuid,
    company_id uuid,
    name text,
    legal_name character varying,
    customer_type character varying,
    tax_id character varying,
    address text,
    city character varying,
    country character varying,
    phone character varying,
    email character varying,
    pic_name character varying,
    pic_phone character varying,
    pic_email character varying,
    source character varying,
    assigned_to uuid,
    pipeline_stage character varying,
    lost_reason text,
    converted_at timestamp with time zone,
    converted_to uuid,
    payment_terms_id uuid,
    currency_code character varying,
    credit_limit numeric,
    notes text,
    is_active boolean,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    estimated_closing_date date,
    assigned_profile uuid,
    company_prefix text,
    won_reason text,
    bant_commodity text,
    bant_origin text,
    bant_destination text,
    bant_frequency text,
    bant_current_vendor text,
    bant_payment text,
    bant_decision_maker text,
    bant_score integer,
    account_status character varying(50),
    owner_company_id uuid,
    tier character varying(20),
    code text,
    nomor_kontrak text,
    default_dc text,
    last_activity_at timestamp with time zone,
    became_customer_at timestamp with time zone,
    estimated_value numeric,
    bant_budget smallint,
    bant_authority smallint,
    bant_need smallint,
    bant_timeline smallint,
    stage_changed_at timestamp with time zone,
    is_in_lead_pool boolean,
    lead_pool_reason text,
    lead_pool_at timestamp with time zone,
    pull_justification text,
    pull_requested_at timestamp with time zone,
    pull_approved_by uuid,
    pull_approved_at timestamp with time zone,
    pull_status text,
    is_odoo_customer boolean
);


ALTER TABLE public.backup_leadpool_trap_20260724 OWNER TO postgres;

--
-- Name: backup_prf_20260727; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_prf_20260727 (
    id uuid,
    company_id uuid,
    prf_no text,
    status character varying,
    created_by uuid,
    updated_by uuid,
    submitted_at timestamp with time zone,
    acknowledged_by uuid,
    acknowledged_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    customer_source text,
    account_id uuid,
    account_name_manual text,
    stream text,
    deadline_quotation date,
    direction text,
    commodity text,
    hs_code text,
    msds_available boolean,
    service_type text,
    incoterms text,
    commercial_value numeric(14,2),
    commercial_currency text,
    origin text,
    destination text,
    pickup_address text,
    delivery_address text,
    add_on_services text[],
    add_on_others text,
    cargo_ready_date date,
    sea_freight_type text,
    sea_container_types text[],
    sea_container_qty jsonb,
    sea_lcl_gw numeric(12,2),
    sea_lcl_dimension text,
    sea_lcl_volume numeric(12,2),
    sea_lcl_koli integer,
    air_gw numeric(12,2),
    air_dimension text,
    air_volume numeric(12,2),
    air_koli integer,
    inland_fleet_types text[],
    inland_pickup_address text,
    inland_delivery_address text,
    inland_gw numeric(12,2),
    inland_dimension text,
    custom_doc_type text,
    project_freight_types text[],
    project_qty integer,
    notes text,
    inquiry_id uuid,
    suggested_rate numeric(18,2),
    rate_currency text,
    valid_from date,
    valid_until date,
    pricing_notes text,
    answered_by uuid,
    answered_at timestamp with time zone,
    exchange_rates jsonb,
    goods_name text,
    un_number text,
    imo_class text,
    selected_offer_id uuid,
    selected_by uuid,
    selected_at timestamp with time zone,
    min_offers_waiver_reason text
);


ALTER TABLE public.backup_prf_20260727 OWNER TO postgres;

--
-- Name: backup_prf_cost_items_20260727; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.backup_prf_cost_items_20260727 (
    id uuid,
    prf_id uuid,
    component text,
    cost_type text,
    amount numeric(18,2),
    currency text,
    sort_order integer,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    vendor_id uuid,
    item_group text,
    is_awarded boolean,
    exchange_rate numeric,
    offer_id uuid
);


ALTER TABLE public.backup_prf_cost_items_20260727 OWNER TO postgres;

--
-- Name: bnf_authorized_users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_authorized_users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    company_id uuid NOT NULL,
    reason text,
    granted_by uuid,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone
);


ALTER TABLE public.bnf_authorized_users OWNER TO postgres;

--
-- Name: bnf_department_scopes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_department_scopes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    department_id uuid NOT NULL,
    company_id uuid NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bnf_department_scopes OWNER TO postgres;

--
-- Name: bnf_departments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_departments (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    division_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    head_profile_id uuid
);


ALTER TABLE public.bnf_departments OWNER TO postgres;

--
-- Name: bnf_division_scopes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_division_scopes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    division_id uuid NOT NULL,
    company_id uuid NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bnf_division_scopes OWNER TO postgres;

--
-- Name: bnf_divisions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_divisions (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    director_profile_id uuid
);


ALTER TABLE public.bnf_divisions OWNER TO postgres;

--
-- Name: bnf_report_action_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_report_action_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    report_id uuid NOT NULL,
    description text NOT NULL,
    assigned_to uuid NOT NULL,
    is_done boolean DEFAULT false NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    completed_by uuid
);


ALTER TABLE public.bnf_report_action_items OWNER TO postgres;

--
-- Name: bnf_report_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_report_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    report_id uuid NOT NULL,
    from_status character varying(20),
    to_status character varying(20) NOT NULL,
    note text,
    changed_by uuid NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bnf_report_logs OWNER TO postgres;

--
-- Name: bnf_report_related_departments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_report_related_departments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    report_id uuid NOT NULL,
    department_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bnf_report_related_departments OWNER TO postgres;

--
-- Name: bnf_reports; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bnf_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    report_no character varying(30) NOT NULL,
    division_id uuid NOT NULL,
    department_id uuid NOT NULL,
    description text NOT NULL,
    root_cause text,
    solution text,
    target_date date NOT NULL,
    escalation_level character varying(20),
    status character varying(20) DEFAULT 'Open'::character varying NOT NULL,
    closed_at timestamp with time zone,
    created_by uuid NOT NULL,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT bnf_reports_escalation_level_check CHECK (((escalation_level IS NULL) OR ((escalation_level)::text = ANY ((ARRAY['manager_direct'::character varying, 'direktur_divisi'::character varying, 'ceo'::character varying])::text[])))),
    CONSTRAINT bnf_reports_status_check CHECK (((status)::text = ANY ((ARRAY['Open'::character varying, 'In Progress'::character varying, 'Escalated'::character varying, 'Closed'::character varying])::text[])))
);


ALTER TABLE public.bnf_reports OWNER TO postgres;

--
-- Name: COLUMN bnf_reports.status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bnf_reports.status IS 'Title Case by design (Open/In Progress/Escalated/Closed) — mirrors App.jsx StatusBadge value convention, unlike lowercase status on activities/hrga_requests.';


--
-- Name: branches; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.branches (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    address text,
    city character varying(100),
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.branches OWNER TO postgres;

--
-- Name: TABLE branches; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.branches IS 'Physical or operational locations of a company.';


--
-- Name: COLUMN branches.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.branches.code IS 'Short location identifier, unique per company, e.g. HO, SBY, MDN.';


--
-- Name: COLUMN branches.deleted_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.branches.deleted_at IS 'Soft delete timestamp. NULL = active.';


--
-- Name: channel_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.channel_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    service_line character varying(30),
    margin_floor numeric(5,2),
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT channel_types_line_check CHECK (((service_line IS NULL) OR ((service_line)::text = ANY (ARRAY['freight_forwarding'::text, 'customs'::text, 'trading'::text])))),
    CONSTRAINT channel_types_margin_check CHECK (((margin_floor IS NULL) OR ((margin_floor >= (0)::numeric) AND (margin_floor <= (100)::numeric))))
);


ALTER TABLE public.channel_types OWNER TO postgres;

--
-- Name: TABLE channel_types; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.channel_types IS 'Channel penjualan per entitas (Direct/Forwarder/Hybrid). margin_floor dipakai gerbang margin Quotation (batch B4).';


--
-- Name: chart_of_accounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chart_of_accounts (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(150) NOT NULL,
    account_type character varying(20) NOT NULL,
    parent_id uuid,
    level smallint DEFAULT 1 NOT NULL,
    is_header boolean DEFAULT false NOT NULL,
    normal_balance character varying(6) DEFAULT 'debit'::character varying NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT chart_of_accounts_account_type_check CHECK (((account_type)::text = ANY ((ARRAY['asset'::character varying, 'liability'::character varying, 'equity'::character varying, 'revenue'::character varying, 'expense'::character varying])::text[]))),
    CONSTRAINT chart_of_accounts_level_check CHECK (((level >= 1) AND (level <= 4))),
    CONSTRAINT chart_of_accounts_normal_balance_check CHECK (((normal_balance)::text = ANY ((ARRAY['debit'::character varying, 'credit'::character varying])::text[])))
);


ALTER TABLE public.chart_of_accounts OWNER TO postgres;

--
-- Name: TABLE chart_of_accounts; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.chart_of_accounts IS 'Company-scoped general ledger account structure. Finance Controller must approve before any accounting transaction is recorded.';


--
-- Name: COLUMN chart_of_accounts.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.code IS 'Account code, unique per company. Follows Indonesian standard COA numbering convention.';


--
-- Name: COLUMN chart_of_accounts.account_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.account_type IS 'Fundamental account classification: asset, liability, equity, revenue, expense.';


--
-- Name: COLUMN chart_of_accounts.parent_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.parent_id IS 'Self-referential parent for hierarchy. NULL = top-level account type grouping.';


--
-- Name: COLUMN chart_of_accounts.level; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.level IS '1=Type, 2=Group, 3=Sub-Group, 4=Detail. Only level 4 (leaf) accounts accept direct postings.';


--
-- Name: COLUMN chart_of_accounts.is_header; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.is_header IS 'True = summary/header account. Direct journal postings to header accounts are not allowed.';


--
-- Name: COLUMN chart_of_accounts.normal_balance; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.normal_balance IS 'debit: increases with debit entries (assets, expenses). credit: increases with credit entries (liabilities, equity, revenue).';


--
-- Name: COLUMN chart_of_accounts.deleted_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.chart_of_accounts.deleted_at IS 'Soft delete only if no transactions reference this account. Finance Controller approval required before deleting any account.';


--
-- Name: code_counters; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.code_counters (
    entity text NOT NULL,
    year integer NOT NULL,
    last_number integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.code_counters OWNER TO postgres;

--
-- Name: companies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.companies (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    legal_name character varying(200),
    business_focus character varying(100),
    address text,
    city character varying(100),
    country character varying(100) DEFAULT 'Indonesia'::character varying,
    phone character varying(50),
    email character varying(100),
    tax_id character varying(50),
    logo_url text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    nib character varying,
    website character varying,
    address_2 character varying,
    province character varying,
    postal_code character varying,
    fiscal_year_start integer DEFAULT 1,
    default_currency character varying(3) DEFAULT 'IDR'::character varying,
    timezone character varying DEFAULT 'Asia/Jakarta'::character varying,
    aging_enabled boolean DEFAULT false NOT NULL
);


ALTER TABLE public.companies OWNER TO postgres;

--
-- Name: TABLE companies; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.companies IS 'Root anchor for all company-scoped data. One row per MSI Group legal entity.';


--
-- Name: COLUMN companies.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.companies.code IS 'Short identifier: MSI, JCI, SBI. Used as the {ENTITY} segment in document numbers.';


--
-- Name: COLUMN companies.business_focus; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.companies.business_focus IS 'Human-readable description: Freight Forwarding, PPJK, General Trading.';


--
-- Name: COLUMN companies.tax_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.companies.tax_id IS 'NPWP — Indonesian tax registration number.';


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    "position" text,
    email text,
    phone text,
    role_type text,
    is_primary boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    notes text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT contacts_role_type_check CHECK (((role_type IS NULL) OR (role_type = ANY (ARRAY['decision_maker'::text, 'requester'::text, 'finance'::text, 'operations'::text, 'other'::text]))))
);


ALTER TABLE public.contacts OWNER TO postgres;

--
-- Name: cost_centers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.cost_centers (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    branch_id uuid,
    department_id uuid,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.cost_centers OWNER TO postgres;

--
-- Name: TABLE cost_centers; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.cost_centers IS 'Company-scoped budget and cost tracking units. Used in job costing, expense allocation, and management reporting.';


--
-- Name: COLUMN cost_centers.branch_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.cost_centers.branch_id IS 'Optional branch association. NULL = cost center spans all branches.';


--
-- Name: COLUMN cost_centers.department_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.cost_centers.department_id IS 'Optional department association. NULL = cost center spans all departments.';


--
-- Name: COLUMN cost_centers.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.cost_centers.code IS 'Cost center code, unique per company. e.g. CC-LOG-HO, CC-SLS-SBY.';


--
-- Name: currencies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.currencies (
    code character varying(3) NOT NULL,
    name character varying(100) NOT NULL,
    symbol character varying(10),
    decimal_places smallint DEFAULT 2 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.currencies OWNER TO postgres;

--
-- Name: TABLE currencies; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.currencies IS 'Global ISO 4217 currency registry. Readable by all authenticated users; managed by Super Admin only.';


--
-- Name: COLUMN currencies.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.currencies.code IS 'ISO 4217 three-letter currency code: IDR, USD, SGD, EUR, JPY.';


--
-- Name: COLUMN currencies.decimal_places; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.currencies.decimal_places IS 'Number of decimal places for display. IDR = 0, USD/EUR/SGD = 2, JPY = 0.';


--
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    code text,
    default_dc text DEFAULT ''::text NOT NULL,
    pic_name text DEFAULT ''::text NOT NULL,
    pic_email text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    payment_terms integer DEFAULT 30 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid NOT NULL,
    legal_name character varying(200),
    customer_type character varying(50),
    tax_id character varying(50),
    address text,
    city character varying(100),
    country character varying(100) DEFAULT 'Indonesia'::character varying,
    phone character varying(50),
    email character varying(100),
    pic_phone character varying(50),
    credit_limit numeric(18,2) DEFAULT 0,
    payment_terms_id uuid,
    currency_code character varying(3) DEFAULT 'IDR'::character varying,
    notes text,
    deleted_at timestamp with time zone,
    created_by uuid,
    updated_by uuid,
    nomor_kontrak text,
    status character varying(50) DEFAULT 'active'::character varying,
    prospect_id uuid,
    assigned_to uuid,
    tier character varying(20),
    last_activity_at timestamp with time zone DEFAULT now(),
    source_company_id uuid
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- Name: TABLE customers; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.customers IS 'Legacy customer master table. Used by Customer page, SP Manifest, and AR Tracker. Extended by migration 008 with ERP fields (company_id, credit_limit, etc.). payment_terms (integer days) is the legacy field; payment_terms_id FK added in 008.';


--
-- Name: COLUMN customers.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.code IS 'Customer code, unique per company. Auto-generated or manually assigned. e.g. CST-0001.';


--
-- Name: COLUMN customers.payment_terms; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.payment_terms IS 'Legacy payment terms in days (integer). Not used by current customerFromDb() but preserved as a pre-existing column. Migration 008 adds payment_terms_id (FK). Phase 1.0F migrates this value to the FK and drops this integer column.';


--
-- Name: COLUMN customers.company_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.company_id IS 'ERP company scope. NULL until Phase 1.0F backfill. Will become NOT NULL after 1.0F.';


--
-- Name: COLUMN customers.customer_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.customer_type IS 'Customer classification: Individual, Company, Government, Freight Agent, etc.';


--
-- Name: COLUMN customers.tax_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.tax_id IS 'NPWP (Indonesian tax ID) or equivalent for non-Indonesian customers.';


--
-- Name: COLUMN customers.credit_limit; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.credit_limit IS 'Maximum outstanding AR allowed. Sensitive — mask in non-Finance role views.';


--
-- Name: COLUMN customers.payment_terms_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.payment_terms_id IS 'FK to payment_terms. New ERP field running alongside legacy payment_terms (integer). Phase 1.0F migrates and removes the integer.';


--
-- Name: COLUMN customers.currency_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.currency_code IS 'Default billing currency for this customer. Default IDR.';


--
-- Name: COLUMN customers.deleted_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.deleted_at IS 'Soft delete timestamp. NULL = active. If column already exists, ADD IF NOT EXISTS is safe.';


--
-- Name: COLUMN customers.updated_by; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.updated_by IS 'User who last updated this record.';


--
-- Name: daily_report_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.daily_report_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    department_id uuid NOT NULL,
    entry_date date DEFAULT CURRENT_DATE NOT NULL,
    created_by uuid NOT NULL,
    category character varying(20) NOT NULL,
    description text NOT NULL,
    task_status character varying(20),
    carried_from_id uuid,
    insiden_resolution character varying(20),
    pulled_to_bnf_report_id uuid,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT daily_report_items_category_check CHECK (((category)::text = ANY ((ARRAY['task'::character varying, 'aktivitas'::character varying, 'insiden'::character varying])::text[]))),
    CONSTRAINT daily_report_items_insiden_resolution_check CHECK (((insiden_resolution)::text = ANY ((ARRAY['pending_review'::character varying, 'resolved_internal'::character varying, 'pulled_to_bnf'::character varying])::text[]))),
    CONSTRAINT daily_report_items_task_status_check CHECK (((task_status)::text = ANY ((ARRAY['pending'::character varying, 'selesai'::character varying])::text[])))
);


ALTER TABLE public.daily_report_items OWNER TO postgres;

--
-- Name: dc_master; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dc_master (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    customer_id uuid,
    kode text,
    nama text NOT NULL,
    wilayah text,
    alamat text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT dc_master_wilayah_check CHECK ((wilayah = ANY (ARRAY['Jawa'::text, 'Sumatera'::text, 'Sulawesi'::text, 'Kalimantan'::text, 'Bali & Nusa Tenggara'::text, 'Lainnya'::text])))
);


ALTER TABLE public.dc_master OWNER TO postgres;

--
-- Name: deal_handovers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.deal_handovers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    account_id uuid,
    handover_type text NOT NULL,
    nama_perusahaan text,
    npwp text,
    nib text,
    ktp_direktur text,
    alamat text,
    website text,
    industri text,
    tahun_berdiri text,
    tipe_customer text,
    tier_assigned text,
    stream_service text,
    estimasi_volume text,
    payment_terms text,
    credit_limit numeric(18,2),
    validity_quote text,
    special_handling text,
    tcv_forecast numeric(18,2),
    volume_per_lane text,
    service_mix text,
    sla_komitmen text,
    quotation_ref text,
    msa_status text,
    pic_decision_maker text,
    pic_operasional text,
    pic_commercial text,
    pic_finance text,
    pic_escalation_1 text,
    pic_escalation_2 text,
    top_approved text,
    pefindo_score text,
    bank_reference text,
    invoicing_instructions text,
    tax_status text,
    doc_requirement text,
    communication_pref text,
    reporting_cadence text,
    kam_assigned uuid,
    status text DEFAULT 'draft'::text,
    submitted_at timestamp with time zone,
    approved_by_sales uuid,
    approved_by_ops uuid,
    approved_by_finance uuid,
    approved_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT deal_handovers_handover_type_check CHECK ((handover_type = ANY (ARRAY['light'::text, 'strategic'::text]))),
    CONSTRAINT deal_handovers_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'submitted'::text, 'approved'::text])))
);


ALTER TABLE public.deal_handovers OWNER TO postgres;

--
-- Name: delivery_incidents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_incidents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    delivery_note_id uuid NOT NULL,
    incident_type text NOT NULL,
    severity text DEFAULT 'minor'::text NOT NULL,
    description text NOT NULL,
    occurred_at timestamp with time zone,
    reported_at timestamp with time zone DEFAULT now() NOT NULL,
    reported_by uuid,
    status text DEFAULT 'open'::text NOT NULL,
    resolution text,
    resolved_at timestamp with time zone,
    resolved_by uuid,
    delay_minutes integer,
    vendor_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT delivery_incidents_resolve_check CHECK (((status <> 'resolved'::text) OR ((resolved_at IS NOT NULL) AND (resolution IS NOT NULL)))),
    CONSTRAINT delivery_incidents_severity_check CHECK ((severity = ANY (ARRAY['minor'::text, 'major'::text, 'critical'::text]))),
    CONSTRAINT delivery_incidents_status_check CHECK ((status = ANY (ARRAY['open'::text, 'resolved'::text, 'cancelled'::text]))),
    CONSTRAINT delivery_incidents_type_check CHECK ((incident_type = ANY (ARRAY['kendaraan_rusak'::text, 'kecelakaan'::text, 'macet'::text, 'cuaca'::text, 'alamat_salah'::text, 'dc_tutup'::text, 'dc_tolak'::text, 'barang_rusak'::text, 'barang_kurang'::text, 'dokumen_kurang'::text, 'lainnya'::text])))
);


ALTER TABLE public.delivery_incidents OWNER TO postgres;

--
-- Name: TABLE delivery_incidents; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.delivery_incidents IS 'Kendala/insiden selama perjalanan Surat Jalan. Sumber data tracking SLA vendor pengiriman. occurred_at (kapan terjadi) sengaja dipisah dari reported_at (kapan dilaporkan).';


--
-- Name: delivery_note_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_note_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    delivery_note_id uuid NOT NULL,
    picking_list_item_id uuid,
    product_name text DEFAULT ''::text NOT NULL,
    sku text DEFAULT ''::text NOT NULL,
    qty integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    product_id uuid,
    sp_order_item_id uuid
);


ALTER TABLE public.delivery_note_items OWNER TO postgres;

--
-- Name: delivery_notes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'd2e5e565-5f67-4954-b8d9-5979a2a0c697'::uuid NOT NULL,
    do_no text NOT NULL,
    sp_no text NOT NULL,
    picking_list_id uuid,
    customer_id uuid,
    destination_address text,
    driver_name text,
    driver_phone text,
    vehicle_no text,
    ship_date date,
    total_koli integer,
    total_weight numeric(12,2),
    status text DEFAULT 'draft'::text NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    dispatched_at timestamp with time zone,
    delivered_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    customer_name text,
    sp_order_id uuid,
    CONSTRAINT delivery_notes_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'in_transit'::text, 'delivered'::text, 'cancelled'::text])))
);


ALTER TABLE public.delivery_notes OWNER TO postgres;

--
-- Name: departments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.departments (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    parent_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.departments OWNER TO postgres;

--
-- Name: TABLE departments; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.departments IS 'Organizational units. Codes appear as the {DEPT} segment in document numbers.';


--
-- Name: COLUMN departments.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.departments.code IS 'Short dept code matching the Document Numbering standard: SLS, LOG, FIN, PROC, IT, MGMT, HR.';


--
-- Name: COLUMN departments.parent_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.departments.parent_id IS 'Self-referential parent department for hierarchy. NULL = top-level.';


--
-- Name: COLUMN departments.deleted_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.departments.deleted_at IS 'Soft delete timestamp. NULL = active.';


--
-- Name: document_numbering; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.document_numbering (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    document_type character varying NOT NULL,
    prefix character varying DEFAULT ''::character varying NOT NULL,
    suffix character varying DEFAULT ''::character varying NOT NULL,
    padding_digits integer DEFAULT 4 NOT NULL,
    separator character varying DEFAULT '/'::character varying NOT NULL,
    reset_cadence character varying DEFAULT 'yearly'::character varying NOT NULL,
    last_sequence integer DEFAULT 0 NOT NULL,
    last_reset_at timestamp with time zone,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT document_numbering_reset_cadence_check CHECK (((reset_cadence)::text = ANY ((ARRAY['yearly'::character varying, 'monthly'::character varying, 'never'::character varying])::text[])))
);


ALTER TABLE public.document_numbering OWNER TO postgres;

--
-- Name: document_sequences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.document_sequences (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    document_type character varying(20) NOT NULL,
    department_code character varying(20) NOT NULL,
    year smallint NOT NULL,
    month smallint DEFAULT 0 NOT NULL,
    last_sequence integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    day smallint DEFAULT 0 NOT NULL
);


ALTER TABLE public.document_sequences OWNER TO postgres;

--
-- Name: TABLE document_sequences; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.document_sequences IS 'Running sequence counter per (company, document_type, department_code, year, month). Incremented atomically via UPDATE ... RETURNING. See docs/workflow/document-numbering.md.';


--
-- Name: COLUMN document_sequences.month; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_sequences.month IS '0 = yearly reset (most common). 1–12 = monthly reset. Matches reset_period in document_types.';


--
-- Name: COLUMN document_sequences.last_sequence; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_sequences.last_sequence IS 'The last assigned sequence number. Increment atomically: UPDATE ... SET last_sequence = last_sequence + 1 ... RETURNING last_sequence. Never SELECT then UPDATE.';


--
-- Name: COLUMN document_sequences.day; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_sequences.day IS '0 = not day-scoped (yearly/monthly reset, all pre-existing callers). 1-31 = daily reset (BNF).';


--
-- Name: document_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.document_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    document_type character varying NOT NULL,
    header_text text,
    footer_text text,
    terms_and_conditions text,
    footnote text,
    logo_position character varying DEFAULT 'left'::character varying NOT NULL,
    show_stamp boolean DEFAULT true NOT NULL,
    show_signature boolean DEFAULT true NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT document_templates_logo_position_check CHECK (((logo_position)::text = ANY ((ARRAY['left'::character varying, 'center'::character varying, 'right'::character varying])::text[])))
);


ALTER TABLE public.document_templates OWNER TO postgres;

--
-- Name: document_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.document_types (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    module character varying(50) NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    prefix_format character varying(100) DEFAULT '{DOC}/{ENTITY}/{DEPT}/{YYYY}/{SEQ}'::character varying NOT NULL,
    department_code character varying(20) NOT NULL,
    reset_period character varying(10) DEFAULT 'yearly'::character varying NOT NULL,
    seq_padding smallint DEFAULT 4 NOT NULL,
    approval_required boolean DEFAULT true NOT NULL,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT document_types_reset_period_check CHECK (((reset_period)::text = ANY ((ARRAY['yearly'::character varying, 'monthly'::character varying])::text[])))
);


ALTER TABLE public.document_types OWNER TO postgres;

--
-- Name: TABLE document_types; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.document_types IS 'Document type registry per company. Defines numbering format, approval requirement, and department segment for each document code.';


--
-- Name: COLUMN document_types.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_types.code IS 'Short document code: QT, SP, SHP, CUS, TRD, PR, PO, GRN, INV, RCP, PV, JE, AST, TCK, HRG.';


--
-- Name: COLUMN document_types.prefix_format; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_types.prefix_format IS 'Numbering format template. Supported tokens: {DOC}, {ENTITY}, {DEPT}, {YYYY}, {MM}, {SEQ}.';


--
-- Name: COLUMN document_types.department_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_types.department_code IS 'Default department code used in the document number segment. Stored as varchar — NOT a FK to departments. See docs/workflow/document-numbering.md.';


--
-- Name: COLUMN document_types.reset_period; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_types.reset_period IS 'Sequence reset period: yearly (most common) or monthly.';


--
-- Name: COLUMN document_types.seq_padding; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.document_types.seq_padding IS 'Zero-padding width for the sequence segment. Default 4 produces 0001, 0042, 1234.';


--
-- Name: dropdown_options; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dropdown_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    group_key text NOT NULL,
    list_key text NOT NULL,
    label text NOT NULL,
    value text NOT NULL,
    sort_order smallint DEFAULT 0,
    is_active boolean DEFAULT true,
    company_id uuid,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.dropdown_options OWNER TO postgres;

--
-- Name: entity_bank_accounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.entity_bank_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    bank_name character varying NOT NULL,
    account_number character varying NOT NULL,
    account_holder character varying NOT NULL,
    branch character varying,
    currency character varying(3) DEFAULT 'IDR'::character varying NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.entity_bank_accounts OWNER TO postgres;

--
-- Name: entity_finance_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.entity_finance_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    ppn_rate numeric(5,2) DEFAULT 11.00 NOT NULL,
    ppn_formula character varying DEFAULT 'opsi_b'::character varying NOT NULL,
    pph_rate numeric(5,2) DEFAULT 0.00 NOT NULL,
    tax_mode character varying DEFAULT 'exclusive'::character varying NOT NULL,
    base_currency character varying(3) DEFAULT 'IDR'::character varying NOT NULL,
    supported_currencies text[] DEFAULT '{IDR}'::text[] NOT NULL,
    rate_input_mode character varying DEFAULT 'manual'::character varying NOT NULL,
    default_payment_terms integer DEFAULT 30 NOT NULL,
    quotation_validity_days integer DEFAULT 14 NOT NULL,
    default_incoterm character varying,
    rounding_mode character varying DEFAULT 'round'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    default_payment_term_id uuid,
    CONSTRAINT entity_finance_settings_ppn_formula_check CHECK (((ppn_formula)::text = ANY ((ARRAY['opsi_a'::character varying, 'opsi_b'::character varying])::text[]))),
    CONSTRAINT entity_finance_settings_rate_input_mode_check CHECK (((rate_input_mode)::text = ANY ((ARRAY['manual'::character varying, 'daily'::character varying])::text[]))),
    CONSTRAINT entity_finance_settings_rounding_mode_check CHECK (((rounding_mode)::text = ANY ((ARRAY['round'::character varying, 'floor'::character varying, 'ceil'::character varying])::text[]))),
    CONSTRAINT entity_finance_settings_tax_mode_check CHECK (((tax_mode)::text = ANY ((ARRAY['inclusive'::character varying, 'exclusive'::character varying])::text[])))
);


ALTER TABLE public.entity_finance_settings OWNER TO postgres;

--
-- Name: entity_signatories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.entity_signatories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name character varying NOT NULL,
    title character varying NOT NULL,
    document_types text[] DEFAULT '{}'::text[] NOT NULL,
    signature_url text,
    stamp_url text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.entity_signatories OWNER TO postgres;

--
-- Name: exchange_rates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.exchange_rates (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    from_currency character varying(3) NOT NULL,
    to_currency character varying(3) NOT NULL,
    rate numeric(18,6) NOT NULL,
    effective_date date NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT exchange_rates_no_self_conversion CHECK (((from_currency)::text <> (to_currency)::text)),
    CONSTRAINT exchange_rates_rate_check CHECK ((rate > (0)::numeric))
);


ALTER TABLE public.exchange_rates OWNER TO postgres;

--
-- Name: TABLE exchange_rates; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.exchange_rates IS 'Company-scoped exchange rate history. Never delete historical rates — deactivate via effective_date or add a new rate.';


--
-- Name: COLUMN exchange_rates.rate; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.exchange_rates.rate IS 'Rate: 1 unit of from_currency = rate units of to_currency. Must be > 0.';


--
-- Name: COLUMN exchange_rates.effective_date; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.exchange_rates.effective_date IS 'The date from which this rate is valid. Use most recent rate on or before the transaction date.';


--
-- Name: hrga_approval_configs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_approval_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    request_type_id uuid NOT NULL,
    level integer NOT NULL,
    approver_role character varying(50) NOT NULL,
    approver_user_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hrga_approval_configs_level_check CHECK (((level >= 1) AND (level <= 3)))
);


ALTER TABLE public.hrga_approval_configs OWNER TO postgres;

--
-- Name: hrga_notification_queue; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_notification_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    request_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    recipient_email character varying(200) NOT NULL,
    notification_type character varying(50) NOT NULL,
    payload jsonb,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    sent_at timestamp with time zone,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hrga_notification_queue_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'sent'::character varying, 'failed'::character varying, 'skipped'::character varying])::text[]))),
    CONSTRAINT hrga_notification_queue_type_check CHECK (((notification_type)::text = ANY ((ARRAY['request_submitted'::character varying, 'request_approved'::character varying, 'request_rejected'::character varying, 'approval_pending'::character varying, 'revision_requested'::character varying])::text[])))
);


ALTER TABLE public.hrga_notification_queue OWNER TO postgres;

--
-- Name: hrga_offboarding_checklists; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_offboarding_checklists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    department character varying(50) DEFAULT 'ALL'::character varying NOT NULL,
    responsible_role character varying(50) NOT NULL,
    item_order integer DEFAULT 0 NOT NULL,
    item_description character varying(300) NOT NULL,
    is_required boolean DEFAULT true NOT NULL,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT hrga_offboarding_checklists_role_check CHECK (((responsible_role)::text = ANY ((ARRAY['hrga'::character varying, 'it'::character varying, 'finance'::character varying, 'supervisor'::character varying])::text[])))
);


ALTER TABLE public.hrga_offboarding_checklists OWNER TO postgres;

--
-- Name: hrga_offboarding_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_offboarding_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    checklist_id uuid,
    item_order integer DEFAULT 0 NOT NULL,
    item_description character varying(300) NOT NULL,
    responsible_role character varying(50) NOT NULL,
    is_required boolean DEFAULT true NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    completed_by uuid,
    completed_at timestamp with time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hrga_offboarding_items_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'done'::character varying, 'skipped'::character varying, 'na'::character varying])::text[])))
);


ALTER TABLE public.hrga_offboarding_items OWNER TO postgres;

--
-- Name: hrga_request_approvals; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_request_approvals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    level integer NOT NULL,
    approver_id uuid NOT NULL,
    approver_role character varying(50) NOT NULL,
    action character varying(30) NOT NULL,
    comment text,
    actioned_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hrga_request_approvals_action_check CHECK (((action)::text = ANY ((ARRAY['approved'::character varying, 'rejected'::character varying, 'revision_requested'::character varying, 'noted'::character varying])::text[]))),
    CONSTRAINT hrga_request_approvals_level_check CHECK (((level >= 1) AND (level <= 3)))
);


ALTER TABLE public.hrga_request_approvals OWNER TO postgres;

--
-- Name: hrga_request_attachments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_request_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    file_name character varying(255) NOT NULL,
    storage_path text NOT NULL,
    file_size_bytes bigint,
    mime_type character varying(100),
    uploaded_by uuid NOT NULL,
    uploaded_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.hrga_request_attachments OWNER TO postgres;

--
-- Name: hrga_request_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_request_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    line_no integer DEFAULT 1 NOT NULL,
    item_description character varying(300) NOT NULL,
    quantity numeric(18,4) DEFAULT 1 NOT NULL,
    unit character varying(50),
    unit_price numeric(18,4),
    total_price numeric(18,4),
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hrga_request_items_line_no_positive CHECK ((line_no > 0)),
    CONSTRAINT hrga_request_items_qty_positive CHECK ((quantity > (0)::numeric))
);


ALTER TABLE public.hrga_request_items OWNER TO postgres;

--
-- Name: hrga_request_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_request_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    category_code character varying(10) NOT NULL,
    category_name character varying(100) NOT NULL,
    type_code character varying(30) NOT NULL,
    type_name character varying(150) NOT NULL,
    description text,
    requires_attachment boolean DEFAULT false NOT NULL,
    requires_amount boolean DEFAULT false NOT NULL,
    requires_date_range boolean DEFAULT false NOT NULL,
    approval_levels integer DEFAULT 1 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT hrga_request_types_approval_levels_check CHECK (((approval_levels >= 1) AND (approval_levels <= 3))),
    CONSTRAINT hrga_request_types_category_check CHECK (((category_code)::text = ANY ((ARRAY['ADM'::character varying, 'AST'::character varying, 'FAC'::character varying, 'TRV'::character varying, 'FIN'::character varying, 'OFF'::character varying])::text[])))
);


ALTER TABLE public.hrga_request_types OWNER TO postgres;

--
-- Name: hrga_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hrga_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    document_no character varying(50) NOT NULL,
    request_type_id uuid NOT NULL,
    requester_id uuid NOT NULL,
    department_id uuid,
    branch_id uuid,
    subject character varying(300) NOT NULL,
    description text,
    requested_date date,
    start_date date,
    end_date date,
    amount numeric(18,4),
    currency_code character varying(3) DEFAULT 'IDR'::character varying,
    destination character varying(200),
    notes text,
    status character varying(30) DEFAULT 'draft'::character varying NOT NULL,
    current_level integer DEFAULT 0 NOT NULL,
    total_levels integer DEFAULT 1 NOT NULL,
    submitted_at timestamp with time zone,
    approved_at timestamp with time zone,
    rejected_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT hrga_requests_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'submitted'::character varying, 'under_review'::character varying, 'revision_requested'::character varying, 'revised'::character varying, 'approved'::character varying, 'rejected'::character varying, 'cancelled'::character varying, 'completed'::character varying, 'archived'::character varying])::text[]))),
    CONSTRAINT hrga_requests_total_levels_check CHECK (((total_levels >= 1) AND (total_levels <= 3)))
);


ALTER TABLE public.hrga_requests OWNER TO postgres;

--
-- Name: inquiries; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inquiries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    inquiry_no text NOT NULL,
    prospect_id uuid,
    customer_id uuid,
    service_type character varying,
    route text,
    estimated_volume text,
    notes text,
    status character varying DEFAULT 'OPEN'::character varying,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    deadline_quote date,
    pol text,
    pod text,
    incoterms text[],
    container_types text[],
    goods_name text,
    hs_code text,
    weight_kg numeric(12,2),
    volume_cbm numeric(12,2),
    cargo_types text[],
    un_number text,
    imo_class text,
    has_msds text,
    additional_services text[],
    dimension text,
    pickup_address text,
    delivery_address text,
    won_reason text,
    lost_reason text,
    estimated_value numeric,
    contact_id uuid,
    owner_id uuid,
    closed_at timestamp with time zone,
    closed_by uuid,
    loss_reason_id uuid,
    competitor_name text,
    competitor_price numeric,
    cancel_reason text,
    CONSTRAINT inquiries_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'IN_REVIEW'::character varying, 'QUOTED'::character varying, 'NEGOTIATION'::character varying, 'WON'::character varying, 'LOST'::character varying, 'CANCELLED'::character varying])::text[])))
);


ALTER TABLE public.inquiries OWNER TO postgres;

--
-- Name: COLUMN inquiries.lost_reason; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.lost_reason IS 'DISUPERSEDI oleh loss_reason_id (master-based) sejak batch Pipeline CRM v3, 28 Agu 2026. Baris lama dibiarkan apa adanya; penulisan baru lewat loss_reason_id. Drop menyusul di batch pembersihan terpisah, setelah nol pembaca tersisa.';


--
-- Name: COLUMN inquiries.owner_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.owner_id IS 'Pemilik inquiry. Di-backfill dari created_by (batch persiapan CRM v3). Nullable: created_by sendiri nullable.';


--
-- Name: COLUMN inquiries.closed_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.closed_at IS 'Saat deal ditutup (WON/LOST/CANCELLED). Distempel otomatis trg_z_stamp_inquiry_closure; TIDAK ditimpa bila FE sudah mengirim nilainya sendiri.';


--
-- Name: COLUMN inquiries.closed_by; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.closed_by IS 'Pelaku penutupan (auth.uid()). NULL bila penutupan terjadi tanpa konteks user.';


--
-- Name: COLUMN inquiries.loss_reason_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.loss_reason_id IS 'Alasan kalah berbasis master loss_reasons. Menggantikan kolom teks bebas lost_reason.';


--
-- Name: COLUMN inquiries.competitor_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.competitor_name IS 'Nama pesaing. Diwajibkan FE hanya bila loss_reasons.code = PRICE atau COMPETITOR.';


--
-- Name: COLUMN inquiries.competitor_price; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.competitor_price IS 'Harga pesaing. Diwajibkan FE hanya bila loss_reasons.code = PRICE atau COMPETITOR.';


--
-- Name: COLUMN inquiries.cancel_reason; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiries.cancel_reason IS 'Alasan pembatalan, teks bebas. SENGAJA bukan dari master: ini catatan operasional, bukan taksonomi kompetitif seperti alasan kalah.';


--
-- Name: inquiry_comment_mentions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inquiry_comment_mentions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    comment_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.inquiry_comment_mentions OWNER TO postgres;

--
-- Name: inquiry_comments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inquiry_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    inquiry_id uuid NOT NULL,
    created_by uuid NOT NULL,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


ALTER TABLE public.inquiry_comments OWNER TO postgres;

--
-- Name: inquiry_status_history; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inquiry_status_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    inquiry_id uuid NOT NULL,
    from_status character varying(30),
    to_status character varying(30) NOT NULL,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    reason text,
    duration_seconds integer,
    CONSTRAINT ish_duration_check CHECK (((duration_seconds IS NULL) OR (duration_seconds >= 0)))
);


ALTER TABLE public.inquiry_status_history OWNER TO postgres;

--
-- Name: TABLE inquiry_status_history; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.inquiry_status_history IS 'Riwayat perubahan inquiries.status. Audit-only: ditulis EKSKLUSIF oleh trg_z_log_inquiry_status_change (SECURITY DEFINER), nol policy tulis untuk authenticated.';


--
-- Name: COLUMN inquiry_status_history.changed_by; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiry_status_history.changed_by IS 'auth.uid() saat transisi. NULL bila transisi dipicu trigger tanpa konteks user (mis. WON otomatis dari sales_orders).';


--
-- Name: COLUMN inquiry_status_history.reason; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiry_status_history.reason IS 'Alasan bebas dari jalur manual. Diisi FE lewat kolom penutupan di inquiries; trigger menyalinnya bila tersedia.';


--
-- Name: COLUMN inquiry_status_history.duration_seconds; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inquiry_status_history.duration_seconds IS 'Lama inquiry berada di status SEBELUMNYA, dalam detik. NULL = tidak diketahui (baris backfill). JANGAN diisi mundur dengan angka karangan.';


--
-- Name: journal_entries; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.journal_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    entry_date date DEFAULT CURRENT_DATE NOT NULL,
    reference_type text NOT NULL,
    reference_id uuid NOT NULL,
    description text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT journal_entries_reference_type_check CHECK ((reference_type = ANY (ARRAY['invoice_issued'::text, 'payment_received'::text])))
);


ALTER TABLE public.journal_entries OWNER TO postgres;

--
-- Name: TABLE journal_entries; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.journal_entries IS 'Jurnal AR minimal Fase 5. Auto-post tanpa approval. Tulis HANYA via RPC SECURITY DEFINER. Koreksi = jurnal pembalik, bukan UPDATE.';


--
-- Name: journal_entry_lines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.journal_entry_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    journal_entry_id uuid NOT NULL,
    account_id uuid NOT NULL,
    debit numeric(18,2) DEFAULT 0 NOT NULL,
    credit numeric(18,2) DEFAULT 0 NOT NULL,
    CONSTRAINT journal_entry_lines_sign_check CHECK (((debit >= (0)::numeric) AND (credit >= (0)::numeric) AND ((debit = (0)::numeric) OR (credit = (0)::numeric))))
);


ALTER TABLE public.journal_entry_lines OWNER TO postgres;

--
-- Name: loss_reasons; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.loss_reasons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    category character varying(30),
    applies_to character varying(10) DEFAULT 'deal'::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT loss_reasons_applies_check CHECK (((applies_to)::text = ANY (ARRAY['deal'::text, 'account'::text, 'both'::text])))
);


ALTER TABLE public.loss_reasons OWNER TO postgres;

--
-- Name: TABLE loss_reasons; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.loss_reasons IS 'Taksonomi GLOBAL alasan kalah (deal/akun). company_id selalu NULL — jangan difilter di FE (gotcha #18).';


--
-- Name: meeting_moms; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.meeting_moms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    mom_no text,
    mom_type text NOT NULL,
    divisi text,
    meeting_date date,
    time_start time without time zone,
    time_end time without time zone,
    pemimpin text,
    notulis_id uuid,
    lokasi text,
    peserta text[],
    catatan_tambahan text,
    status text DEFAULT 'draft'::text,
    submitted_at timestamp with time zone,
    approved_by uuid,
    approved_at timestamp with time zone,
    reject_reason text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT meeting_moms_mom_type_check CHECK ((mom_type = ANY (ARRAY['weekly'::text, 'project'::text, 'probation'::text, 'board'::text, 'departmental'::text, 'adhoc'::text]))),
    CONSTRAINT meeting_moms_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'submitted'::text, 'approved'::text, 'rejected'::text])))
);


ALTER TABLE public.meeting_moms OWNER TO postgres;

--
-- Name: menu_actions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.menu_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    menu_id uuid NOT NULL,
    action text NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.menu_actions OWNER TO postgres;

--
-- Name: module_actions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.module_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    module_id uuid NOT NULL,
    action text NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.module_actions OWNER TO postgres;

--
-- Name: module_menus; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.module_menus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    module_id uuid NOT NULL,
    key text NOT NULL,
    label text NOT NULL,
    sort_order integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.module_menus OWNER TO postgres;

--
-- Name: modules; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.modules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    label text NOT NULL,
    sort_order integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.modules OWNER TO postgres;

--
-- Name: mom_action_plans; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mom_action_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mom_id uuid,
    section text NOT NULL,
    no smallint,
    action_plan text,
    pic text,
    timeline date,
    prioritas text,
    status text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT mom_action_plans_prioritas_check CHECK ((prioritas = ANY (ARRAY['high'::text, 'medium'::text, 'low'::text]))),
    CONSTRAINT mom_action_plans_section_check CHECK ((section = ANY (ARRAY['review'::text, 'new'::text]))),
    CONSTRAINT mom_action_plans_status_check CHECK ((status = ANY (ARRAY['done'::text, 'on_progress'::text, 'pending'::text, 'high_priority'::text, 'new_initiative'::text, 'appreciated'::text, 'positive'::text, 'need_improvement'::text])))
);


ALTER TABLE public.mom_action_plans OWNER TO postgres;

--
-- Name: mom_improvements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mom_improvements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mom_id uuid,
    no smallint,
    usulan text,
    catatan text,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.mom_improvements OWNER TO postgres;

--
-- Name: mom_issues; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mom_issues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mom_id uuid,
    no smallint,
    issue text,
    dampak text,
    akar_masalah text,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.mom_issues OWNER TO postgres;

--
-- Name: mom_progress_updates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mom_progress_updates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mom_id uuid,
    no smallint,
    aspek text,
    capaian text,
    target text,
    status text,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.mom_progress_updates OWNER TO postgres;

--
-- Name: notification_rules; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    event_type character varying NOT NULL,
    event_scope character varying,
    channel character varying DEFAULT 'in_app'::character varying NOT NULL,
    recipient_type character varying DEFAULT 'role'::character varying NOT NULL,
    recipient_role character varying,
    recipient_user_id uuid,
    template_subject character varying,
    template_body text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT notification_rules_channel_check CHECK (((channel)::text = ANY ((ARRAY['in_app'::character varying, 'email'::character varying, 'both'::character varying])::text[]))),
    CONSTRAINT notification_rules_recipient_type_check CHECK (((recipient_type)::text = ANY ((ARRAY['role'::character varying, 'user'::character varying, 'assigned_to'::character varying, 'created_by'::character varying])::text[])))
);


ALTER TABLE public.notification_rules OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_id uuid NOT NULL,
    event_type character varying NOT NULL,
    title character varying NOT NULL,
    body text,
    reference_type character varying,
    reference_id uuid,
    is_read boolean DEFAULT false NOT NULL,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: payment_terms; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_terms (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    days_due integer DEFAULT 0 NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT payment_terms_days_due_check CHECK ((days_due >= 0))
);


ALTER TABLE public.payment_terms OWNER TO postgres;

--
-- Name: TABLE payment_terms; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.payment_terms IS 'Company-scoped payment term templates. Standardizes due-date calculation for customers, vendors, and invoices.';


--
-- Name: COLUMN payment_terms.days_due; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.payment_terms.days_due IS 'Number of days from invoice date until payment is due. 0 = COD (cash on delivery).';


--
-- Name: permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.permissions (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    module character varying(50) NOT NULL,
    action character varying(50) NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.permissions OWNER TO postgres;

--
-- Name: TABLE permissions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.permissions IS 'Global permission catalog. Every {module}.{action} combination that can be granted to a role. Managed by Super Admin only.';


--
-- Name: COLUMN permissions.module; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.permissions.module IS 'Module slug, e.g. companies, customers, sales_orders, invoices, users.';


--
-- Name: COLUMN permissions.action; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.permissions.action IS 'Action code: view, create, edit, delete, restore, approve, submit, export, import, print, config.';


--
-- Name: picking_list_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.picking_list_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    picking_list_id uuid NOT NULL,
    sp_item_id uuid,
    product_id uuid,
    product_name text DEFAULT ''::text NOT NULL,
    sku text DEFAULT ''::text NOT NULL,
    qty_requested integer DEFAULT 0 NOT NULL,
    qty_picked integer DEFAULT 0 NOT NULL,
    location_detail text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    qty_short integer DEFAULT 0 NOT NULL,
    CONSTRAINT picking_list_items_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'picked'::text, 'short'::text])))
);


ALTER TABLE public.picking_list_items OWNER TO postgres;

--
-- Name: picking_list_materials; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.picking_list_materials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    picking_list_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_name text DEFAULT ''::text NOT NULL,
    sku text DEFAULT ''::text NOT NULL,
    qty integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid
);


ALTER TABLE public.picking_list_materials OWNER TO postgres;

--
-- Name: picking_lists; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.picking_lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'd2e5e565-5f67-4954-b8d9-5979a2a0c697'::uuid NOT NULL,
    picking_no text NOT NULL,
    sp_no text NOT NULL,
    warehouse_id uuid,
    assigned_to uuid,
    status text DEFAULT 'pending'::text NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    sp_order_id uuid,
    customer_id uuid,
    CONSTRAINT picking_lists_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'in_progress'::text, 'done'::text, 'cancelled'::text])))
);


ALTER TABLE public.picking_lists OWNER TO postgres;

--
-- Name: positions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.positions (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid,
    department_id uuid,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    level character varying(20) DEFAULT 'Staff'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT positions_level_check CHECK (((level)::text = ANY ((ARRAY['Staff'::character varying, 'Supervisor'::character varying, 'Manager'::character varying, 'Head'::character varying, 'Director'::character varying])::text[])))
);


ALTER TABLE public.positions OWNER TO postgres;

--
-- Name: TABLE positions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.positions IS 'Company-scoped job position registry. Levels drive approval matrix thresholds.';


--
-- Name: COLUMN positions.department_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.positions.department_id IS 'Optional department assignment. NULL = position spans multiple departments.';


--
-- Name: COLUMN positions.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.positions.code IS 'Position code, unique per company. e.g. STAFF, SPV, MGR, HEAD, DIR.';


--
-- Name: COLUMN positions.level; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.positions.level IS 'Seniority level: Staff, Supervisor, Manager, Head, Director. Used for approval threshold matching.';


--
-- Name: prf; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prf (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    prf_no text NOT NULL,
    status character varying DEFAULT 'DRAFT'::character varying,
    created_by uuid,
    updated_by uuid,
    submitted_at timestamp with time zone,
    acknowledged_by uuid,
    acknowledged_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    customer_source text,
    account_id uuid,
    account_name_manual text,
    stream text,
    deadline_quotation date,
    direction text,
    commodity text,
    hs_code text,
    msds_available boolean DEFAULT false,
    service_type text,
    incoterms text,
    commercial_value numeric(14,2),
    commercial_currency text,
    origin text,
    destination text,
    pickup_address text,
    delivery_address text,
    add_on_services text[],
    add_on_others text,
    cargo_ready_date date,
    sea_freight_type text,
    sea_container_types text[],
    sea_container_qty jsonb,
    sea_lcl_gw numeric(12,2),
    sea_lcl_dimension text,
    sea_lcl_volume numeric(12,2),
    sea_lcl_koli integer,
    air_gw numeric(12,2),
    air_dimension text,
    air_volume numeric(12,2),
    air_koli integer,
    inland_fleet_types text[],
    inland_pickup_address text,
    inland_delivery_address text,
    inland_gw numeric(12,2),
    inland_dimension text,
    custom_doc_type text,
    project_freight_types text[],
    project_qty integer,
    notes text,
    inquiry_id uuid,
    suggested_rate numeric(18,2),
    rate_currency text DEFAULT 'IDR'::text NOT NULL,
    valid_from date,
    valid_until date,
    pricing_notes text,
    answered_by uuid,
    answered_at timestamp with time zone,
    exchange_rates jsonb DEFAULT '{}'::jsonb NOT NULL,
    goods_name text,
    un_number text,
    imo_class text,
    selected_offer_id uuid,
    selected_by uuid,
    selected_at timestamp with time zone,
    min_offers_waiver_reason text,
    CONSTRAINT prf_status_check CHECK (((status)::text = ANY (ARRAY['DRAFT'::text, 'SUBMITTED'::text, 'ACKNOWLEDGED'::text, 'CANCELLED'::text, 'QUOTED'::text, 'EXPIRED'::text])))
);


ALTER TABLE public.prf OWNER TO postgres;

--
-- Name: prf_cost_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prf_cost_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    prf_id uuid NOT NULL,
    component text NOT NULL,
    cost_type text DEFAULT 'vendor'::text NOT NULL,
    amount numeric(18,2) DEFAULT 0 NOT NULL,
    currency text DEFAULT 'IDR'::text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    vendor_id uuid,
    item_group text,
    is_awarded boolean DEFAULT true NOT NULL,
    exchange_rate numeric DEFAULT 1 NOT NULL,
    offer_id uuid,
    CONSTRAINT prf_cost_items_cost_type_check CHECK ((cost_type = ANY (ARRAY['vendor'::text, 'internal'::text])))
);


ALTER TABLE public.prf_cost_items OWNER TO postgres;

--
-- Name: prf_vendor_offers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prf_vendor_offers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    prf_id uuid NOT NULL,
    company_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    currency text,
    valid_from date,
    valid_until date,
    pros text NOT NULL,
    cons text NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.prf_vendor_offers OWNER TO postgres;

--
-- Name: product_price_history; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_price_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    company_id uuid NOT NULL,
    old_price numeric(18,2),
    new_price numeric(18,2),
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    reason text,
    source text,
    contract_no text,
    valid_from date,
    valid_until date,
    price_category text
);


ALTER TABLE public.product_price_history OWNER TO postgres;

--
-- Name: product_warehouse_location; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_warehouse_location (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    product_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    rack_location text,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.product_warehouse_location OWNER TO postgres;

--
-- Name: products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.products (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    category character varying(50),
    unit character varying(20),
    description text,
    is_service boolean DEFAULT true NOT NULL,
    default_price numeric(18,2) DEFAULT 0,
    tax_id uuid,
    cogs_account_id uuid,
    revenue_account_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    registered_date date,
    inventory_class character varying(100),
    main_group character varying(100),
    operational_function text,
    uom text,
    unit_cost numeric(15,2),
    weight text,
    dimensions text,
    packaging text,
    min_order_qty text,
    cogs_account text,
    revenue_account text,
    price_semester numeric(18,2),
    price_tahunan numeric(18,2),
    price_project numeric(18,2),
    reorder_point numeric
);


ALTER TABLE public.products OWNER TO postgres;

--
-- Name: TABLE products; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.products IS 'Company-scoped product and service catalog. Used in quotations, sales orders, invoices, and purchase orders.';


--
-- Name: COLUMN products.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.products.code IS 'Product/service code, unique per company. e.g. SRV-0001 for services, PRD-0001 for goods.';


--
-- Name: COLUMN products.is_service; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.products.is_service IS 'True = billable service (most MSI/JCI items). False = physical goods (SBI trading).';


--
-- Name: COLUMN products.default_price; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.products.default_price IS 'Default unit price. Overridable at transaction level.';


--
-- Name: COLUMN products.cogs_account_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.products.cogs_account_id IS 'Nullable FK to chart_of_accounts for COGS mapping. Set in Phase 3 when COA is configured.';


--
-- Name: COLUMN products.revenue_account_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.products.revenue_account_id IS 'Nullable FK to chart_of_accounts for revenue mapping. Set in Phase 3 when COA is configured.';


--
-- Name: COLUMN products.reorder_point; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.products.reorder_point IS 'Reorder point / ROP per produk (unit). Nullable = belum ditentukan. Diisi manual sesuai SOP Storbit (Finance/Warehouse Controller), bukan dihitung sistem. Terpisah dari min_order_qty (text bebas).';


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    full_name text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid NOT NULL,
    branch_id uuid,
    department_id uuid,
    position_id uuid,
    last_login_at timestamp with time zone,
    mfa_required boolean DEFAULT false NOT NULL,
    avatar_url text,
    phone character varying,
    bio text,
    job_title character varying,
    employee_id character varying,
    date_of_birth date,
    gender character varying,
    address text,
    emergency_contact_name character varying,
    emergency_contact_phone character varying,
    notification_preferences jsonb DEFAULT '{}'::jsonb,
    display_preferences jsonb DEFAULT '{}'::jsonb,
    reports_to uuid,
    email text
);


ALTER TABLE public.profiles OWNER TO postgres;

--
-- Name: TABLE profiles; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.profiles IS 'Legacy user profile table. One row per auth.users entry, created by the on_auth_user_created trigger. Extended by migration 007 with ERP fields. role column maps to user_role_legacy enum; migrated to user_roles table in Phase 1.0F.';


--
-- Name: COLUMN profiles.active; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.active IS 'False = user is disabled. AuthContext checks profile.active before granting isAuthenticated = true.';


--
-- Name: COLUMN profiles.company_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.company_id IS 'ERP business entity this user belongs to. NULL until Phase 1.0F migration assigns company_id.';


--
-- Name: COLUMN profiles.branch_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.branch_id IS 'Branch assignment. Optional. NULL = no branch restriction.';


--
-- Name: COLUMN profiles.department_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.department_id IS 'Department assignment. Optional. NULL = no department restriction.';


--
-- Name: COLUMN profiles.position_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.position_id IS 'Job position. Nullable FK to positions (added in migration 9). NULL = no position assigned.';


--
-- Name: COLUMN profiles.last_login_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.last_login_at IS 'Timestamp of most recent successful login. Updated by auth trigger or application layer.';


--
-- Name: COLUMN profiles.mfa_required; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.profiles.mfa_required IS 'True = MFA is mandatory for this user. Enforced by auth policy. Default false; set true for finance_controller, bod, admin, super_admin.';


--
-- Name: quotation_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.quotation_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    quotation_id uuid NOT NULL,
    sort_order integer DEFAULT 0,
    description text NOT NULL,
    qty numeric DEFAULT 1,
    unit character varying,
    unit_price numeric(15,2) DEFAULT 0,
    notes text,
    group_name character varying DEFAULT 'CHARGES'::character varying,
    currency character varying DEFAULT 'IDR'::character varying,
    unit_label character varying DEFAULT 'Per 20Ft'::character varying,
    exchange_rate numeric(15,2) DEFAULT 1,
    total numeric(15,2) DEFAULT 0,
    cost_price numeric(15,2) DEFAULT 0,
    if_any boolean DEFAULT false NOT NULL
);


ALTER TABLE public.quotation_items OWNER TO postgres;

--
-- Name: quotations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.quotations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    quotation_no text NOT NULL,
    revision integer DEFAULT 1,
    inquiry_id uuid,
    prospect_id uuid,
    customer_id uuid,
    service_type character varying,
    valid_until date,
    payment_terms_id uuid,
    currency_code character varying DEFAULT 'IDR'::character varying,
    notes text,
    terms text,
    subtotal numeric(15,2) DEFAULT 0,
    tax_amount numeric(15,2) DEFAULT 0,
    total_amount numeric(15,2) DEFAULT 0,
    status character varying DEFAULT 'DRAFT'::character varying,
    sent_at timestamp with time zone,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    usd_rate numeric(15,2) DEFAULT 16000,
    route text,
    pricing_done_at timestamp with time zone,
    quote_sent_at timestamp with time zone,
    discount_pct numeric DEFAULT 0,
    margin_floor numeric DEFAULT 0,
    internal_notes text,
    quote_date date,
    vat_rate numeric DEFAULT 0.011,
    attention_to text,
    pickup_address text,
    delivery_address text,
    cargo_mode text,
    gw text,
    dimension text,
    cw text,
    cbm text,
    container_type text,
    container_qty integer,
    exchange_rates jsonb DEFAULT '{}'::jsonb NOT NULL,
    prf_id uuid
);


ALTER TABLE public.quotations OWNER TO postgres;

--
-- Name: COLUMN quotations.exchange_rates; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.quotations.exchange_rates IS 'Tabel kurs manual per-quotation: {"USD":16200,"SGD":12000}. IDR implisit = 1 (tak disimpan). Sumber kebenaran kurs; quotation_items.exchange_rate = salinan materialized (write-through) yang dibaca Detail & PDF. Input manual, tanpa lookup FX.';


--
-- Name: COLUMN quotations.prf_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.quotations.prf_id IS 'PRF yang jadi dasar harga quotation ini. Boleh null untuk quotation yang dibuat manual tanpa PRF.';


--
-- Name: rate_sheets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.rate_sheets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    created_by uuid NOT NULL,
    rate_name text NOT NULL,
    valid_until date,
    columns jsonb DEFAULT '[]'::jsonb NOT NULL,
    rows jsonb DEFAULT '[]'::jsonb NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.rate_sheets OWNER TO postgres;

--
-- Name: role_menu_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.role_menu_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_id uuid NOT NULL,
    menu_action_id uuid,
    module_action_id uuid,
    granted_by uuid,
    granted_at timestamp with time zone DEFAULT now(),
    CONSTRAINT rmp_one_action_required CHECK ((((module_action_id IS NOT NULL) AND (menu_action_id IS NULL)) OR ((module_action_id IS NULL) AND (menu_action_id IS NOT NULL))))
);


ALTER TABLE public.role_menu_permissions OWNER TO postgres;

--
-- Name: role_permission_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.role_permission_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_id uuid NOT NULL,
    menu_action_id uuid NOT NULL,
    is_cross_entity boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.role_permission_templates OWNER TO postgres;

--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.role_permissions (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    granted_by uuid,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    is_cross_entity boolean DEFAULT false NOT NULL
);


ALTER TABLE public.role_permissions OWNER TO postgres;

--
-- Name: TABLE role_permissions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.role_permissions IS 'Links roles to permissions. No soft delete — revoke by deleting the row. Full matrix seed in Phase 1.0C.';


--
-- Name: roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.roles (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid,
    code character varying(50) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    is_system_role boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.roles OWNER TO postgres;

--
-- Name: TABLE roles; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.roles IS 'Named permission sets, company-scoped. System roles are pre-seeded and cannot be modified by company Admins.';


--
-- Name: COLUMN roles.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.roles.code IS 'Role code slug: super_admin, admin, bod, finance_controller, etc. Unique per company.';


--
-- Name: COLUMN roles.is_system_role; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.roles.is_system_role IS 'True = seeded by platform, cannot be renamed or deleted by company admin.';


--
-- Name: COLUMN roles.deleted_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.roles.deleted_at IS 'Soft delete. Custom roles only — system roles may not be deleted.';


--
-- Name: sales_calls; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_calls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    prospect_id uuid,
    salesperson_id uuid,
    call_date date DEFAULT CURRENT_DATE NOT NULL,
    call_time time without time zone,
    duration_minutes integer,
    call_type character varying(50),
    contact_name text,
    contact_phone text,
    bant_collected integer DEFAULT 0,
    result character varying(50),
    notes text,
    next_action text,
    next_action_date date,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.sales_calls OWNER TO postgres;

--
-- Name: sales_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    so_no text NOT NULL,
    status character varying DEFAULT 'DRAFT'::character varying NOT NULL,
    inquiry_id uuid NOT NULL,
    account_id uuid NOT NULL,
    signed boolean DEFAULT false NOT NULL,
    sign_link text,
    signed_at timestamp with time zone,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    external_ref text,
    booking_no text,
    CONSTRAINT sales_orders_status_check CHECK (((status)::text = ANY (ARRAY['DRAFT'::text, 'SENT'::text])))
);


ALTER TABLE public.sales_orders OWNER TO postgres;

--
-- Name: COLUMN sales_orders.external_ref; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sales_orders.external_ref IS 'Nomor referensi SO ini di sistem operasional (Odoo). Nullable, belum dipakai UI mana pun — kunci sambungan disiapkan lebih dulu supaya rekonsiliasi tidak perlu mencari padanan manual nanti.';


--
-- Name: COLUMN sales_orders.booking_no; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sales_orders.booking_no IS 'Nomor booking ke carrier. Nullable, belum dipakai UI mana pun.';


--
-- Name: sales_visit_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_visit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    visit_id uuid NOT NULL,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now(),
    from_status character varying(50),
    to_status character varying(50),
    notes text
);


ALTER TABLE public.sales_visit_logs OWNER TO postgres;

--
-- Name: sales_visits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_visits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    prospect_id uuid,
    salesperson_id uuid,
    visit_date date NOT NULL,
    visit_time time without time zone,
    location text,
    notes text,
    status character varying(50) DEFAULT 'scheduled'::character varying,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    point_of_meeting text,
    mom text,
    follow_up text,
    visit_type text
);


ALTER TABLE public.sales_visits OWNER TO postgres;

--
-- Name: sla_policies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sla_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(30) NOT NULL,
    name character varying(100) NOT NULL,
    policy_type character varying(20) NOT NULL,
    service_line character varying(30),
    transport_mode character varying(20),
    target_status character varying(30),
    target_scope character varying(30),
    threshold integer NOT NULL,
    time_unit character varying(20) NOT NULL,
    inherits_from uuid,
    action character varying(30) NOT NULL,
    requires_human boolean DEFAULT false NOT NULL,
    escalate_to character varying(30),
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT sla_policies_action_check CHECK (((action)::text = ANY (ARRAY['flag_stale'::text, 'create_task'::text, 'escalate_manager'::text, 'propose_cancel'::text, 'move_lead_pool'::text, 'set_free_agent'::text]))),
    CONSTRAINT sla_policies_axis_check CHECK (((((policy_type)::text = 'prf_response'::text) AND (transport_mode IS NOT NULL) AND (target_status IS NULL) AND (target_scope IS NULL)) OR (((policy_type)::text = 'deal_aging'::text) AND (target_status IS NOT NULL) AND (target_scope IS NULL)) OR (((policy_type)::text = 'account_dormancy'::text) AND (target_scope IS NOT NULL) AND (transport_mode IS NULL) AND (target_status IS NULL)))),
    CONSTRAINT sla_policies_human_check CHECK ((((action)::text <> 'propose_cancel'::text) OR (requires_human = true))),
    CONSTRAINT sla_policies_line_check CHECK (((service_line IS NULL) OR ((service_line)::text = ANY (ARRAY['freight_forwarding'::text, 'customs'::text, 'trading'::text])))),
    CONSTRAINT sla_policies_mode_check CHECK (((transport_mode IS NULL) OR ((transport_mode)::text = ANY (ARRAY['air'::text, 'fcl'::text, 'lcl'::text, 'inland'::text, 'project'::text, 'custom'::text])))),
    CONSTRAINT sla_policies_scope_check CHECK (((target_scope IS NULL) OR ((target_scope)::text = ANY (ARRAY['pre_customer'::text, 'customer'::text])))),
    CONSTRAINT sla_policies_threshold_check CHECK ((threshold > 0)),
    CONSTRAINT sla_policies_type_check CHECK (((policy_type)::text = ANY (ARRAY['prf_response'::text, 'deal_aging'::text, 'account_dormancy'::text]))),
    CONSTRAINT sla_policies_unit_check CHECK (((time_unit)::text = ANY (ARRAY['business_hour'::text, 'business_day'::text, 'day'::text, 'month'::text])))
);


ALTER TABLE public.sla_policies OWNER TO postgres;

--
-- Name: TABLE sla_policies; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.sla_policies IS 'Kebijakan SLA per entitas. Tiga policy_type: prf_response (sumbu moda), deal_aging (sumbu inquiries.status), account_dormancy (sumbu pre_customer/customer).';


--
-- Name: COLUMN sla_policies.inherits_from; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sla_policies.inherits_from IS 'Dipakai baris IN_REVIEW: ambang batasnya mengikuti baris prf_response moda yang bersangkutan.';


--
-- Name: COLUMN sla_policies.requires_human; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sla_policies.requires_human IS 'true = sistem hanya MENGUSULKAN, tidak pernah mengeksekusi sendiri.';


--
-- Name: sp_btb; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_btb (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    sp_order_id uuid NOT NULL,
    delivery_note_id uuid,
    customer_id uuid NOT NULL,
    btb_no text NOT NULL,
    btb_date date,
    qty integer,
    received_at timestamp with time zone,
    received_by uuid,
    remarks text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT sp_btb_qty_check CHECK (((qty IS NULL) OR (qty >= 0)))
);


ALTER TABLE public.sp_btb OWNER TO postgres;

--
-- Name: sp_btbs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_btbs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sp_no text NOT NULL,
    btb_no text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    remarks text
);


ALTER TABLE public.sp_btbs OWNER TO postgres;

--
-- Name: sp_invoice_lines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_invoice_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_id uuid NOT NULL,
    sp_order_item_id uuid,
    btb_id uuid,
    dpp numeric(18,2) DEFAULT 0 NOT NULL,
    ppn numeric(18,2) DEFAULT 0 NOT NULL,
    qty integer,
    "position" integer
);


ALTER TABLE public.sp_invoice_lines OWNER TO postgres;

--
-- Name: sp_invoices; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    sp_order_id uuid NOT NULL,
    invoice_no text,
    faktur_no text,
    invoice_date date,
    status text DEFAULT 'draft'::text NOT NULL,
    submitted_at timestamp with time zone,
    submit_ref text,
    total_dpp numeric(18,2) DEFAULT 0 NOT NULL,
    total_ppn numeric(18,2) DEFAULT 0 NOT NULL,
    total_amount numeric(18,2) DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    due_date date,
    CONSTRAINT sp_invoices_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'issued'::text, 'submitted'::text, 'partial'::text, 'paid'::text, 'void'::text])))
);


ALTER TABLE public.sp_invoices OWNER TO postgres;

--
-- Name: sp_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_items (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    sp_date date,
    sp_no text DEFAULT ''::text NOT NULL,
    customer_id uuid,
    product_name text DEFAULT ''::text NOT NULL,
    sku text DEFAULT ''::text NOT NULL,
    qty integer DEFAULT 0 NOT NULL,
    shipped_qty integer DEFAULT 0 NOT NULL,
    exp_date date,
    expired_date date,
    dc text DEFAULT ''::text NOT NULL,
    shipping_date date,
    btb_no_deprecated text DEFAULT ''::text NOT NULL,
    unit_price numeric(18,2) DEFAULT 0 NOT NULL,
    shipping_price numeric(18,2) DEFAULT 0 NOT NULL,
    inv boolean DEFAULT false NOT NULL,
    fp boolean DEFAULT false NOT NULL,
    submit boolean DEFAULT false NOT NULL,
    kirim boolean DEFAULT false NOT NULL,
    submit_date date,
    email_status text,
    notes text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    sla_days integer,
    estimated_delivery_date date,
    arrival_date date,
    sp_status text DEFAULT 'draft'::text NOT NULL,
    confirmed_at timestamp with time zone,
    confirmed_by uuid,
    cancelled_at timestamp with time zone,
    cancelled_by uuid,
    cancel_reason text,
    sp_category text,
    external_url text,
    product_id uuid,
    price_category text,
    review_status text,
    CONSTRAINT sp_items_sp_status_check CHECK ((sp_status = ANY (ARRAY['draft'::text, 'confirmed'::text, 'cancelled'::text])))
);


ALTER TABLE public.sp_items OWNER TO postgres;

--
-- Name: TABLE sp_items; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.sp_items IS 'SP (Surat Pesanan) line items — core freight manifest. Multiple rows share the same sp_no and are grouped in the app by groupBySP(). customer_id FK ON DELETE SET NULL preserves rows if customer is deleted.';


--
-- Name: COLUMN sp_items.inv; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_items.inv IS 'Invoice document issued flag.';


--
-- Name: COLUMN sp_items.fp; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_items.fp IS 'Faktur Pajak (tax invoice) issued flag.';


--
-- Name: COLUMN sp_items.email_status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_items.email_status IS 'Stored as text (not date). App renders it in a date input (type=date) but treats it as a string. Empty string stored as NULL.';


--
-- Name: sp_manifest_staging_20260810; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_manifest_staging_20260810 (
    sheet text,
    sp_no text,
    sheet_status text,
    inconsistent_flag text,
    dc text,
    btb_no text,
    submit_date text
);


ALTER TABLE public.sp_manifest_staging_20260810 OWNER TO postgres;

--
-- Name: sp_order_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sp_order_id uuid NOT NULL,
    company_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_name text DEFAULT ''::text NOT NULL,
    sku text DEFAULT ''::text NOT NULL,
    qty integer DEFAULT 0 NOT NULL,
    shipped_qty integer DEFAULT 0 NOT NULL,
    unit_price numeric(18,2) DEFAULT 0 NOT NULL,
    price_category text,
    shipping_price numeric(18,2) DEFAULT 0 NOT NULL,
    sla_days integer,
    estimated_delivery_date date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    legacy_sp_item_id uuid,
    CONSTRAINT sp_order_items_check CHECK (((shipped_qty >= 0) AND (shipped_qty <= qty))),
    CONSTRAINT sp_order_items_price_category_check CHECK ((price_category = ANY (ARRAY['semester'::text, 'tahunan'::text, 'project'::text]))),
    CONSTRAINT sp_order_items_qty_check CHECK ((qty >= 1))
);


ALTER TABLE public.sp_order_items OWNER TO postgres;

--
-- Name: sp_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    sp_no text NOT NULL,
    sp_date date,
    dc_id uuid NOT NULL,
    status text DEFAULT 'DRAFT'::text NOT NULL,
    is_disputed boolean DEFAULT false NOT NULL,
    dispute_reason text,
    disputed_at timestamp with time zone,
    disputed_by uuid,
    expired_date date,
    sp_category text,
    external_url text,
    notes text,
    confirmed_at timestamp with time zone,
    confirmed_by uuid,
    cancelled_at timestamp with time zone,
    cancelled_by uuid,
    cancel_reason text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    had_cancelled_picking boolean DEFAULT false NOT NULL,
    price_category text,
    inv boolean DEFAULT false NOT NULL,
    fp boolean DEFAULT false NOT NULL,
    submit boolean DEFAULT false NOT NULL,
    kirim boolean DEFAULT false NOT NULL,
    submit_date date,
    email_status text,
    CONSTRAINT sp_orders_price_category_check CHECK ((price_category = ANY (ARRAY['semester'::text, 'tahunan'::text, 'project'::text]))),
    CONSTRAINT sp_orders_status_check CHECK ((status = ANY (ARRAY['DRAFT'::text, 'CONFIRMED'::text, 'MENUNGGU_STOK'::text, 'PICKING'::text, 'PACKED'::text, 'DIKIRIM'::text, 'SAMPAI'::text, 'MENUNGGU_KONFIRMASI_DC'::text, 'BTB_TERBIT'::text, 'TERKIRIM_PENUH'::text, 'INVOICED'::text, 'SUBMITTED'::text, 'LUNAS'::text, 'CANCELLED'::text])))
);


ALTER TABLE public.sp_orders OWNER TO postgres;

--
-- Name: COLUMN sp_orders.price_category; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.price_category IS 'Tipe SP level header: semester/tahunan/project. NULL = belum/tidak dikategorikan. Sengaja senama dgn sp_order_items.price_category (kategori harga per item) — berhubungan tapi tidak wajib sama. BUKAN sp_orders.sp_category, yang artinya kategori produk (reguler/loyang/trolly).';


--
-- Name: COLUMN sp_orders.inv; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.inv IS 'Status dokumen level SP (promosi 2 Sep 2026). SUMBER KEBENARAN; sp_items.inv disinkronkan turun oleh set_sp_finance_docs(). Jangan tulis langsung.';


--
-- Name: COLUMN sp_orders.fp; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.fp IS 'Faktur Pajak, level SP. Sumber kebenaran — lihat catatan sp_orders.inv.';


--
-- Name: COLUMN sp_orders.submit; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.submit IS 'Submit ke customer, level SP. Sumber kebenaran — lihat catatan sp_orders.inv.';


--
-- Name: COLUMN sp_orders.kirim; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.kirim IS 'Kirim dokumen, level SP. Sumber kebenaran — lihat catatan sp_orders.inv.';


--
-- Name: COLUMN sp_orders.submit_date; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.submit_date IS 'Tanggal submit dokumen, level SP. Sumber kebenaran — lihat sp_orders.inv.';


--
-- Name: COLUMN sp_orders.email_status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_orders.email_status IS 'Status email ke customer, level SP. Teks bebas (sama seperti sp_items, sengaja tanpa CHECK). Sumber kebenaran — lihat catatan sp_orders.inv.';


--
-- Name: sp_payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sp_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_id uuid NOT NULL,
    payment_date date,
    amount numeric(18,2) NOT NULL,
    pph numeric(18,2) DEFAULT 0 NOT NULL,
    reference text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    bukti_potong_url text,
    bukti_potong_no text
);


ALTER TABLE public.sp_payments OWNER TO postgres;

--
-- Name: COLUMN sp_payments.bukti_potong_url; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_payments.bukti_potong_url IS 'Tautan scan bukti potong (Drive/Storage). Interim: URL manual.';


--
-- Name: COLUMN sp_payments.bukti_potong_no; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sp_payments.bukti_potong_no IS 'Nomor bukti potong PPh 23 dari customer.';


--
-- Name: status_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.status_catalog (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    code character varying(50) NOT NULL,
    label character varying(100) NOT NULL,
    description text,
    color_class character varying(100),
    applicable_modules jsonb,
    is_terminal boolean DEFAULT false NOT NULL,
    sort_order smallint DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.status_catalog OWNER TO postgres;

--
-- Name: TABLE status_catalog; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.status_catalog IS 'Global registry of all valid status values. Reference only — document tables store status as varchar, not as FK. See docs/workflow/status-lifecycle.md.';


--
-- Name: COLUMN status_catalog.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.status_catalog.code IS 'Snake_case status code, e.g. draft, submitted, under_review. Globally unique.';


--
-- Name: COLUMN status_catalog.color_class; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.status_catalog.color_class IS 'Tailwind CSS class string for UI badges, e.g. bg-yellow-100 text-yellow-800.';


--
-- Name: COLUMN status_catalog.applicable_modules; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.status_catalog.applicable_modules IS 'JSON array of module slugs this status applies to. NULL means applicable to all modules.';


--
-- Name: COLUMN status_catalog.is_terminal; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.status_catalog.is_terminal IS 'If true, no further status transition is allowed from this state (rejected, cancelled, archived, completed).';


--
-- Name: stock_ledger; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.stock_ledger (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    product_id uuid NOT NULL,
    movement_type character varying(20) NOT NULL,
    qty integer NOT NULL,
    reference_type character varying(20),
    reference_id uuid,
    reference_no character varying(50),
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    location_detail text,
    last_count_date date,
    CONSTRAINT stock_ledger_movement_type_check CHECK (((movement_type)::text = ANY ((ARRAY['inbound'::character varying, 'outbound'::character varying, 'adjustment'::character varying, 'reserved'::character varying, 'unreserved'::character varying, 'transfer_in'::character varying, 'transfer_out'::character varying])::text[])))
);


ALTER TABLE public.stock_ledger OWNER TO postgres;

--
-- Name: stock_summary; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.stock_summary WITH (security_invoker='true') AS
 SELECT product_id,
    warehouse_id,
    company_id,
    sum(qty) FILTER (WHERE ((movement_type)::text = ANY ((ARRAY['inbound'::character varying, 'outbound'::character varying, 'adjustment'::character varying, 'transfer_in'::character varying, 'transfer_out'::character varying])::text[]))) AS on_hand,
    (sum(
        CASE
            WHEN ((movement_type)::text = 'reserved'::text) THEN abs(qty)
            ELSE 0
        END) - sum(
        CASE
            WHEN ((movement_type)::text = 'unreserved'::text) THEN abs(qty)
            ELSE 0
        END)) AS reserved,
    (sum(qty) FILTER (WHERE ((movement_type)::text = ANY ((ARRAY['inbound'::character varying, 'outbound'::character varying, 'adjustment'::character varying, 'transfer_in'::character varying, 'transfer_out'::character varying])::text[]))) - (sum(
        CASE
            WHEN ((movement_type)::text = 'reserved'::text) THEN abs(qty)
            ELSE 0
        END) - sum(
        CASE
            WHEN ((movement_type)::text = 'unreserved'::text) THEN abs(qty)
            ELSE 0
        END))) AS available,
    max(last_count_date) AS last_count_date
   FROM public.stock_ledger
  GROUP BY product_id, warehouse_id, company_id;


ALTER VIEW public.stock_summary OWNER TO postgres;

--
-- Name: taxes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.taxes (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    rate numeric(7,4) NOT NULL,
    tax_type character varying(30) DEFAULT 'percentage'::character varying NOT NULL,
    is_inclusive boolean DEFAULT false NOT NULL,
    gl_account_id uuid,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT taxes_rate_check CHECK ((rate >= (0)::numeric)),
    CONSTRAINT taxes_tax_type_check CHECK (((tax_type)::text = ANY ((ARRAY['percentage'::character varying, 'fixed'::character varying])::text[])))
);


ALTER TABLE public.taxes OWNER TO postgres;

--
-- Name: TABLE taxes; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.taxes IS 'Company-scoped tax code registry. Indonesian context: PPN (VAT), PPh23, PPh21. Never modify rate on a code used in posted transactions — deactivate and create new instead.';


--
-- Name: COLUMN taxes.rate; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.taxes.rate IS 'Tax rate as a percentage value: 11.0000 = 11%. For fixed type, this is the fixed amount per unit.';


--
-- Name: COLUMN taxes.is_inclusive; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.taxes.is_inclusive IS 'True = tax is already included in the price (tax-inclusive). False = tax is added on top of the base price.';


--
-- Name: COLUMN taxes.gl_account_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.taxes.gl_account_id IS 'Nullable FK to chart_of_accounts. Set during Phase 3 when COA is configured.';


--
-- Name: top_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.top_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    account_id uuid,
    nama_perusahaan text,
    alamat_kantor text,
    alamat_gudang text,
    telepon text,
    email text,
    website text,
    npwp text,
    nib text,
    direktur_nama text,
    direktur_ktp text,
    status_pkp text,
    industri text,
    tahun_berdiri text,
    jumlah_karyawan text,
    revenue_tahunan text,
    produk_utama text,
    customer_utama text,
    supplier_utama text,
    volume_bulanan text,
    total_aset numeric(18,2),
    total_liabilities numeric(18,2),
    annual_revenue numeric(18,2),
    net_profit_margin text,
    laporan_keuangan text,
    outstanding_hutang text,
    bank_1_nama text,
    bank_1_rekening text,
    bank_1_cabang text,
    bank_1_contact text,
    bank_2_nama text,
    bank_2_rekening text,
    bank_2_cabang text,
    bank_2_contact text,
    trade_ref_1 text,
    trade_ref_2 text,
    trade_ref_3 text,
    top_requested text,
    credit_limit_diminta numeric(18,2),
    service_type text,
    estimasi_volume text,
    alasan_top text,
    pefindo_score text,
    bank_ref_verified text,
    trade_ref_verified text,
    credit_limit_approved numeric(18,2),
    top_approved text,
    effective_date date,
    review_date date,
    catatan text,
    status text DEFAULT 'draft'::text,
    submitted_at timestamp with time zone,
    approved_by uuid,
    approved_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT top_requests_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'submitted'::text, 'approved'::text, 'rejected'::text])))
);


ALTER TABLE public.top_requests OWNER TO postgres;

--
-- Name: user_login_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_login_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    session_id uuid,
    logged_in_at timestamp with time zone DEFAULT now() NOT NULL,
    ip text,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.user_login_logs OWNER TO postgres;

--
-- Name: user_menu_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_menu_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    menu_action_id uuid,
    is_cross_entity boolean DEFAULT false,
    company_id uuid,
    granted_by uuid,
    granted_at timestamp with time zone DEFAULT now(),
    module_action_id uuid,
    effect text DEFAULT 'grant'::text NOT NULL,
    CONSTRAINT ump_one_action_required CHECK ((((module_action_id IS NOT NULL) AND (menu_action_id IS NULL)) OR ((module_action_id IS NULL) AND (menu_action_id IS NOT NULL)))),
    CONSTRAINT user_menu_permissions_effect_check CHECK ((effect = ANY (ARRAY['grant'::text, 'deny'::text])))
);


ALTER TABLE public.user_menu_permissions OWNER TO postgres;

--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_roles (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL,
    company_id uuid NOT NULL,
    valid_from date,
    valid_until date,
    is_active boolean DEFAULT true NOT NULL,
    granted_by uuid,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_by uuid,
    revoked_at timestamp with time zone
);


ALTER TABLE public.user_roles OWNER TO postgres;

--
-- Name: TABLE user_roles; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.user_roles IS 'User-to-role assignments. A user may have multiple roles within one company. valid_from/until enables time-bound grants.';


--
-- Name: COLUMN user_roles.valid_until; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_roles.valid_until IS 'NULL = no expiry. If set, role should be checked against current date at permission evaluation.';


--
-- Name: COLUMN user_roles.is_active; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_roles.is_active IS 'False = role revoked. Row is kept for audit history.';


--
-- Name: vendors; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.vendors (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    legal_name character varying(200),
    vendor_type character varying(50),
    tax_id character varying(50),
    address text,
    city character varying(100),
    country character varying(100) DEFAULT 'Indonesia'::character varying,
    phone character varying(50),
    email character varying(100),
    pic_name character varying(100),
    pic_phone character varying(50),
    bank_name character varying(100),
    bank_account character varying(50),
    bank_account_name character varying(100),
    payment_terms_id uuid,
    currency_code character varying(3) DEFAULT 'IDR'::character varying,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.vendors OWNER TO postgres;

--
-- Name: TABLE vendors; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.vendors IS 'Company-scoped vendor master. Covers suppliers, shipping lines, truckers, customs agents, and sub-contractors.';


--
-- Name: COLUMN vendors.code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vendors.code IS 'Vendor code, unique per company. e.g. VND-0001.';


--
-- Name: COLUMN vendors.vendor_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vendors.vendor_type IS 'Classification: Shipping Line, Trucker, Customs Agent, Supplier, Sub-contractor, General.';


--
-- Name: COLUMN vendors.bank_account; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vendors.bank_account IS 'SENSITIVE: Display only last 4 digits to non-Finance roles. Full value stored for AP payment processing.';


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.warehouses (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    company_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(100) NOT NULL,
    city character varying(100),
    address text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.warehouses OWNER TO postgres;

--
-- Name: weekly_meeting_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.weekly_meeting_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    weekly_meeting_id uuid NOT NULL,
    source_type character varying(20) NOT NULL,
    daily_report_item_id uuid,
    bnf_report_id uuid,
    catatan_meeting text,
    action_plan text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT weekly_meeting_items_source_type_check CHECK (((source_type)::text = ANY ((ARRAY['task_pending'::character varying, 'insiden_resolved'::character varying, 'bnf_report'::character varying])::text[])))
);


ALTER TABLE public.weekly_meeting_items OWNER TO postgres;

--
-- Name: weekly_meetings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.weekly_meetings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    department_id uuid NOT NULL,
    week_start_date date NOT NULL,
    meeting_date date,
    peserta text,
    keterangan text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.weekly_meetings OWNER TO postgres;

--
-- Name: account_lifecycle_history account_lifecycle_history_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_lifecycle_history
    ADD CONSTRAINT account_lifecycle_history_pkey PRIMARY KEY (id);


--
-- Name: activities activities_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_pkey PRIMARY KEY (id);


--
-- Name: activity_logs activity_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_logs
    ADD CONSTRAINT activity_logs_pkey PRIMARY KEY (id);


--
-- Name: app_settings app_settings_company_id_category_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_company_id_category_key_key UNIQUE (company_id, category, key);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (id);


--
-- Name: approval_delegations approval_delegations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_delegations
    ADD CONSTRAINT approval_delegations_pkey PRIMARY KEY (id);


--
-- Name: approval_logs approval_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_logs
    ADD CONSTRAINT approval_logs_pkey PRIMARY KEY (id);


--
-- Name: approval_rules approval_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_pkey PRIMARY KEY (id);


--
-- Name: approval_workflow_steps approval_workflow_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflow_steps
    ADD CONSTRAINT approval_workflow_steps_pkey PRIMARY KEY (id);


--
-- Name: approval_workflow_steps approval_workflow_steps_workflow_id_step_order_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflow_steps
    ADD CONSTRAINT approval_workflow_steps_workflow_id_step_order_key UNIQUE (workflow_id, step_order);


--
-- Name: approval_workflows approval_workflows_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflows
    ADD CONSTRAINT approval_workflows_pkey PRIMARY KEY (id);


--
-- Name: ar_btbs ar_btbs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_btbs
    ADD CONSTRAINT ar_btbs_pkey PRIMARY KEY (id);


--
-- Name: ar_ttfs ar_ttfs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_ttfs
    ADD CONSTRAINT ar_ttfs_pkey PRIMARY KEY (id);


--
-- Name: asset_categories asset_categories_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_categories
    ADD CONSTRAINT asset_categories_company_code_unique UNIQUE (company_id, code);


--
-- Name: asset_categories asset_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_categories
    ADD CONSTRAINT asset_categories_pkey PRIMARY KEY (id);


--
-- Name: asset_fuel_logs asset_fuel_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_fuel_logs
    ADD CONSTRAINT asset_fuel_logs_pkey PRIMARY KEY (id);


--
-- Name: asset_locations asset_locations_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_locations
    ADD CONSTRAINT asset_locations_company_code_unique UNIQUE (company_id, code);


--
-- Name: asset_locations asset_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_locations
    ADD CONSTRAINT asset_locations_pkey PRIMARY KEY (id);


--
-- Name: asset_maintenance_records asset_maintenance_records_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_maintenance_records
    ADD CONSTRAINT asset_maintenance_records_pkey PRIMARY KEY (id);


--
-- Name: asset_network asset_network_asset_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_network
    ADD CONSTRAINT asset_network_asset_unique UNIQUE (asset_id);


--
-- Name: asset_network asset_network_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_network
    ADD CONSTRAINT asset_network_pkey PRIMARY KEY (id);


--
-- Name: asset_software_licenses asset_software_licenses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_software_licenses
    ADD CONSTRAINT asset_software_licenses_pkey PRIMARY KEY (id);


--
-- Name: asset_specifications asset_specifications_asset_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_specifications
    ADD CONSTRAINT asset_specifications_asset_unique UNIQUE (asset_id);


--
-- Name: asset_specifications asset_specifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_specifications
    ADD CONSTRAINT asset_specifications_pkey PRIMARY KEY (id);


--
-- Name: assets assets_company_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_company_no_unique UNIQUE (company_id, asset_no);


--
-- Name: assets assets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: bnf_authorized_users bnf_authorized_users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_authorized_users
    ADD CONSTRAINT bnf_authorized_users_pkey PRIMARY KEY (id);


--
-- Name: bnf_department_scopes bnf_department_scopes_department_id_company_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_department_scopes
    ADD CONSTRAINT bnf_department_scopes_department_id_company_id_key UNIQUE (department_id, company_id);


--
-- Name: bnf_department_scopes bnf_department_scopes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_department_scopes
    ADD CONSTRAINT bnf_department_scopes_pkey PRIMARY KEY (id);


--
-- Name: bnf_departments bnf_departments_division_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_departments
    ADD CONSTRAINT bnf_departments_division_code_unique UNIQUE (division_id, code);


--
-- Name: bnf_departments bnf_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_departments
    ADD CONSTRAINT bnf_departments_pkey PRIMARY KEY (id);


--
-- Name: bnf_division_scopes bnf_division_scopes_division_id_company_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_division_scopes
    ADD CONSTRAINT bnf_division_scopes_division_id_company_id_key UNIQUE (division_id, company_id);


--
-- Name: bnf_division_scopes bnf_division_scopes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_division_scopes
    ADD CONSTRAINT bnf_division_scopes_pkey PRIMARY KEY (id);


--
-- Name: bnf_divisions bnf_divisions_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_divisions
    ADD CONSTRAINT bnf_divisions_company_code_unique UNIQUE (company_id, code);


--
-- Name: bnf_divisions bnf_divisions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_divisions
    ADD CONSTRAINT bnf_divisions_pkey PRIMARY KEY (id);


--
-- Name: bnf_report_action_items bnf_report_action_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_action_items
    ADD CONSTRAINT bnf_report_action_items_pkey PRIMARY KEY (id);


--
-- Name: bnf_report_logs bnf_report_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_logs
    ADD CONSTRAINT bnf_report_logs_pkey PRIMARY KEY (id);


--
-- Name: bnf_report_related_departments bnf_report_related_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_related_departments
    ADD CONSTRAINT bnf_report_related_departments_pkey PRIMARY KEY (id);


--
-- Name: bnf_report_related_departments bnf_report_related_departments_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_related_departments
    ADD CONSTRAINT bnf_report_related_departments_unique UNIQUE (report_id, department_id);


--
-- Name: bnf_reports bnf_reports_company_report_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_company_report_no_unique UNIQUE (company_id, report_no);


--
-- Name: bnf_reports bnf_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_pkey PRIMARY KEY (id);


--
-- Name: branches branches_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_company_code_unique UNIQUE (company_id, code);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: channel_types channel_types_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.channel_types
    ADD CONSTRAINT channel_types_pkey PRIMARY KEY (id);


--
-- Name: chart_of_accounts chart_of_accounts_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_company_code_unique UNIQUE (company_id, code);


--
-- Name: chart_of_accounts chart_of_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_pkey PRIMARY KEY (id);


--
-- Name: code_counters code_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.code_counters
    ADD CONSTRAINT code_counters_pkey PRIMARY KEY (entity, year);


--
-- Name: companies companies_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_code_unique UNIQUE (code);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: cost_centers cost_centers_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_company_code_unique UNIQUE (company_id, code);


--
-- Name: cost_centers cost_centers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_pkey PRIMARY KEY (id);


--
-- Name: currencies currencies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.currencies
    ADD CONSTRAINT currencies_pkey PRIMARY KEY (code);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: daily_report_items daily_report_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_pkey PRIMARY KEY (id);


--
-- Name: dc_master dc_master_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dc_master
    ADD CONSTRAINT dc_master_pkey PRIMARY KEY (id);


--
-- Name: deal_handovers deal_handovers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_pkey PRIMARY KEY (id);


--
-- Name: delivery_incidents delivery_incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_incidents
    ADD CONSTRAINT delivery_incidents_pkey PRIMARY KEY (id);


--
-- Name: delivery_note_items delivery_note_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_pkey PRIMARY KEY (id);


--
-- Name: delivery_notes delivery_notes_do_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_do_no_key UNIQUE (do_no);


--
-- Name: delivery_notes delivery_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_pkey PRIMARY KEY (id);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: document_numbering document_numbering_company_id_document_type_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_numbering
    ADD CONSTRAINT document_numbering_company_id_document_type_key UNIQUE (company_id, document_type);


--
-- Name: document_numbering document_numbering_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_numbering
    ADD CONSTRAINT document_numbering_pkey PRIMARY KEY (id);


--
-- Name: document_sequences document_sequences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_sequences
    ADD CONSTRAINT document_sequences_pkey PRIMARY KEY (id);


--
-- Name: document_sequences document_sequences_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_sequences
    ADD CONSTRAINT document_sequences_unique UNIQUE (company_id, document_type, department_code, year, month, day);


--
-- Name: document_templates document_templates_company_id_document_type_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_templates
    ADD CONSTRAINT document_templates_company_id_document_type_key UNIQUE (company_id, document_type);


--
-- Name: document_templates document_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_templates
    ADD CONSTRAINT document_templates_pkey PRIMARY KEY (id);


--
-- Name: document_types document_types_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_company_code_unique UNIQUE (company_id, code);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (id);


--
-- Name: dropdown_options dropdown_options_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dropdown_options
    ADD CONSTRAINT dropdown_options_pkey PRIMARY KEY (id);


--
-- Name: entity_bank_accounts entity_bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_bank_accounts
    ADD CONSTRAINT entity_bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: entity_finance_settings entity_finance_settings_company_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_finance_settings
    ADD CONSTRAINT entity_finance_settings_company_id_key UNIQUE (company_id);


--
-- Name: entity_finance_settings entity_finance_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_finance_settings
    ADD CONSTRAINT entity_finance_settings_pkey PRIMARY KEY (id);


--
-- Name: entity_signatories entity_signatories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_signatories
    ADD CONSTRAINT entity_signatories_pkey PRIMARY KEY (id);


--
-- Name: exchange_rates exchange_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_pkey PRIMARY KEY (id);


--
-- Name: exchange_rates exchange_rates_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_unique UNIQUE (company_id, from_currency, to_currency, effective_date);


--
-- Name: hrga_approval_configs hrga_approval_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_approval_configs
    ADD CONSTRAINT hrga_approval_configs_pkey PRIMARY KEY (id);


--
-- Name: hrga_approval_configs hrga_approval_configs_type_level_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_approval_configs
    ADD CONSTRAINT hrga_approval_configs_type_level_unique UNIQUE (request_type_id, level);


--
-- Name: hrga_notification_queue hrga_notification_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_notification_queue
    ADD CONSTRAINT hrga_notification_queue_pkey PRIMARY KEY (id);


--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_checklists
    ADD CONSTRAINT hrga_offboarding_checklists_pkey PRIMARY KEY (id);


--
-- Name: hrga_offboarding_items hrga_offboarding_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_items
    ADD CONSTRAINT hrga_offboarding_items_pkey PRIMARY KEY (id);


--
-- Name: hrga_request_approvals hrga_request_approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_approvals
    ADD CONSTRAINT hrga_request_approvals_pkey PRIMARY KEY (id);


--
-- Name: hrga_request_attachments hrga_request_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_attachments
    ADD CONSTRAINT hrga_request_attachments_pkey PRIMARY KEY (id);


--
-- Name: hrga_request_items hrga_request_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_items
    ADD CONSTRAINT hrga_request_items_pkey PRIMARY KEY (id);


--
-- Name: hrga_request_types hrga_request_types_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_types
    ADD CONSTRAINT hrga_request_types_company_code_unique UNIQUE (company_id, type_code);


--
-- Name: hrga_request_types hrga_request_types_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_types
    ADD CONSTRAINT hrga_request_types_pkey PRIMARY KEY (id);


--
-- Name: hrga_requests hrga_requests_document_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_document_no_unique UNIQUE (company_id, document_no);


--
-- Name: hrga_requests hrga_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_pkey PRIMARY KEY (id);


--
-- Name: inquiries inquiries_inquiry_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_inquiry_no_key UNIQUE (inquiry_no);


--
-- Name: inquiries inquiries_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_pkey PRIMARY KEY (id);


--
-- Name: inquiry_comment_mentions inquiry_comment_mentions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comment_mentions
    ADD CONSTRAINT inquiry_comment_mentions_pkey PRIMARY KEY (id);


--
-- Name: inquiry_comments inquiry_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comments
    ADD CONSTRAINT inquiry_comments_pkey PRIMARY KEY (id);


--
-- Name: inquiry_status_history inquiry_status_history_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_status_history
    ADD CONSTRAINT inquiry_status_history_pkey PRIMARY KEY (id);


--
-- Name: journal_entries journal_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_pkey PRIMARY KEY (id);


--
-- Name: journal_entry_lines journal_entry_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_pkey PRIMARY KEY (id);


--
-- Name: loss_reasons loss_reasons_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loss_reasons
    ADD CONSTRAINT loss_reasons_pkey PRIMARY KEY (id);


--
-- Name: meeting_moms meeting_moms_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.meeting_moms
    ADD CONSTRAINT meeting_moms_pkey PRIMARY KEY (id);


--
-- Name: menu_actions menu_actions_menu_id_action_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu_actions
    ADD CONSTRAINT menu_actions_menu_id_action_key UNIQUE (menu_id, action);


--
-- Name: menu_actions menu_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu_actions
    ADD CONSTRAINT menu_actions_pkey PRIMARY KEY (id);


--
-- Name: module_actions module_actions_module_id_action_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.module_actions
    ADD CONSTRAINT module_actions_module_id_action_key UNIQUE (module_id, action);


--
-- Name: module_actions module_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.module_actions
    ADD CONSTRAINT module_actions_pkey PRIMARY KEY (id);


--
-- Name: module_menus module_menus_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.module_menus
    ADD CONSTRAINT module_menus_key_key UNIQUE (key);


--
-- Name: module_menus module_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.module_menus
    ADD CONSTRAINT module_menus_pkey PRIMARY KEY (id);


--
-- Name: modules modules_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_key_key UNIQUE (key);


--
-- Name: modules modules_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_pkey PRIMARY KEY (id);


--
-- Name: mom_action_plans mom_action_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_action_plans
    ADD CONSTRAINT mom_action_plans_pkey PRIMARY KEY (id);


--
-- Name: mom_improvements mom_improvements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_improvements
    ADD CONSTRAINT mom_improvements_pkey PRIMARY KEY (id);


--
-- Name: mom_issues mom_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_issues
    ADD CONSTRAINT mom_issues_pkey PRIMARY KEY (id);


--
-- Name: mom_progress_updates mom_progress_updates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_progress_updates
    ADD CONSTRAINT mom_progress_updates_pkey PRIMARY KEY (id);


--
-- Name: notification_rules notification_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: payment_terms payment_terms_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_terms
    ADD CONSTRAINT payment_terms_company_code_unique UNIQUE (company_id, code);


--
-- Name: payment_terms payment_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_terms
    ADD CONSTRAINT payment_terms_pkey PRIMARY KEY (id);


--
-- Name: permissions permissions_module_action_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_module_action_unique UNIQUE (module, action);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: picking_list_items picking_list_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_items
    ADD CONSTRAINT picking_list_items_pkey PRIMARY KEY (id);


--
-- Name: picking_list_materials picking_list_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_materials
    ADD CONSTRAINT picking_list_materials_pkey PRIMARY KEY (id);


--
-- Name: picking_lists picking_lists_picking_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_picking_no_key UNIQUE (picking_no);


--
-- Name: picking_lists picking_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_pkey PRIMARY KEY (id);


--
-- Name: positions positions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_pkey PRIMARY KEY (id);


--
-- Name: prf_cost_items prf_cost_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_cost_items
    ADD CONSTRAINT prf_cost_items_pkey PRIMARY KEY (id);


--
-- Name: prf prf_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_no_unique UNIQUE (company_id, prf_no);


--
-- Name: prf prf_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_pkey PRIMARY KEY (id);


--
-- Name: prf_vendor_offers prf_vendor_offers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_vendor_offers
    ADD CONSTRAINT prf_vendor_offers_pkey PRIMARY KEY (id);


--
-- Name: product_price_history product_price_history_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_price_history
    ADD CONSTRAINT product_price_history_pkey PRIMARY KEY (id);


--
-- Name: product_warehouse_location product_warehouse_location_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_warehouse_location
    ADD CONSTRAINT product_warehouse_location_pkey PRIMARY KEY (id);


--
-- Name: products products_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_company_code_unique UNIQUE (company_id, code);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: accounts prospects_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_pkey PRIMARY KEY (id);


--
-- Name: product_warehouse_location pwl_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_warehouse_location
    ADD CONSTRAINT pwl_uniq UNIQUE (product_id, warehouse_id);


--
-- Name: quotation_items quotation_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotation_items
    ADD CONSTRAINT quotation_items_pkey PRIMARY KEY (id);


--
-- Name: quotations quotations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_pkey PRIMARY KEY (id);


--
-- Name: quotations quotations_quotation_no_revision_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_quotation_no_revision_key UNIQUE (quotation_no, revision);


--
-- Name: rate_sheets rate_sheets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rate_sheets
    ADD CONSTRAINT rate_sheets_pkey PRIMARY KEY (id);


--
-- Name: role_menu_permissions role_menu_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_menu_permissions
    ADD CONSTRAINT role_menu_permissions_pkey PRIMARY KEY (id);


--
-- Name: role_permission_templates role_permission_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permission_templates
    ADD CONSTRAINT role_permission_templates_pkey PRIMARY KEY (id);


--
-- Name: role_permission_templates role_permission_templates_role_id_menu_action_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permission_templates
    ADD CONSTRAINT role_permission_templates_role_id_menu_action_id_key UNIQUE (role_id, menu_action_id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_unique UNIQUE (role_id, permission_id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: sales_calls sales_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_calls
    ADD CONSTRAINT sales_calls_pkey PRIMARY KEY (id);


--
-- Name: sales_orders sales_orders_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_no_unique UNIQUE (company_id, so_no);


--
-- Name: sales_orders sales_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_pkey PRIMARY KEY (id);


--
-- Name: sales_visit_logs sales_visit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visit_logs
    ADD CONSTRAINT sales_visit_logs_pkey PRIMARY KEY (id);


--
-- Name: sales_visits sales_visits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visits
    ADD CONSTRAINT sales_visits_pkey PRIMARY KEY (id);


--
-- Name: sla_policies sla_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_pkey PRIMARY KEY (id);


--
-- Name: sp_btb sp_btb_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_btb
    ADD CONSTRAINT sp_btb_pkey PRIMARY KEY (id);


--
-- Name: sp_btbs sp_btbs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_btbs
    ADD CONSTRAINT sp_btbs_pkey PRIMARY KEY (id);


--
-- Name: sp_invoice_lines sp_invoice_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoice_lines
    ADD CONSTRAINT sp_invoice_lines_pkey PRIMARY KEY (id);


--
-- Name: sp_invoices sp_invoice_one_per_sp; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoices
    ADD CONSTRAINT sp_invoice_one_per_sp UNIQUE (sp_order_id);


--
-- Name: sp_invoices sp_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoices
    ADD CONSTRAINT sp_invoices_pkey PRIMARY KEY (id);


--
-- Name: sp_items sp_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_items
    ADD CONSTRAINT sp_items_pkey PRIMARY KEY (id);


--
-- Name: sp_order_items sp_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_order_items
    ADD CONSTRAINT sp_order_items_pkey PRIMARY KEY (id);


--
-- Name: sp_orders sp_orders_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_orders
    ADD CONSTRAINT sp_orders_no_unique UNIQUE (customer_id, sp_no);


--
-- Name: sp_orders sp_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_orders
    ADD CONSTRAINT sp_orders_pkey PRIMARY KEY (id);


--
-- Name: sp_payments sp_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_payments
    ADD CONSTRAINT sp_payments_pkey PRIMARY KEY (id);


--
-- Name: status_catalog status_catalog_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.status_catalog
    ADD CONSTRAINT status_catalog_code_unique UNIQUE (code);


--
-- Name: status_catalog status_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.status_catalog
    ADD CONSTRAINT status_catalog_pkey PRIMARY KEY (id);


--
-- Name: stock_ledger stock_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_ledger
    ADD CONSTRAINT stock_ledger_pkey PRIMARY KEY (id);


--
-- Name: taxes taxes_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT taxes_company_code_unique UNIQUE (company_id, code);


--
-- Name: taxes taxes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT taxes_pkey PRIMARY KEY (id);


--
-- Name: top_requests top_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.top_requests
    ADD CONSTRAINT top_requests_pkey PRIMARY KEY (id);


--
-- Name: user_login_logs user_login_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login_logs
    ADD CONSTRAINT user_login_logs_pkey PRIMARY KEY (id);


--
-- Name: user_menu_permissions user_menu_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_pkey PRIMARY KEY (id);


--
-- Name: user_menu_permissions user_menu_permissions_user_id_menu_action_id_company_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_user_id_menu_action_id_company_id_key UNIQUE (user_id, menu_action_id, company_id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_unique UNIQUE (user_id, role_id, company_id);


--
-- Name: vendors vendors_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_company_code_unique UNIQUE (company_id, code);


--
-- Name: vendors vendors_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_pkey PRIMARY KEY (id);


--
-- Name: warehouses warehouses_company_code_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_company_code_unique UNIQUE (company_id, code);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);


--
-- Name: weekly_meeting_items weekly_meeting_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meeting_items
    ADD CONSTRAINT weekly_meeting_items_pkey PRIMARY KEY (id);


--
-- Name: weekly_meetings weekly_meetings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meetings
    ADD CONSTRAINT weekly_meetings_pkey PRIMARY KEY (id);


--
-- Name: accounts_code_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX accounts_code_unique ON public.accounts USING btree (code) WHERE (code IS NOT NULL);


--
-- Name: channel_types_company_code_line_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX channel_types_company_code_line_uidx ON public.channel_types USING btree (company_id, code, COALESCE(service_line, '__ALL__'::character varying)) WHERE (deleted_at IS NULL);


--
-- Name: departments_company_code_active_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX departments_company_code_active_uidx ON public.departments USING btree (COALESCE(company_id, '00000000-0000-0000-0000-000000000000'::uuid), code) WHERE (deleted_at IS NULL);


--
-- Name: dropdown_options_entity_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX dropdown_options_entity_unique ON public.dropdown_options USING btree (company_id, list_key, value) WHERE (company_id IS NOT NULL);


--
-- Name: dropdown_options_global_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX dropdown_options_global_unique ON public.dropdown_options USING btree (list_key, value) WHERE (company_id IS NULL);


--
-- Name: idx_activities_account; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_account ON public.activities USING btree (account_id);


--
-- Name: idx_activities_assigned; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_assigned ON public.activities USING btree (assigned_to);


--
-- Name: idx_activities_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_company ON public.activities USING btree (company_id);


--
-- Name: idx_activities_contact; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_contact ON public.activities USING btree (contact_id);


--
-- Name: idx_activities_sched; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_sched ON public.activities USING btree (scheduled_for);


--
-- Name: idx_activities_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_status ON public.activities USING btree (status);


--
-- Name: idx_activities_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activities_type ON public.activities USING btree (type);


--
-- Name: idx_activity_logs_activity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_logs_activity ON public.activity_logs USING btree (activity_id);


--
-- Name: idx_alh_account_changed; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_alh_account_changed ON public.account_lifecycle_history USING btree (account_id, changed_at DESC);


--
-- Name: idx_app_settings_category; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_app_settings_category ON public.app_settings USING btree (category, key);


--
-- Name: idx_app_settings_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_app_settings_company ON public.app_settings USING btree (company_id);


--
-- Name: idx_approval_delegations_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_delegations_company_id ON public.approval_delegations USING btree (company_id);


--
-- Name: idx_approval_delegations_delegate; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_delegations_delegate ON public.approval_delegations USING btree (delegate_id, valid_from, valid_until) WHERE (is_active = true);


--
-- Name: idx_approval_delegations_delegator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_delegations_delegator ON public.approval_delegations USING btree (delegator_id);


--
-- Name: idx_approval_logs_acted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_logs_acted_at ON public.approval_logs USING btree (company_id, acted_at DESC);


--
-- Name: idx_approval_logs_actor_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_logs_actor_id ON public.approval_logs USING btree (actor_id);


--
-- Name: idx_approval_logs_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_logs_company_id ON public.approval_logs USING btree (company_id);


--
-- Name: idx_approval_logs_document; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_logs_document ON public.approval_logs USING btree (company_id, document_type, document_id);


--
-- Name: idx_approval_rules_company_doctype; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_rules_company_doctype ON public.approval_rules USING btree (company_id, document_type) WHERE (is_active = true);


--
-- Name: idx_approval_rules_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_approval_rules_company_id ON public.approval_rules USING btree (company_id);


--
-- Name: idx_ar_btbs_ttf_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_btbs_ttf_id ON public.ar_btbs USING btree (ttf_id, "position");


--
-- Name: idx_ar_ttfs_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_ttfs_company_id ON public.ar_ttfs USING btree (company_id);


--
-- Name: idx_ar_ttfs_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_ttfs_customer_id ON public.ar_ttfs USING btree (customer_id);


--
-- Name: idx_ar_ttfs_invoice_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_ttfs_invoice_id ON public.ar_ttfs USING btree (invoice_id);


--
-- Name: idx_ar_ttfs_sp_order_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_ttfs_sp_order_id ON public.ar_ttfs USING btree (sp_order_id);


--
-- Name: idx_ar_ttfs_tanggal_ttf; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_ttfs_tanggal_ttf ON public.ar_ttfs USING btree (tanggal_ttf DESC NULLS LAST);


--
-- Name: idx_ar_ttfs_tgl_pembayaran; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ar_ttfs_tgl_pembayaran ON public.ar_ttfs USING btree (tgl_pembayaran);


--
-- Name: idx_asset_categories_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_categories_company_id ON public.asset_categories USING btree (company_id);


--
-- Name: idx_asset_categories_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_categories_deleted_at ON public.asset_categories USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_asset_fuel_logs_asset_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_fuel_logs_asset_id ON public.asset_fuel_logs USING btree (asset_id, fill_date DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_asset_fuel_logs_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_fuel_logs_company_id ON public.asset_fuel_logs USING btree (company_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_asset_locations_branch_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_locations_branch_id ON public.asset_locations USING btree (branch_id);


--
-- Name: idx_asset_locations_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_locations_company_id ON public.asset_locations USING btree (company_id);


--
-- Name: idx_asset_locations_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_locations_deleted_at ON public.asset_locations USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_asset_maintenance_asset_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_maintenance_asset_id ON public.asset_maintenance_records USING btree (asset_id, maintenance_date DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_asset_maintenance_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_maintenance_company_id ON public.asset_maintenance_records USING btree (company_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_asset_network_asset_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_network_asset_id ON public.asset_network USING btree (asset_id);


--
-- Name: idx_asset_network_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_network_company_id ON public.asset_network USING btree (company_id);


--
-- Name: idx_asset_software_asset_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_software_asset_id ON public.asset_software_licenses USING btree (asset_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_asset_software_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_software_company_id ON public.asset_software_licenses USING btree (company_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_asset_specifications_asset_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_specifications_asset_id ON public.asset_specifications USING btree (asset_id);


--
-- Name: idx_asset_specifications_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_asset_specifications_company_id ON public.asset_specifications USING btree (company_id);


--
-- Name: idx_assets_asset_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_assets_asset_code ON public.assets USING btree (company_id, asset_code) WHERE ((asset_code IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: idx_assets_asset_subtype; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assets_asset_subtype ON public.assets USING btree (company_id, asset_subtype) WHERE (deleted_at IS NULL);


--
-- Name: idx_assets_category_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assets_category_id ON public.assets USING btree (category_id);


--
-- Name: idx_assets_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assets_company_id ON public.assets USING btree (company_id);


--
-- Name: idx_assets_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assets_deleted_at ON public.assets USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_assets_plate_number; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assets_plate_number ON public.assets USING btree (company_id, plate_number) WHERE ((plate_number IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: idx_assets_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assets_status ON public.assets USING btree (company_id, status);


--
-- Name: idx_audit_logs_action; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_action ON public.audit_logs USING btree (action);


--
-- Name: idx_audit_logs_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_company ON public.audit_logs USING btree (company_id);


--
-- Name: idx_audit_logs_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_created_at ON public.audit_logs USING btree (created_at DESC);


--
-- Name: idx_audit_logs_entity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_entity ON public.audit_logs USING btree (entity_type, entity_id);


--
-- Name: idx_audit_logs_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_user_id ON public.audit_logs USING btree (user_id);


--
-- Name: idx_bank_accounts_default; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_bank_accounts_default ON public.entity_bank_accounts USING btree (company_id, currency) WHERE (is_default = true);


--
-- Name: idx_bnf_departments_division; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bnf_departments_division ON public.bnf_departments USING btree (division_id);


--
-- Name: idx_bnf_report_logs_report; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bnf_report_logs_report ON public.bnf_report_logs USING btree (report_id);


--
-- Name: idx_bnf_report_related_departments_report; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bnf_report_related_departments_report ON public.bnf_report_related_departments USING btree (report_id);


--
-- Name: idx_bnf_reports_company_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bnf_reports_company_status ON public.bnf_reports USING btree (company_id, status);


--
-- Name: idx_bnf_reports_created_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bnf_reports_created_by ON public.bnf_reports USING btree (created_by);


--
-- Name: idx_bnf_reports_division; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bnf_reports_division ON public.bnf_reports USING btree (division_id);


--
-- Name: idx_branches_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_branches_company_id ON public.branches USING btree (company_id);


--
-- Name: idx_branches_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_branches_deleted_at ON public.branches USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_coa_account_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_coa_account_type ON public.chart_of_accounts USING btree (company_id, account_type);


--
-- Name: idx_coa_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_coa_company_id ON public.chart_of_accounts USING btree (company_id);


--
-- Name: idx_coa_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_coa_deleted_at ON public.chart_of_accounts USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_coa_parent_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_coa_parent_id ON public.chart_of_accounts USING btree (parent_id) WHERE (parent_id IS NOT NULL);


--
-- Name: idx_companies_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_companies_code ON public.companies USING btree (code);


--
-- Name: idx_companies_is_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_is_active ON public.companies USING btree (is_active);


--
-- Name: idx_contacts_account; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contacts_account ON public.contacts USING btree (account_id);


--
-- Name: idx_contacts_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contacts_company ON public.contacts USING btree (company_id);


--
-- Name: idx_cost_centers_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cost_centers_company_id ON public.cost_centers USING btree (company_id);


--
-- Name: idx_cost_centers_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cost_centers_deleted_at ON public.cost_centers USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_customers_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customers_active ON public.customers USING btree (active);


--
-- Name: idx_customers_company_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customers_company_code ON public.customers USING btree (company_id, code) WHERE ((company_id IS NOT NULL) AND (code IS NOT NULL));


--
-- Name: idx_customers_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customers_company_id ON public.customers USING btree (company_id) WHERE (company_id IS NOT NULL);


--
-- Name: idx_customers_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customers_deleted_at ON public.customers USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_customers_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customers_name ON public.customers USING btree (name);


--
-- Name: idx_delivery_incidents_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_incidents_company ON public.delivery_incidents USING btree (company_id);


--
-- Name: idx_delivery_incidents_dn; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_incidents_dn ON public.delivery_incidents USING btree (delivery_note_id);


--
-- Name: idx_delivery_incidents_open; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_incidents_open ON public.delivery_incidents USING btree (status) WHERE (status = 'open'::text);


--
-- Name: idx_delivery_note_items_dn; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_note_items_dn ON public.delivery_note_items USING btree (delivery_note_id);


--
-- Name: idx_delivery_notes_picking; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_notes_picking ON public.delivery_notes USING btree (picking_list_id);


--
-- Name: idx_delivery_notes_sp_no; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_notes_sp_no ON public.delivery_notes USING btree (sp_no);


--
-- Name: idx_delivery_notes_sp_order; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_notes_sp_order ON public.delivery_notes USING btree (sp_order_id) WHERE (sp_order_id IS NOT NULL);


--
-- Name: idx_delivery_notes_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_delivery_notes_status ON public.delivery_notes USING btree (status);


--
-- Name: idx_departments_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_departments_company_id ON public.departments USING btree (company_id);


--
-- Name: idx_departments_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_departments_deleted_at ON public.departments USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_departments_parent_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_departments_parent_id ON public.departments USING btree (parent_id);


--
-- Name: idx_document_sequences_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_document_sequences_company_id ON public.document_sequences USING btree (company_id);


--
-- Name: idx_document_sequences_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_document_sequences_lookup ON public.document_sequences USING btree (company_id, document_type, department_code, year, month);


--
-- Name: idx_document_types_company_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_document_types_company_code ON public.document_types USING btree (company_id, code);


--
-- Name: idx_document_types_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_document_types_company_id ON public.document_types USING btree (company_id);


--
-- Name: idx_dropdown_options_group; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_dropdown_options_group ON public.dropdown_options USING btree (group_key);


--
-- Name: idx_dropdown_options_list; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_dropdown_options_list ON public.dropdown_options USING btree (list_key, is_active);


--
-- Name: idx_exchange_rates_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_exchange_rates_company_id ON public.exchange_rates USING btree (company_id);


--
-- Name: idx_exchange_rates_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_exchange_rates_lookup ON public.exchange_rates USING btree (company_id, from_currency, to_currency, effective_date DESC);


--
-- Name: idx_hrga_approval_configs_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_approval_configs_company ON public.hrga_approval_configs USING btree (company_id);


--
-- Name: idx_hrga_approval_configs_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_approval_configs_type ON public.hrga_approval_configs USING btree (request_type_id) WHERE (is_active = true);


--
-- Name: idx_hrga_notification_queue_pending; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_notification_queue_pending ON public.hrga_notification_queue USING btree (created_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: idx_hrga_notification_queue_request; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_notification_queue_request ON public.hrga_notification_queue USING btree (request_id);


--
-- Name: idx_hrga_offboarding_checklists_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_offboarding_checklists_company ON public.hrga_offboarding_checklists USING btree (company_id) WHERE ((deleted_at IS NULL) AND (is_active = true));


--
-- Name: idx_hrga_offboarding_items_request; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_offboarding_items_request ON public.hrga_offboarding_items USING btree (request_id);


--
-- Name: idx_hrga_request_approvals_approver; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_request_approvals_approver ON public.hrga_request_approvals USING btree (approver_id);


--
-- Name: idx_hrga_request_approvals_request; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_request_approvals_request ON public.hrga_request_approvals USING btree (request_id);


--
-- Name: idx_hrga_request_attachments_request; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_request_attachments_request ON public.hrga_request_attachments USING btree (request_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_request_items_request; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_request_items_request ON public.hrga_request_items USING btree (request_id);


--
-- Name: idx_hrga_request_types_category; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_request_types_category ON public.hrga_request_types USING btree (company_id, category_code) WHERE ((deleted_at IS NULL) AND (is_active = true));


--
-- Name: idx_hrga_request_types_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_request_types_company ON public.hrga_request_types USING btree (company_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_requests_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_requests_company ON public.hrga_requests USING btree (company_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_requests_company_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_requests_company_created ON public.hrga_requests USING btree (company_id, created_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_requests_company_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_requests_company_status ON public.hrga_requests USING btree (company_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_requests_current_level; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_requests_current_level ON public.hrga_requests USING btree (company_id, current_level, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_requests_requester; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_requests_requester ON public.hrga_requests USING btree (requester_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_hrga_requests_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_hrga_requests_type ON public.hrga_requests USING btree (request_type_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_inquiries_closed_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiries_closed_at ON public.inquiries USING btree (closed_at DESC) WHERE (closed_at IS NOT NULL);


--
-- Name: idx_inquiries_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiries_company_id ON public.inquiries USING btree (company_id);


--
-- Name: idx_inquiries_contact; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiries_contact ON public.inquiries USING btree (contact_id);


--
-- Name: idx_inquiries_owner_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiries_owner_id ON public.inquiries USING btree (owner_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_inquiries_prospect_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiries_prospect_id ON public.inquiries USING btree (prospect_id);


--
-- Name: idx_inquiry_comment_mentions_comment_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiry_comment_mentions_comment_id ON public.inquiry_comment_mentions USING btree (comment_id);


--
-- Name: idx_inquiry_comment_mentions_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiry_comment_mentions_user_id ON public.inquiry_comment_mentions USING btree (user_id);


--
-- Name: idx_inquiry_comments_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiry_comments_company_id ON public.inquiry_comments USING btree (company_id);


--
-- Name: idx_inquiry_comments_inquiry_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inquiry_comments_inquiry_id ON public.inquiry_comments USING btree (inquiry_id, created_at DESC);


--
-- Name: idx_ish_inquiry_changed; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ish_inquiry_changed ON public.inquiry_status_history USING btree (inquiry_id, changed_at DESC);


--
-- Name: idx_je_company_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_je_company_date ON public.journal_entries USING btree (company_id, entry_date);


--
-- Name: idx_je_reference; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_je_reference ON public.journal_entries USING btree (reference_type, reference_id);


--
-- Name: idx_jel_account; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_jel_account ON public.journal_entry_lines USING btree (account_id);


--
-- Name: idx_jel_entry; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_jel_entry ON public.journal_entry_lines USING btree (journal_entry_id);


--
-- Name: idx_meeting_moms_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_meeting_moms_company ON public.meeting_moms USING btree (company_id);


--
-- Name: idx_meeting_moms_created_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_meeting_moms_created_by ON public.meeting_moms USING btree (created_by);


--
-- Name: idx_meeting_moms_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_meeting_moms_status ON public.meeting_moms USING btree (status);


--
-- Name: idx_mom_action_plans_mom_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mom_action_plans_mom_id ON public.mom_action_plans USING btree (mom_id);


--
-- Name: idx_mom_improvements_mom_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mom_improvements_mom_id ON public.mom_improvements USING btree (mom_id);


--
-- Name: idx_mom_issues_mom_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mom_issues_mom_id ON public.mom_issues USING btree (mom_id);


--
-- Name: idx_mom_progress_updates_mom_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mom_progress_updates_mom_id ON public.mom_progress_updates USING btree (mom_id);


--
-- Name: idx_notifications_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_user_id ON public.notifications USING btree (user_id, is_read, created_at DESC);


--
-- Name: idx_payment_terms_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_payment_terms_company_id ON public.payment_terms USING btree (company_id);


--
-- Name: idx_payment_terms_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_payment_terms_deleted_at ON public.payment_terms USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_permissions_module; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_permissions_module ON public.permissions USING btree (module);


--
-- Name: idx_picking_list_items_pl; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_picking_list_items_pl ON public.picking_list_items USING btree (picking_list_id);


--
-- Name: idx_picking_lists_sp_no; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_picking_lists_sp_no ON public.picking_lists USING btree (sp_no);


--
-- Name: idx_picking_lists_sp_order; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_picking_lists_sp_order ON public.picking_lists USING btree (sp_order_id) WHERE (sp_order_id IS NOT NULL);


--
-- Name: idx_picking_lists_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_picking_lists_status ON public.picking_lists USING btree (status);


--
-- Name: idx_plm_picking; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_plm_picking ON public.picking_list_materials USING btree (picking_list_id);


--
-- Name: idx_positions_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_positions_company_id ON public.positions USING btree (company_id);


--
-- Name: idx_positions_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_positions_deleted_at ON public.positions USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_pph_product_changed; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pph_product_changed ON public.product_price_history USING btree (product_id, changed_at DESC);


--
-- Name: idx_prf_acknowledged_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_acknowledged_by ON public.prf USING btree (acknowledged_by) WHERE (acknowledged_by IS NOT NULL);


--
-- Name: idx_prf_cost_items_offer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_cost_items_offer ON public.prf_cost_items USING btree (offer_id);


--
-- Name: idx_prf_cost_items_prf_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_cost_items_prf_id ON public.prf_cost_items USING btree (prf_id);


--
-- Name: idx_prf_inquiry_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_inquiry_id ON public.prf USING btree (inquiry_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_prf_selected_offer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_selected_offer ON public.prf USING btree (selected_offer_id) WHERE (selected_offer_id IS NOT NULL);


--
-- Name: idx_prf_vendor_offers_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_vendor_offers_company ON public.prf_vendor_offers USING btree (company_id);


--
-- Name: idx_prf_vendor_offers_prf; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_vendor_offers_prf ON public.prf_vendor_offers USING btree (prf_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_prf_vendor_offers_vendor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prf_vendor_offers_vendor ON public.prf_vendor_offers USING btree (vendor_id);


--
-- Name: idx_products_company_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_products_company_code ON public.products USING btree (company_id, code);


--
-- Name: idx_products_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_products_company_id ON public.products USING btree (company_id);


--
-- Name: idx_products_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_products_deleted_at ON public.products USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_profiles_branch_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_profiles_branch_id ON public.profiles USING btree (branch_id) WHERE (branch_id IS NOT NULL);


--
-- Name: idx_profiles_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_profiles_company_id ON public.profiles USING btree (company_id) WHERE (company_id IS NOT NULL);


--
-- Name: idx_profiles_department_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_profiles_department_id ON public.profiles USING btree (department_id) WHERE (department_id IS NOT NULL);


--
-- Name: idx_profiles_reports_to; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_profiles_reports_to ON public.profiles USING btree (reports_to);


--
-- Name: idx_prospects_assigned_to; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_assigned_to ON public.accounts USING btree (assigned_to);


--
-- Name: idx_prospects_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_company_id ON public.accounts USING btree (company_id);


--
-- Name: idx_prospects_pipeline_stage; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_pipeline_stage ON public.accounts USING btree (pipeline_stage);


--
-- Name: idx_pwl_product; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pwl_product ON public.product_warehouse_location USING btree (product_id);


--
-- Name: idx_pwl_warehouse; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pwl_warehouse ON public.product_warehouse_location USING btree (warehouse_id);


--
-- Name: idx_quotations_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_quotations_company_id ON public.quotations USING btree (company_id);


--
-- Name: idx_quotations_prf_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_quotations_prf_id ON public.quotations USING btree (prf_id) WHERE (prf_id IS NOT NULL);


--
-- Name: idx_quotations_prospect_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_quotations_prospect_id ON public.quotations USING btree (prospect_id);


--
-- Name: idx_quotations_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_quotations_status ON public.quotations USING btree (status);


--
-- Name: idx_role_menu_permissions_menu_action_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_role_menu_permissions_menu_action_id ON public.role_menu_permissions USING btree (menu_action_id);


--
-- Name: idx_role_menu_permissions_module_action_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_role_menu_permissions_module_action_id ON public.role_menu_permissions USING btree (module_action_id);


--
-- Name: idx_role_menu_permissions_role_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_role_menu_permissions_role_id ON public.role_menu_permissions USING btree (role_id);


--
-- Name: idx_role_permissions_permission_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_role_permissions_permission_id ON public.role_permissions USING btree (permission_id);


--
-- Name: idx_role_permissions_role_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_role_permissions_role_id ON public.role_permissions USING btree (role_id);


--
-- Name: idx_roles_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_roles_company_id ON public.roles USING btree (company_id);


--
-- Name: idx_roles_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_roles_deleted_at ON public.roles USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_sales_orders_account_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sales_orders_account_id ON public.sales_orders USING btree (account_id);


--
-- Name: idx_sales_orders_company_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sales_orders_company_created ON public.sales_orders USING btree (company_id, created_at DESC);


--
-- Name: idx_sp_btb_sp_order_live; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sp_btb_sp_order_live ON public.sp_btb USING btree (sp_order_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_sp_items_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sp_items_customer_id ON public.sp_items USING btree (customer_id);


--
-- Name: idx_sp_items_product_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sp_items_product_id ON public.sp_items USING btree (product_id);


--
-- Name: idx_sp_items_sp_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sp_items_sp_date ON public.sp_items USING btree (sp_date DESC NULLS LAST);


--
-- Name: idx_sp_items_sp_no; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sp_items_sp_no ON public.sp_items USING btree (sp_no);


--
-- Name: idx_sp_orders_company_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sp_orders_company_status ON public.sp_orders USING btree (company_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_status_catalog_is_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_status_catalog_is_active ON public.status_catalog USING btree (is_active);


--
-- Name: idx_stock_ledger_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_stock_ledger_company ON public.stock_ledger USING btree (company_id);


--
-- Name: idx_stock_ledger_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_stock_ledger_created_at ON public.stock_ledger USING btree (created_at DESC);


--
-- Name: idx_stock_ledger_product; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_stock_ledger_product ON public.stock_ledger USING btree (product_id);


--
-- Name: idx_stock_ledger_warehouse; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_stock_ledger_warehouse ON public.stock_ledger USING btree (warehouse_id);


--
-- Name: idx_taxes_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_taxes_company_id ON public.taxes USING btree (company_id);


--
-- Name: idx_taxes_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_taxes_deleted_at ON public.taxes USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_user_login_logs_time; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_login_logs_time ON public.user_login_logs USING btree (logged_in_at DESC);


--
-- Name: idx_user_login_logs_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_login_logs_user ON public.user_login_logs USING btree (user_id);


--
-- Name: idx_user_roles_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_roles_company_id ON public.user_roles USING btree (company_id);


--
-- Name: idx_user_roles_role_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_roles_role_id ON public.user_roles USING btree (role_id);


--
-- Name: idx_user_roles_user_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_roles_user_company ON public.user_roles USING btree (user_id, company_id) WHERE (is_active = true);


--
-- Name: idx_user_roles_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_roles_user_id ON public.user_roles USING btree (user_id);


--
-- Name: idx_vendors_company_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_company_code ON public.vendors USING btree (company_id, code);


--
-- Name: idx_vendors_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_company_id ON public.vendors USING btree (company_id);


--
-- Name: idx_vendors_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_deleted_at ON public.vendors USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_vendors_is_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_is_active ON public.vendors USING btree (is_active);


--
-- Name: loss_reasons_code_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX loss_reasons_code_uidx ON public.loss_reasons USING btree (code) WHERE (deleted_at IS NULL);


--
-- Name: positions_company_code_active_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX positions_company_code_active_uidx ON public.positions USING btree (COALESCE(company_id, '00000000-0000-0000-0000-000000000000'::uuid), code) WHERE (deleted_at IS NULL);


--
-- Name: role_menu_permissions_role_menu_action_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX role_menu_permissions_role_menu_action_unique ON public.role_menu_permissions USING btree (role_id, menu_action_id) WHERE (menu_action_id IS NOT NULL);


--
-- Name: role_menu_permissions_role_module_action_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX role_menu_permissions_role_module_action_unique ON public.role_menu_permissions USING btree (role_id, module_action_id) WHERE (module_action_id IS NOT NULL);


--
-- Name: roles_company_code_active_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX roles_company_code_active_uidx ON public.roles USING btree (COALESCE(company_id, '00000000-0000-0000-0000-000000000000'::uuid), code) WHERE (deleted_at IS NULL);


--
-- Name: sales_orders_inquiry_unique_live; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX sales_orders_inquiry_unique_live ON public.sales_orders USING btree (inquiry_id) WHERE (deleted_at IS NULL);


--
-- Name: sla_policies_company_code_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX sla_policies_company_code_uidx ON public.sla_policies USING btree (company_id, code) WHERE (deleted_at IS NULL);


--
-- Name: sp_btb_no_unique_live; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX sp_btb_no_unique_live ON public.sp_btb USING btree (customer_id, btb_no) WHERE (deleted_at IS NULL);


--
-- Name: uq_accounts_norm_name_per_entitas; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_accounts_norm_name_per_entitas ON public.accounts USING btree (company_id, public.normalize_account_name(name)) WHERE (deleted_at IS NULL);


--
-- Name: uq_contacts_one_primary; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_contacts_one_primary ON public.contacts USING btree (account_id) WHERE (is_primary AND (deleted_at IS NULL));


--
-- Name: delivery_incidents set_delivery_incidents_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_delivery_incidents_updated_at BEFORE UPDATE ON public.delivery_incidents FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hrga_approval_configs set_hrga_approval_configs_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_hrga_approval_configs_updated_at BEFORE UPDATE ON public.hrga_approval_configs FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hrga_offboarding_checklists set_hrga_offboarding_checklists_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_hrga_offboarding_checklists_updated_at BEFORE UPDATE ON public.hrga_offboarding_checklists FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hrga_offboarding_items set_hrga_offboarding_items_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_hrga_offboarding_items_updated_at BEFORE UPDATE ON public.hrga_offboarding_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hrga_request_items set_hrga_request_items_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_hrga_request_items_updated_at BEFORE UPDATE ON public.hrga_request_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hrga_request_types set_hrga_request_types_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_hrga_request_types_updated_at BEFORE UPDATE ON public.hrga_request_types FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hrga_requests set_hrga_requests_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_hrga_requests_updated_at BEFORE UPDATE ON public.hrga_requests FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: prf_cost_items set_prf_cost_items_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_prf_cost_items_updated_at BEFORE UPDATE ON public.prf_cost_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: prf set_prf_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_prf_updated_at BEFORE UPDATE ON public.prf FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: sales_orders set_sales_orders_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_sales_orders_updated_at BEFORE UPDATE ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: accounts trg_a_sync_lifecycle_columns; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_a_sync_lifecycle_columns BEFORE INSERT OR UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.sync_lifecycle_columns();


--
-- Name: approval_delegations trg_approval_delegations_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_approval_delegations_updated_at BEFORE UPDATE ON public.approval_delegations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: approval_rules trg_approval_rules_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_approval_rules_updated_at BEFORE UPDATE ON public.approval_rules FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: ar_ttfs trg_ar_ttfs_set_company; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_ar_ttfs_set_company BEFORE INSERT ON public.ar_ttfs FOR EACH ROW EXECUTE FUNCTION public.ar_ttfs_set_company();


--
-- Name: ar_ttfs trg_ar_ttfs_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_ar_ttfs_updated_at BEFORE UPDATE ON public.ar_ttfs FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_categories trg_asset_categories_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_categories_updated_at BEFORE UPDATE ON public.asset_categories FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_fuel_logs trg_asset_fuel_logs_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_fuel_logs_updated_at BEFORE UPDATE ON public.asset_fuel_logs FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_locations trg_asset_locations_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_locations_updated_at BEFORE UPDATE ON public.asset_locations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_maintenance_records trg_asset_maintenance_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_maintenance_updated_at BEFORE UPDATE ON public.asset_maintenance_records FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_network trg_asset_network_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_network_updated_at BEFORE UPDATE ON public.asset_network FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_software_licenses trg_asset_software_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_software_updated_at BEFORE UPDATE ON public.asset_software_licenses FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: asset_specifications trg_asset_specifications_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_asset_specifications_updated_at BEFORE UPDATE ON public.asset_specifications FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: assets trg_assets_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_assets_updated_at BEFORE UPDATE ON public.assets FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: branches trg_branches_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_branches_updated_at BEFORE UPDATE ON public.branches FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: chart_of_accounts trg_chart_of_accounts_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_chart_of_accounts_updated_at BEFORE UPDATE ON public.chart_of_accounts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: companies trg_companies_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_companies_updated_at BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: cost_centers trg_cost_centers_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_cost_centers_updated_at BEFORE UPDATE ON public.cost_centers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: currencies trg_currencies_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_currencies_updated_at BEFORE UPDATE ON public.currencies FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: customers trg_customers_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_customers_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: delivery_notes trg_delivery_notes_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_delivery_notes_updated_at BEFORE UPDATE ON public.delivery_notes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: departments trg_departments_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_departments_updated_at BEFORE UPDATE ON public.departments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: document_sequences trg_document_sequences_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_document_sequences_updated_at BEFORE UPDATE ON public.document_sequences FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: document_types trg_document_types_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_document_types_updated_at BEFORE UPDATE ON public.document_types FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: exchange_rates trg_exchange_rates_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_exchange_rates_updated_at BEFORE UPDATE ON public.exchange_rates FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: accounts trg_gen_customer_code_ins; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_gen_customer_code_ins BEFORE INSERT ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.generate_customer_code();


--
-- Name: bnf_department_scopes trg_guard_bnf_department_scope_not_home; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_bnf_department_scope_not_home BEFORE INSERT OR UPDATE ON public.bnf_department_scopes FOR EACH ROW EXECUTE FUNCTION public.guard_bnf_department_scope_not_home();


--
-- Name: bnf_division_scopes trg_guard_bnf_division_scope_not_home; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_bnf_division_scope_not_home BEFORE INSERT OR UPDATE ON public.bnf_division_scopes FOR EACH ROW EXECUTE FUNCTION public.guard_bnf_division_scope_not_home();


--
-- Name: bnf_reports trg_guard_bnf_reports_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_bnf_reports_update BEFORE UPDATE ON public.bnf_reports FOR EACH ROW EXECUTE FUNCTION public.guard_bnf_reports_field_update();


--
-- Name: daily_report_items trg_guard_daily_report_items_field_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_daily_report_items_field_update BEFORE UPDATE ON public.daily_report_items FOR EACH ROW EXECUTE FUNCTION public.guard_daily_report_items_field_update();


--
-- Name: quotations trg_inquiry_quoted; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_inquiry_quoted AFTER INSERT OR UPDATE OF status ON public.quotations FOR EACH ROW EXECUTE FUNCTION public.set_inquiry_quoted_on_quotation_sent();


--
-- Name: prf trg_inquiry_review; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_inquiry_review AFTER INSERT OR UPDATE OF status ON public.prf FOR EACH ROW EXECUTE FUNCTION public.set_inquiry_review_on_prf_submit();


--
-- Name: sales_orders trg_inquiry_won; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_inquiry_won AFTER INSERT OR UPDATE ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.set_inquiry_won_on_so();


--
-- Name: payment_terms trg_payment_terms_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_terms_updated_at BEFORE UPDATE ON public.payment_terms FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: picking_lists trg_picking_lists_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_picking_lists_updated_at BEFORE UPDATE ON public.picking_lists FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: positions trg_positions_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_positions_updated_at BEFORE UPDATE ON public.positions FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: prf_vendor_offers trg_prf_vendor_offers_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_prf_vendor_offers_updated_at BEFORE UPDATE ON public.prf_vendor_offers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: product_warehouse_location trg_product_warehouse_location_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_product_warehouse_location_updated_at BEFORE UPDATE ON public.product_warehouse_location FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: products trg_products_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: profiles trg_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: quotations trg_quotation_prf_consistency; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_quotation_prf_consistency BEFORE INSERT OR UPDATE ON public.quotations FOR EACH ROW EXECUTE FUNCTION public.guard_quotation_prf_consistency();


--
-- Name: roles trg_roles_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_roles_updated_at BEFORE UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: inquiries trg_set_customer_on_inquiry_won; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_customer_on_inquiry_won AFTER INSERT OR UPDATE ON public.inquiries FOR EACH ROW EXECUTE FUNCTION public.set_customer_on_inquiry_won();


--
-- Name: accounts trg_set_customer_on_won; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_customer_on_won BEFORE INSERT OR UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.set_customer_on_won();


--
-- Name: daily_report_items trg_set_daily_report_items_defaults; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_daily_report_items_defaults BEFORE INSERT ON public.daily_report_items FOR EACH ROW EXECUTE FUNCTION public.set_daily_report_items_defaults();


--
-- Name: inquiries trg_set_prospect_on_inquiry; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_prospect_on_inquiry AFTER INSERT ON public.inquiries FOR EACH ROW EXECUTE FUNCTION public.set_prospect_on_inquiry();


--
-- Name: sp_items trg_sp_items_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sp_items_updated_at BEFORE UPDATE ON public.sp_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: status_catalog trg_status_catalog_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_status_catalog_updated_at BEFORE UPDATE ON public.status_catalog FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: taxes trg_taxes_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_taxes_updated_at BEFORE UPDATE ON public.taxes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: vendors trg_vendors_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_vendors_updated_at BEFORE UPDATE ON public.vendors FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: warehouses trg_warehouses_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_warehouses_updated_at BEFORE UPDATE ON public.warehouses FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: accounts trg_z_gen_customer_code_upd; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_gen_customer_code_upd BEFORE UPDATE ON public.accounts FOR EACH ROW WHEN ((((new.code IS NULL) OR (new.code = ''::text)) AND (new.deleted_at IS NULL))) EXECUTE FUNCTION public.generate_customer_code();


--
-- Name: inquiries trg_z_lock_inquiry_owner; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_lock_inquiry_owner BEFORE UPDATE OF owner_id ON public.inquiries FOR EACH ROW EXECUTE FUNCTION public.lock_inquiry_owner_when_closed();


--
-- Name: inquiries trg_z_log_inquiry_status_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_log_inquiry_status_change AFTER UPDATE ON public.inquiries FOR EACH ROW WHEN (((new.status)::text IS DISTINCT FROM (old.status)::text)) EXECUTE FUNCTION public.log_inquiry_status_change();


--
-- Name: accounts trg_z_log_lifecycle_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_log_lifecycle_change AFTER UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.log_lifecycle_change();


--
-- Name: products trg_z_products_price_history; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_products_price_history AFTER UPDATE OF default_price ON public.products FOR EACH ROW WHEN ((old.default_price IS DISTINCT FROM new.default_price)) EXECUTE FUNCTION public.log_product_price_change();


--
-- Name: inquiries trg_z_stamp_inquiry_closure; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_stamp_inquiry_closure BEFORE UPDATE ON public.inquiries FOR EACH ROW WHEN ((((new.status)::text = ANY ((ARRAY['WON'::character varying, 'LOST'::character varying, 'CANCELLED'::character varying])::text[])) AND ((old.status)::text IS DISTINCT FROM (new.status)::text))) EXECUTE FUNCTION public.stamp_inquiry_closure();


--
-- Name: quotations trg_z_sync_deal_value_on_quotation_accept; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_sync_deal_value_on_quotation_accept AFTER UPDATE ON public.quotations FOR EACH ROW EXECUTE FUNCTION public.sync_deal_value_on_quotation_accept();


--
-- Name: activities trg_z_sync_last_activity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_sync_last_activity AFTER INSERT OR DELETE OR UPDATE ON public.activities FOR EACH ROW EXECUTE FUNCTION public.sync_last_activity_on_account();


--
-- Name: profiles trg_z_sync_profile_email; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_sync_profile_email BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.sync_profile_email();


--
-- Name: accounts trg_z_track_stage_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_z_track_stage_change BEFORE UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.track_stage_change();


--
-- Name: accounts accounts_pull_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pull_approved_by_fkey FOREIGN KEY (pull_approved_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: activities activities_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: activities activities_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: activities activities_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contacts(id);


--
-- Name: activities activities_inquiry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: activities activities_quotation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_quotation_id_fkey FOREIGN KEY (quotation_id) REFERENCES public.quotations(id);


--
-- Name: activity_logs activity_logs_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_logs
    ADD CONSTRAINT activity_logs_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;


--
-- Name: account_lifecycle_history alh_account_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_lifecycle_history
    ADD CONSTRAINT alh_account_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: account_lifecycle_history alh_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_lifecycle_history
    ADD CONSTRAINT alh_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.profiles(id);


--
-- Name: app_settings app_settings_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: app_settings app_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: approval_delegations approval_delegations_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_delegations
    ADD CONSTRAINT approval_delegations_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES auth.users(id);


--
-- Name: approval_delegations approval_delegations_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_delegations
    ADD CONSTRAINT approval_delegations_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: approval_delegations approval_delegations_delegate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_delegations
    ADD CONSTRAINT approval_delegations_delegate_id_fkey FOREIGN KEY (delegate_id) REFERENCES auth.users(id);


--
-- Name: approval_delegations approval_delegations_delegator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_delegations
    ADD CONSTRAINT approval_delegations_delegator_id_fkey FOREIGN KEY (delegator_id) REFERENCES auth.users(id);


--
-- Name: approval_logs approval_logs_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_logs
    ADD CONSTRAINT approval_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES auth.users(id);


--
-- Name: approval_logs approval_logs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_logs
    ADD CONSTRAINT approval_logs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: approval_rules approval_rules_approver_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_approver_role_id_fkey FOREIGN KEY (approver_role_id) REFERENCES public.roles(id);


--
-- Name: approval_rules approval_rules_approver_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_approver_user_id_fkey FOREIGN KEY (approver_user_id) REFERENCES auth.users(id);


--
-- Name: approval_rules approval_rules_backup_approver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_backup_approver_id_fkey FOREIGN KEY (backup_approver_id) REFERENCES auth.users(id);


--
-- Name: approval_rules approval_rules_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: approval_rules approval_rules_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: approval_rules approval_rules_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_rules
    ADD CONSTRAINT approval_rules_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id);


--
-- Name: approval_workflow_steps approval_workflow_steps_approver_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflow_steps
    ADD CONSTRAINT approval_workflow_steps_approver_user_id_fkey FOREIGN KEY (approver_user_id) REFERENCES auth.users(id);


--
-- Name: approval_workflow_steps approval_workflow_steps_workflow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflow_steps
    ADD CONSTRAINT approval_workflow_steps_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES public.approval_workflows(id) ON DELETE CASCADE;


--
-- Name: approval_workflows approval_workflows_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflows
    ADD CONSTRAINT approval_workflows_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: approval_workflows approval_workflows_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.approval_workflows
    ADD CONSTRAINT approval_workflows_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: ar_btbs ar_btbs_ttf_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_btbs
    ADD CONSTRAINT ar_btbs_ttf_id_fkey FOREIGN KEY (ttf_id) REFERENCES public.ar_ttfs(id) ON DELETE CASCADE;


--
-- Name: ar_ttfs ar_ttfs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_ttfs
    ADD CONSTRAINT ar_ttfs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: ar_ttfs ar_ttfs_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_ttfs
    ADD CONSTRAINT ar_ttfs_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: ar_ttfs ar_ttfs_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_ttfs
    ADD CONSTRAINT ar_ttfs_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.sp_invoices(id);


--
-- Name: ar_ttfs ar_ttfs_sp_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_ttfs
    ADD CONSTRAINT ar_ttfs_sp_order_id_fkey FOREIGN KEY (sp_order_id) REFERENCES public.sp_orders(id);


--
-- Name: asset_categories asset_categories_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_categories
    ADD CONSTRAINT asset_categories_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: asset_categories asset_categories_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_categories
    ADD CONSTRAINT asset_categories_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: asset_fuel_logs asset_fuel_logs_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_fuel_logs
    ADD CONSTRAINT asset_fuel_logs_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE RESTRICT;


--
-- Name: asset_fuel_logs asset_fuel_logs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_fuel_logs
    ADD CONSTRAINT asset_fuel_logs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: asset_fuel_logs asset_fuel_logs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_fuel_logs
    ADD CONSTRAINT asset_fuel_logs_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: asset_locations asset_locations_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_locations
    ADD CONSTRAINT asset_locations_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);


--
-- Name: asset_locations asset_locations_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_locations
    ADD CONSTRAINT asset_locations_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: asset_locations asset_locations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_locations
    ADD CONSTRAINT asset_locations_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: asset_maintenance_records asset_maintenance_records_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_maintenance_records
    ADD CONSTRAINT asset_maintenance_records_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: asset_maintenance_records asset_maintenance_records_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_maintenance_records
    ADD CONSTRAINT asset_maintenance_records_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: asset_maintenance_records asset_maintenance_records_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_maintenance_records
    ADD CONSTRAINT asset_maintenance_records_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: asset_network asset_network_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_network
    ADD CONSTRAINT asset_network_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: asset_network asset_network_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_network
    ADD CONSTRAINT asset_network_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: asset_software_licenses asset_software_licenses_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_software_licenses
    ADD CONSTRAINT asset_software_licenses_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: asset_software_licenses asset_software_licenses_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_software_licenses
    ADD CONSTRAINT asset_software_licenses_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: asset_software_licenses asset_software_licenses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_software_licenses
    ADD CONSTRAINT asset_software_licenses_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: asset_specifications asset_specifications_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_specifications
    ADD CONSTRAINT asset_specifications_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: asset_specifications asset_specifications_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.asset_specifications
    ADD CONSTRAINT asset_specifications_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: assets assets_assigned_to_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_assigned_to_user_id_fkey FOREIGN KEY (assigned_to_user_id) REFERENCES auth.users(id);


--
-- Name: assets assets_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.asset_categories(id);


--
-- Name: assets assets_coa_asset_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_coa_asset_account_id_fkey FOREIGN KEY (coa_asset_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: assets assets_coa_depreciation_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_coa_depreciation_account_id_fkey FOREIGN KEY (coa_depreciation_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: assets assets_coa_expense_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_coa_expense_account_id_fkey FOREIGN KEY (coa_expense_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: assets assets_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: assets assets_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: assets assets_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id);


--
-- Name: assets assets_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.asset_locations(id);


--
-- Name: assets assets_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: audit_logs audit_logs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: audit_logs audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: bnf_authorized_users bnf_authorized_users_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_authorized_users
    ADD CONSTRAINT bnf_authorized_users_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: bnf_authorized_users bnf_authorized_users_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_authorized_users
    ADD CONSTRAINT bnf_authorized_users_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES auth.users(id);


--
-- Name: bnf_authorized_users bnf_authorized_users_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_authorized_users
    ADD CONSTRAINT bnf_authorized_users_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: bnf_department_scopes bnf_department_scopes_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_department_scopes
    ADD CONSTRAINT bnf_department_scopes_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: bnf_department_scopes bnf_department_scopes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_department_scopes
    ADD CONSTRAINT bnf_department_scopes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: bnf_department_scopes bnf_department_scopes_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_department_scopes
    ADD CONSTRAINT bnf_department_scopes_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.bnf_departments(id) ON DELETE CASCADE;


--
-- Name: bnf_departments bnf_departments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_departments
    ADD CONSTRAINT bnf_departments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: bnf_departments bnf_departments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_departments
    ADD CONSTRAINT bnf_departments_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: bnf_departments bnf_departments_division_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_departments
    ADD CONSTRAINT bnf_departments_division_id_fkey FOREIGN KEY (division_id) REFERENCES public.bnf_divisions(id) ON DELETE RESTRICT;


--
-- Name: bnf_departments bnf_departments_head_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_departments
    ADD CONSTRAINT bnf_departments_head_profile_id_fkey FOREIGN KEY (head_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: bnf_division_scopes bnf_division_scopes_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_division_scopes
    ADD CONSTRAINT bnf_division_scopes_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: bnf_division_scopes bnf_division_scopes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_division_scopes
    ADD CONSTRAINT bnf_division_scopes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: bnf_division_scopes bnf_division_scopes_division_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_division_scopes
    ADD CONSTRAINT bnf_division_scopes_division_id_fkey FOREIGN KEY (division_id) REFERENCES public.bnf_divisions(id) ON DELETE CASCADE;


--
-- Name: bnf_divisions bnf_divisions_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_divisions
    ADD CONSTRAINT bnf_divisions_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: bnf_divisions bnf_divisions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_divisions
    ADD CONSTRAINT bnf_divisions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: bnf_divisions bnf_divisions_director_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_divisions
    ADD CONSTRAINT bnf_divisions_director_profile_id_fkey FOREIGN KEY (director_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: bnf_report_action_items bnf_report_action_items_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_action_items
    ADD CONSTRAINT bnf_report_action_items_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.profiles(id) ON DELETE RESTRICT;


--
-- Name: bnf_report_action_items bnf_report_action_items_completed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_action_items
    ADD CONSTRAINT bnf_report_action_items_completed_by_fkey FOREIGN KEY (completed_by) REFERENCES auth.users(id);


--
-- Name: bnf_report_action_items bnf_report_action_items_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_action_items
    ADD CONSTRAINT bnf_report_action_items_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: bnf_report_action_items bnf_report_action_items_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_action_items
    ADD CONSTRAINT bnf_report_action_items_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.bnf_reports(id) ON DELETE CASCADE;


--
-- Name: bnf_report_logs bnf_report_logs_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_logs
    ADD CONSTRAINT bnf_report_logs_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users(id);


--
-- Name: bnf_report_logs bnf_report_logs_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_logs
    ADD CONSTRAINT bnf_report_logs_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.bnf_reports(id) ON DELETE CASCADE;


--
-- Name: bnf_report_related_departments bnf_report_related_departments_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_related_departments
    ADD CONSTRAINT bnf_report_related_departments_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.bnf_departments(id) ON DELETE RESTRICT;


--
-- Name: bnf_report_related_departments bnf_report_related_departments_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_report_related_departments
    ADD CONSTRAINT bnf_report_related_departments_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.bnf_reports(id) ON DELETE CASCADE;


--
-- Name: bnf_reports bnf_reports_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: bnf_reports bnf_reports_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: bnf_reports bnf_reports_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.bnf_departments(id) ON DELETE RESTRICT;


--
-- Name: bnf_reports bnf_reports_division_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_division_id_fkey FOREIGN KEY (division_id) REFERENCES public.bnf_divisions(id) ON DELETE RESTRICT;


--
-- Name: bnf_reports bnf_reports_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bnf_reports
    ADD CONSTRAINT bnf_reports_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: branches branches_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: branches branches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: channel_types channel_types_company_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.channel_types
    ADD CONSTRAINT channel_types_company_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: channel_types channel_types_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.channel_types
    ADD CONSTRAINT channel_types_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: chart_of_accounts chart_of_accounts_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: chart_of_accounts chart_of_accounts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: chart_of_accounts chart_of_accounts_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: contacts contacts_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: cost_centers cost_centers_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);


--
-- Name: cost_centers cost_centers_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: cost_centers cost_centers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: cost_centers cost_centers_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id);


--
-- Name: customers customers_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: customers customers_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: customers customers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: customers customers_currency_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES public.currencies(code);


--
-- Name: customers customers_payment_terms_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_payment_terms_id_fkey FOREIGN KEY (payment_terms_id) REFERENCES public.payment_terms(id);


--
-- Name: customers customers_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.accounts(id) ON DELETE SET NULL;


--
-- Name: customers customers_source_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_source_company_id_fkey FOREIGN KEY (source_company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: customers customers_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: daily_report_items daily_report_items_carried_from_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_carried_from_id_fkey FOREIGN KEY (carried_from_id) REFERENCES public.daily_report_items(id);


--
-- Name: daily_report_items daily_report_items_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: daily_report_items daily_report_items_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: daily_report_items daily_report_items_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.bnf_departments(id) ON DELETE RESTRICT;


--
-- Name: daily_report_items daily_report_items_pulled_to_bnf_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_pulled_to_bnf_report_id_fkey FOREIGN KEY (pulled_to_bnf_report_id) REFERENCES public.bnf_reports(id);


--
-- Name: daily_report_items daily_report_items_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_report_items
    ADD CONSTRAINT daily_report_items_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES auth.users(id);


--
-- Name: dc_master dc_master_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dc_master
    ADD CONSTRAINT dc_master_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: dc_master dc_master_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dc_master
    ADD CONSTRAINT dc_master_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: deal_handovers deal_handovers_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: deal_handovers deal_handovers_approved_by_finance_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_approved_by_finance_fkey FOREIGN KEY (approved_by_finance) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: deal_handovers deal_handovers_approved_by_ops_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_approved_by_ops_fkey FOREIGN KEY (approved_by_ops) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: deal_handovers deal_handovers_approved_by_sales_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_approved_by_sales_fkey FOREIGN KEY (approved_by_sales) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: deal_handovers deal_handovers_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: deal_handovers deal_handovers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: deal_handovers deal_handovers_kam_assigned_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deal_handovers
    ADD CONSTRAINT deal_handovers_kam_assigned_fkey FOREIGN KEY (kam_assigned) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: delivery_incidents delivery_incidents_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_incidents
    ADD CONSTRAINT delivery_incidents_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: delivery_incidents delivery_incidents_delivery_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_incidents
    ADD CONSTRAINT delivery_incidents_delivery_note_id_fkey FOREIGN KEY (delivery_note_id) REFERENCES public.delivery_notes(id) ON DELETE CASCADE;


--
-- Name: delivery_incidents delivery_incidents_reported_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_incidents
    ADD CONSTRAINT delivery_incidents_reported_by_fkey FOREIGN KEY (reported_by) REFERENCES auth.users(id);


--
-- Name: delivery_incidents delivery_incidents_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_incidents
    ADD CONSTRAINT delivery_incidents_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES auth.users(id);


--
-- Name: delivery_note_items delivery_note_items_delivery_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_delivery_note_id_fkey FOREIGN KEY (delivery_note_id) REFERENCES public.delivery_notes(id) ON DELETE CASCADE;


--
-- Name: delivery_note_items delivery_note_items_picking_list_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_picking_list_item_id_fkey FOREIGN KEY (picking_list_item_id) REFERENCES public.picking_list_items(id) ON DELETE SET NULL;


--
-- Name: delivery_note_items delivery_note_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: delivery_note_items delivery_note_items_sp_order_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_sp_order_item_id_fkey FOREIGN KEY (sp_order_item_id) REFERENCES public.sp_order_items(id) ON DELETE SET NULL;


--
-- Name: delivery_notes delivery_notes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: delivery_notes delivery_notes_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: delivery_notes delivery_notes_picking_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_picking_list_id_fkey FOREIGN KEY (picking_list_id) REFERENCES public.picking_lists(id);


--
-- Name: delivery_notes delivery_notes_sp_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_sp_order_id_fkey FOREIGN KEY (sp_order_id) REFERENCES public.sp_orders(id);


--
-- Name: departments departments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: departments departments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: departments departments_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.departments(id);


--
-- Name: document_numbering document_numbering_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_numbering
    ADD CONSTRAINT document_numbering_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: document_numbering document_numbering_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_numbering
    ADD CONSTRAINT document_numbering_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: document_sequences document_sequences_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_sequences
    ADD CONSTRAINT document_sequences_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: document_templates document_templates_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_templates
    ADD CONSTRAINT document_templates_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: document_templates document_templates_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_templates
    ADD CONSTRAINT document_templates_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: document_types document_types_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: document_types document_types_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: dropdown_options dropdown_options_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dropdown_options
    ADD CONSTRAINT dropdown_options_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: entity_bank_accounts entity_bank_accounts_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_bank_accounts
    ADD CONSTRAINT entity_bank_accounts_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: entity_bank_accounts entity_bank_accounts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_bank_accounts
    ADD CONSTRAINT entity_bank_accounts_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: entity_finance_settings entity_finance_settings_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_finance_settings
    ADD CONSTRAINT entity_finance_settings_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: entity_finance_settings entity_finance_settings_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_finance_settings
    ADD CONSTRAINT entity_finance_settings_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: entity_finance_settings entity_finance_settings_default_payment_term_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_finance_settings
    ADD CONSTRAINT entity_finance_settings_default_payment_term_id_fkey FOREIGN KEY (default_payment_term_id) REFERENCES public.payment_terms(id) ON DELETE SET NULL;


--
-- Name: entity_signatories entity_signatories_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_signatories
    ADD CONSTRAINT entity_signatories_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: entity_signatories entity_signatories_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entity_signatories
    ADD CONSTRAINT entity_signatories_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: exchange_rates exchange_rates_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: exchange_rates exchange_rates_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: exchange_rates exchange_rates_from_currency_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_from_currency_fkey FOREIGN KEY (from_currency) REFERENCES public.currencies(code);


--
-- Name: exchange_rates exchange_rates_to_currency_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_to_currency_fkey FOREIGN KEY (to_currency) REFERENCES public.currencies(code);


--
-- Name: products fk_products_cogs_account; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_products_cogs_account FOREIGN KEY (cogs_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: products fk_products_revenue_account; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_products_revenue_account FOREIGN KEY (revenue_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: profiles fk_profiles_position_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT fk_profiles_position_id FOREIGN KEY (position_id) REFERENCES public.positions(id);


--
-- Name: taxes fk_taxes_gl_account; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT fk_taxes_gl_account FOREIGN KEY (gl_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: hrga_approval_configs hrga_approval_configs_approver_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_approval_configs
    ADD CONSTRAINT hrga_approval_configs_approver_user_id_fkey FOREIGN KEY (approver_user_id) REFERENCES auth.users(id);


--
-- Name: hrga_approval_configs hrga_approval_configs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_approval_configs
    ADD CONSTRAINT hrga_approval_configs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: hrga_approval_configs hrga_approval_configs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_approval_configs
    ADD CONSTRAINT hrga_approval_configs_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: hrga_approval_configs hrga_approval_configs_request_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_approval_configs
    ADD CONSTRAINT hrga_approval_configs_request_type_id_fkey FOREIGN KEY (request_type_id) REFERENCES public.hrga_request_types(id);


--
-- Name: hrga_notification_queue hrga_notification_queue_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_notification_queue
    ADD CONSTRAINT hrga_notification_queue_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: hrga_notification_queue hrga_notification_queue_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_notification_queue
    ADD CONSTRAINT hrga_notification_queue_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES auth.users(id);


--
-- Name: hrga_notification_queue hrga_notification_queue_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_notification_queue
    ADD CONSTRAINT hrga_notification_queue_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.hrga_requests(id);


--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_checklists
    ADD CONSTRAINT hrga_offboarding_checklists_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_checklists
    ADD CONSTRAINT hrga_offboarding_checklists_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_checklists
    ADD CONSTRAINT hrga_offboarding_checklists_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: hrga_offboarding_items hrga_offboarding_items_checklist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_items
    ADD CONSTRAINT hrga_offboarding_items_checklist_id_fkey FOREIGN KEY (checklist_id) REFERENCES public.hrga_offboarding_checklists(id);


--
-- Name: hrga_offboarding_items hrga_offboarding_items_completed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_items
    ADD CONSTRAINT hrga_offboarding_items_completed_by_fkey FOREIGN KEY (completed_by) REFERENCES auth.users(id);


--
-- Name: hrga_offboarding_items hrga_offboarding_items_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_offboarding_items
    ADD CONSTRAINT hrga_offboarding_items_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.hrga_requests(id) ON DELETE CASCADE;


--
-- Name: hrga_request_approvals hrga_request_approvals_approver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_approvals
    ADD CONSTRAINT hrga_request_approvals_approver_id_fkey FOREIGN KEY (approver_id) REFERENCES auth.users(id);


--
-- Name: hrga_request_approvals hrga_request_approvals_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_approvals
    ADD CONSTRAINT hrga_request_approvals_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.hrga_requests(id);


--
-- Name: hrga_request_attachments hrga_request_attachments_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_attachments
    ADD CONSTRAINT hrga_request_attachments_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.hrga_requests(id);


--
-- Name: hrga_request_attachments hrga_request_attachments_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_attachments
    ADD CONSTRAINT hrga_request_attachments_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES auth.users(id);


--
-- Name: hrga_request_items hrga_request_items_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_items
    ADD CONSTRAINT hrga_request_items_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.hrga_requests(id) ON DELETE CASCADE;


--
-- Name: hrga_request_types hrga_request_types_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_types
    ADD CONSTRAINT hrga_request_types_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: hrga_request_types hrga_request_types_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_types
    ADD CONSTRAINT hrga_request_types_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: hrga_request_types hrga_request_types_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_request_types
    ADD CONSTRAINT hrga_request_types_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: hrga_requests hrga_requests_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);


--
-- Name: hrga_requests hrga_requests_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: hrga_requests hrga_requests_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: hrga_requests hrga_requests_currency_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES public.currencies(code);


--
-- Name: hrga_requests hrga_requests_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id);


--
-- Name: hrga_requests hrga_requests_request_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_request_type_id_fkey FOREIGN KEY (request_type_id) REFERENCES public.hrga_request_types(id);


--
-- Name: hrga_requests hrga_requests_requester_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_requester_id_fkey FOREIGN KEY (requester_id) REFERENCES auth.users(id);


--
-- Name: hrga_requests hrga_requests_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hrga_requests
    ADD CONSTRAINT hrga_requests_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: inquiries inquiries_closed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.profiles(id);


--
-- Name: inquiries inquiries_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: inquiries inquiries_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contacts(id);


--
-- Name: inquiries inquiries_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: inquiries inquiries_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: inquiries inquiries_loss_reason_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_loss_reason_id_fkey FOREIGN KEY (loss_reason_id) REFERENCES public.loss_reasons(id);


--
-- Name: inquiries inquiries_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.profiles(id);


--
-- Name: inquiries inquiries_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.accounts(id);


--
-- Name: inquiry_comment_mentions inquiry_comment_mentions_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comment_mentions
    ADD CONSTRAINT inquiry_comment_mentions_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.inquiry_comments(id) ON DELETE CASCADE;


--
-- Name: inquiry_comment_mentions inquiry_comment_mentions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comment_mentions
    ADD CONSTRAINT inquiry_comment_mentions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: inquiry_comments inquiry_comments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comments
    ADD CONSTRAINT inquiry_comments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: inquiry_comments inquiry_comments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comments
    ADD CONSTRAINT inquiry_comments_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: inquiry_comments inquiry_comments_inquiry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_comments
    ADD CONSTRAINT inquiry_comments_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: inquiry_status_history ish_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_status_history
    ADD CONSTRAINT ish_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.profiles(id);


--
-- Name: inquiry_status_history ish_inquiry_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inquiry_status_history
    ADD CONSTRAINT ish_inquiry_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id) ON DELETE CASCADE;


--
-- Name: journal_entries journal_entries_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: journal_entry_lines journal_entry_lines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT;


--
-- Name: journal_entry_lines journal_entry_lines_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE CASCADE;


--
-- Name: loss_reasons loss_reasons_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loss_reasons
    ADD CONSTRAINT loss_reasons_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: meeting_moms meeting_moms_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.meeting_moms
    ADD CONSTRAINT meeting_moms_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: meeting_moms meeting_moms_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.meeting_moms
    ADD CONSTRAINT meeting_moms_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: meeting_moms meeting_moms_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.meeting_moms
    ADD CONSTRAINT meeting_moms_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: meeting_moms meeting_moms_notulis_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.meeting_moms
    ADD CONSTRAINT meeting_moms_notulis_id_fkey FOREIGN KEY (notulis_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: menu_actions menu_actions_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu_actions
    ADD CONSTRAINT menu_actions_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES public.module_menus(id) ON DELETE CASCADE;


--
-- Name: module_actions module_actions_module_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.module_actions
    ADD CONSTRAINT module_actions_module_id_fkey FOREIGN KEY (module_id) REFERENCES public.modules(id) ON DELETE CASCADE;


--
-- Name: module_menus module_menus_module_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.module_menus
    ADD CONSTRAINT module_menus_module_id_fkey FOREIGN KEY (module_id) REFERENCES public.modules(id) ON DELETE CASCADE;


--
-- Name: mom_action_plans mom_action_plans_mom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_action_plans
    ADD CONSTRAINT mom_action_plans_mom_id_fkey FOREIGN KEY (mom_id) REFERENCES public.meeting_moms(id) ON DELETE CASCADE;


--
-- Name: mom_improvements mom_improvements_mom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_improvements
    ADD CONSTRAINT mom_improvements_mom_id_fkey FOREIGN KEY (mom_id) REFERENCES public.meeting_moms(id) ON DELETE CASCADE;


--
-- Name: mom_issues mom_issues_mom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_issues
    ADD CONSTRAINT mom_issues_mom_id_fkey FOREIGN KEY (mom_id) REFERENCES public.meeting_moms(id) ON DELETE CASCADE;


--
-- Name: mom_progress_updates mom_progress_updates_mom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mom_progress_updates
    ADD CONSTRAINT mom_progress_updates_mom_id_fkey FOREIGN KEY (mom_id) REFERENCES public.meeting_moms(id) ON DELETE CASCADE;


--
-- Name: notification_rules notification_rules_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: notification_rules notification_rules_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: notification_rules notification_rules_recipient_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_recipient_user_id_fkey FOREIGN KEY (recipient_user_id) REFERENCES auth.users(id);


--
-- Name: notifications notifications_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: payment_terms payment_terms_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_terms
    ADD CONSTRAINT payment_terms_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: payment_terms payment_terms_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_terms
    ADD CONSTRAINT payment_terms_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: picking_list_items picking_list_items_picking_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_items
    ADD CONSTRAINT picking_list_items_picking_list_id_fkey FOREIGN KEY (picking_list_id) REFERENCES public.picking_lists(id) ON DELETE CASCADE;


--
-- Name: picking_list_items picking_list_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_items
    ADD CONSTRAINT picking_list_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: picking_list_items picking_list_items_sp_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_items
    ADD CONSTRAINT picking_list_items_sp_item_id_fkey FOREIGN KEY (sp_item_id) REFERENCES public.sp_items(id) ON DELETE SET NULL;


--
-- Name: picking_list_materials picking_list_materials_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_materials
    ADD CONSTRAINT picking_list_materials_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: picking_list_materials picking_list_materials_picking_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_materials
    ADD CONSTRAINT picking_list_materials_picking_list_id_fkey FOREIGN KEY (picking_list_id) REFERENCES public.picking_lists(id) ON DELETE CASCADE;


--
-- Name: picking_list_materials picking_list_materials_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_list_materials
    ADD CONSTRAINT picking_list_materials_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: picking_lists picking_lists_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES auth.users(id);


--
-- Name: picking_lists picking_lists_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: picking_lists picking_lists_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: picking_lists picking_lists_sp_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_sp_order_id_fkey FOREIGN KEY (sp_order_id) REFERENCES public.sp_orders(id);


--
-- Name: picking_lists picking_lists_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.picking_lists
    ADD CONSTRAINT picking_lists_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: positions positions_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: positions positions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: positions positions_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id);


--
-- Name: product_price_history pph_product_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_price_history
    ADD CONSTRAINT pph_product_fk FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: prf prf_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: prf prf_acknowledged_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_acknowledged_by_fkey FOREIGN KEY (acknowledged_by) REFERENCES public.profiles(id);


--
-- Name: prf prf_answered_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_answered_by_fkey FOREIGN KEY (answered_by) REFERENCES public.profiles(id);


--
-- Name: prf prf_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: prf_cost_items prf_cost_items_currency_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_cost_items
    ADD CONSTRAINT prf_cost_items_currency_fkey FOREIGN KEY (currency) REFERENCES public.currencies(code);


--
-- Name: prf_cost_items prf_cost_items_offer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_cost_items
    ADD CONSTRAINT prf_cost_items_offer_id_fkey FOREIGN KEY (offer_id) REFERENCES public.prf_vendor_offers(id) ON DELETE CASCADE;


--
-- Name: prf_cost_items prf_cost_items_prf_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_cost_items
    ADD CONSTRAINT prf_cost_items_prf_id_fkey FOREIGN KEY (prf_id) REFERENCES public.prf(id) ON DELETE CASCADE;


--
-- Name: prf_cost_items prf_cost_items_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_cost_items
    ADD CONSTRAINT prf_cost_items_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: prf prf_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: prf prf_inquiry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: prf prf_selected_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_selected_by_fkey FOREIGN KEY (selected_by) REFERENCES public.profiles(id);


--
-- Name: prf prf_selected_offer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_selected_offer_id_fkey FOREIGN KEY (selected_offer_id) REFERENCES public.prf_vendor_offers(id) ON DELETE SET NULL;


--
-- Name: prf prf_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf
    ADD CONSTRAINT prf_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id);


--
-- Name: prf_vendor_offers prf_vendor_offers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_vendor_offers
    ADD CONSTRAINT prf_vendor_offers_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: prf_vendor_offers prf_vendor_offers_prf_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_vendor_offers
    ADD CONSTRAINT prf_vendor_offers_prf_id_fkey FOREIGN KEY (prf_id) REFERENCES public.prf(id) ON DELETE CASCADE;


--
-- Name: prf_vendor_offers prf_vendor_offers_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prf_vendor_offers
    ADD CONSTRAINT prf_vendor_offers_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: products products_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: products products_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: products products_tax_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_tax_id_fkey FOREIGN KEY (tax_id) REFERENCES public.taxes(id);


--
-- Name: products products_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: profiles profiles_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);


--
-- Name: profiles profiles_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: profiles profiles_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id);


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_reports_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_reports_to_fkey FOREIGN KEY (reports_to) REFERENCES public.profiles(id);


--
-- Name: accounts prospects_assigned_profile_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_assigned_profile_fkey FOREIGN KEY (assigned_profile) REFERENCES public.profiles(id);


--
-- Name: accounts prospects_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.profiles(id);


--
-- Name: accounts prospects_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: accounts prospects_converted_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_converted_to_fkey FOREIGN KEY (converted_to) REFERENCES public.accounts(id);


--
-- Name: accounts prospects_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: accounts prospects_owner_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_owner_company_id_fkey FOREIGN KEY (owner_company_id) REFERENCES public.companies(id);


--
-- Name: accounts prospects_payment_terms_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_payment_terms_id_fkey FOREIGN KEY (payment_terms_id) REFERENCES public.payment_terms(id);


--
-- Name: accounts prospects_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT prospects_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id);


--
-- Name: product_warehouse_location pwl_product_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_warehouse_location
    ADD CONSTRAINT pwl_product_fk FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: product_warehouse_location pwl_warehouse_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_warehouse_location
    ADD CONSTRAINT pwl_warehouse_fk FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: quotation_items quotation_items_quotation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotation_items
    ADD CONSTRAINT quotation_items_quotation_id_fkey FOREIGN KEY (quotation_id) REFERENCES public.quotations(id) ON DELETE CASCADE;


--
-- Name: quotations quotations_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: quotations quotations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: quotations quotations_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: quotations quotations_inquiry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: quotations quotations_payment_terms_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_payment_terms_id_fkey FOREIGN KEY (payment_terms_id) REFERENCES public.payment_terms(id);


--
-- Name: quotations quotations_prf_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_prf_id_fkey FOREIGN KEY (prf_id) REFERENCES public.prf(id);


--
-- Name: quotations quotations_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.accounts(id);


--
-- Name: quotations quotations_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotations
    ADD CONSTRAINT quotations_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id);


--
-- Name: rate_sheets rate_sheets_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rate_sheets
    ADD CONSTRAINT rate_sheets_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: rate_sheets rate_sheets_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rate_sheets
    ADD CONSTRAINT rate_sheets_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: role_menu_permissions role_menu_permissions_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_menu_permissions
    ADD CONSTRAINT role_menu_permissions_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES public.profiles(id);


--
-- Name: role_menu_permissions role_menu_permissions_menu_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_menu_permissions
    ADD CONSTRAINT role_menu_permissions_menu_action_id_fkey FOREIGN KEY (menu_action_id) REFERENCES public.menu_actions(id) ON DELETE CASCADE;


--
-- Name: role_menu_permissions role_menu_permissions_module_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_menu_permissions
    ADD CONSTRAINT role_menu_permissions_module_action_id_fkey FOREIGN KEY (module_action_id) REFERENCES public.module_actions(id) ON DELETE CASCADE;


--
-- Name: role_menu_permissions role_menu_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_menu_permissions
    ADD CONSTRAINT role_menu_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: role_permission_templates role_permission_templates_menu_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permission_templates
    ADD CONSTRAINT role_permission_templates_menu_action_id_fkey FOREIGN KEY (menu_action_id) REFERENCES public.menu_actions(id) ON DELETE CASCADE;


--
-- Name: role_permission_templates role_permission_templates_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permission_templates
    ADD CONSTRAINT role_permission_templates_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES auth.users(id);


--
-- Name: role_permissions role_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: roles roles_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: roles roles_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: sales_calls sales_calls_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_calls
    ADD CONSTRAINT sales_calls_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sales_calls sales_calls_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_calls
    ADD CONSTRAINT sales_calls_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: sales_calls sales_calls_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_calls
    ADD CONSTRAINT sales_calls_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.accounts(id) ON DELETE SET NULL;


--
-- Name: sales_calls sales_calls_salesperson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_calls
    ADD CONSTRAINT sales_calls_salesperson_id_fkey FOREIGN KEY (salesperson_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: sales_orders sales_orders_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: sales_orders sales_orders_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sales_orders sales_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: sales_orders sales_orders_inquiry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: sales_orders sales_orders_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id);


--
-- Name: sales_visit_logs sales_visit_logs_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visit_logs
    ADD CONSTRAINT sales_visit_logs_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.profiles(id);


--
-- Name: sales_visit_logs sales_visit_logs_visit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visit_logs
    ADD CONSTRAINT sales_visit_logs_visit_id_fkey FOREIGN KEY (visit_id) REFERENCES public.sales_visits(id) ON DELETE CASCADE;


--
-- Name: sales_visits sales_visits_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visits
    ADD CONSTRAINT sales_visits_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sales_visits sales_visits_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visits
    ADD CONSTRAINT sales_visits_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: sales_visits sales_visits_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visits
    ADD CONSTRAINT sales_visits_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.accounts(id) ON DELETE SET NULL;


--
-- Name: sales_visits sales_visits_salesperson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_visits
    ADD CONSTRAINT sales_visits_salesperson_id_fkey FOREIGN KEY (salesperson_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: sla_policies sla_policies_company_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_company_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sla_policies sla_policies_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: sla_policies sla_policies_inherits_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_inherits_fkey FOREIGN KEY (inherits_from) REFERENCES public.sla_policies(id);


--
-- Name: sp_btb sp_btb_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_btb
    ADD CONSTRAINT sp_btb_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sp_btb sp_btb_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_btb
    ADD CONSTRAINT sp_btb_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: sp_btb sp_btb_delivery_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_btb
    ADD CONSTRAINT sp_btb_delivery_note_id_fkey FOREIGN KEY (delivery_note_id) REFERENCES public.delivery_notes(id);


--
-- Name: sp_btb sp_btb_sp_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_btb
    ADD CONSTRAINT sp_btb_sp_order_id_fkey FOREIGN KEY (sp_order_id) REFERENCES public.sp_orders(id);


--
-- Name: sp_invoice_lines sp_invoice_lines_btb_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoice_lines
    ADD CONSTRAINT sp_invoice_lines_btb_id_fkey FOREIGN KEY (btb_id) REFERENCES public.sp_btb(id);


--
-- Name: sp_invoice_lines sp_invoice_lines_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoice_lines
    ADD CONSTRAINT sp_invoice_lines_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.sp_invoices(id) ON DELETE CASCADE;


--
-- Name: sp_invoice_lines sp_invoice_lines_sp_order_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoice_lines
    ADD CONSTRAINT sp_invoice_lines_sp_order_item_id_fkey FOREIGN KEY (sp_order_item_id) REFERENCES public.sp_order_items(id);


--
-- Name: sp_invoices sp_invoices_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoices
    ADD CONSTRAINT sp_invoices_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sp_invoices sp_invoices_sp_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_invoices
    ADD CONSTRAINT sp_invoices_sp_order_id_fkey FOREIGN KEY (sp_order_id) REFERENCES public.sp_orders(id);


--
-- Name: sp_items sp_items_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_items
    ADD CONSTRAINT sp_items_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES auth.users(id);


--
-- Name: sp_items sp_items_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_items
    ADD CONSTRAINT sp_items_confirmed_by_fkey FOREIGN KEY (confirmed_by) REFERENCES auth.users(id);


--
-- Name: sp_items sp_items_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_items
    ADD CONSTRAINT sp_items_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: sp_items sp_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_items
    ADD CONSTRAINT sp_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: sp_order_items sp_order_items_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_order_items
    ADD CONSTRAINT sp_order_items_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sp_order_items sp_order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_order_items
    ADD CONSTRAINT sp_order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: sp_order_items sp_order_items_sp_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_order_items
    ADD CONSTRAINT sp_order_items_sp_order_id_fkey FOREIGN KEY (sp_order_id) REFERENCES public.sp_orders(id) ON DELETE CASCADE;


--
-- Name: sp_orders sp_orders_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_orders
    ADD CONSTRAINT sp_orders_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: sp_orders sp_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_orders
    ADD CONSTRAINT sp_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.accounts(id);


--
-- Name: sp_orders sp_orders_dc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_orders
    ADD CONSTRAINT sp_orders_dc_id_fkey FOREIGN KEY (dc_id) REFERENCES public.dc_master(id);


--
-- Name: sp_payments sp_payments_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sp_payments
    ADD CONSTRAINT sp_payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.sp_invoices(id) ON DELETE CASCADE;


--
-- Name: stock_ledger stock_ledger_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_ledger
    ADD CONSTRAINT stock_ledger_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: stock_ledger stock_ledger_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_ledger
    ADD CONSTRAINT stock_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: stock_ledger stock_ledger_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_ledger
    ADD CONSTRAINT stock_ledger_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: stock_ledger stock_ledger_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_ledger
    ADD CONSTRAINT stock_ledger_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE RESTRICT;


--
-- Name: taxes taxes_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT taxes_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: taxes taxes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.taxes
    ADD CONSTRAINT taxes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: top_requests top_requests_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.top_requests
    ADD CONSTRAINT top_requests_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: top_requests top_requests_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.top_requests
    ADD CONSTRAINT top_requests_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: top_requests top_requests_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.top_requests
    ADD CONSTRAINT top_requests_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: top_requests top_requests_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.top_requests
    ADD CONSTRAINT top_requests_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: user_menu_permissions user_menu_permissions_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: user_menu_permissions user_menu_permissions_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES public.profiles(id);


--
-- Name: user_menu_permissions user_menu_permissions_menu_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_menu_action_id_fkey FOREIGN KEY (menu_action_id) REFERENCES public.menu_actions(id) ON DELETE CASCADE;


--
-- Name: user_menu_permissions user_menu_permissions_module_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_module_action_id_fkey FOREIGN KEY (module_action_id) REFERENCES public.module_actions(id) ON DELETE CASCADE;


--
-- Name: user_menu_permissions user_menu_permissions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_menu_permissions
    ADD CONSTRAINT user_menu_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: user_roles user_roles_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES auth.users(id);


--
-- Name: user_roles user_roles_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES auth.users(id);


--
-- Name: user_roles user_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: vendors vendors_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: vendors vendors_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: vendors vendors_currency_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES public.currencies(code);


--
-- Name: vendors vendors_payment_terms_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_payment_terms_id_fkey FOREIGN KEY (payment_terms_id) REFERENCES public.payment_terms(id);


--
-- Name: vendors vendors_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: warehouses warehouses_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: weekly_meeting_items weekly_meeting_items_bnf_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meeting_items
    ADD CONSTRAINT weekly_meeting_items_bnf_report_id_fkey FOREIGN KEY (bnf_report_id) REFERENCES public.bnf_reports(id);


--
-- Name: weekly_meeting_items weekly_meeting_items_daily_report_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meeting_items
    ADD CONSTRAINT weekly_meeting_items_daily_report_item_id_fkey FOREIGN KEY (daily_report_item_id) REFERENCES public.daily_report_items(id);


--
-- Name: weekly_meeting_items weekly_meeting_items_weekly_meeting_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meeting_items
    ADD CONSTRAINT weekly_meeting_items_weekly_meeting_id_fkey FOREIGN KEY (weekly_meeting_id) REFERENCES public.weekly_meetings(id) ON DELETE CASCADE;


--
-- Name: weekly_meetings weekly_meetings_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meetings
    ADD CONSTRAINT weekly_meetings_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: weekly_meetings weekly_meetings_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meetings
    ADD CONSTRAINT weekly_meetings_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: weekly_meetings weekly_meetings_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weekly_meetings
    ADD CONSTRAINT weekly_meetings_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.bnf_departments(id) ON DELETE RESTRICT;


--
-- Name: account_lifecycle_history; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.account_lifecycle_history ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts accounts_delete_superadmin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY accounts_delete_superadmin ON public.accounts FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: activities; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;

--
-- Name: activities activities_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activities_delete ON public.activities FOR DELETE TO authenticated USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: activities activities_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activities_insert ON public.activities FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: activities activities_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activities_select ON public.activities FOR SELECT TO authenticated USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (assigned_to = auth.uid()) OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: activities activities_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activities_update ON public.activities FOR UPDATE TO authenticated USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (assigned_to = auth.uid()) OR (created_by = auth.uid()))) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (assigned_to = auth.uid()) OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: activity_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: activity_logs activity_logs_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activity_logs_delete ON public.activity_logs FOR DELETE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.activities a
  WHERE (a.id = activity_logs.activity_id))) OR public.is_super_admin()));


--
-- Name: activity_logs activity_logs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activity_logs_insert ON public.activity_logs FOR INSERT TO authenticated WITH CHECK (((EXISTS ( SELECT 1
   FROM public.activities a
  WHERE (a.id = activity_logs.activity_id))) OR public.is_super_admin()));


--
-- Name: activity_logs activity_logs_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activity_logs_select ON public.activity_logs FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.activities a
  WHERE (a.id = activity_logs.activity_id))) OR public.is_super_admin()));


--
-- Name: activity_logs activity_logs_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY activity_logs_update ON public.activity_logs FOR UPDATE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.activities a
  WHERE (a.id = activity_logs.activity_id))) OR public.is_super_admin())) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.activities a
  WHERE (a.id = activity_logs.activity_id))) OR public.is_super_admin()));


--
-- Name: account_lifecycle_history alh_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY alh_read ON public.account_lifecycle_history FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.accounts a
  WHERE (a.id = account_lifecycle_history.account_id))));


--
-- Name: app_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: app_settings app_settings_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY app_settings_read ON public.app_settings FOR SELECT USING (public.is_admin_or_above());


--
-- Name: app_settings app_settings_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY app_settings_update ON public.app_settings FOR UPDATE USING (public.is_admin_or_above());


--
-- Name: app_settings app_settings_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY app_settings_write ON public.app_settings FOR INSERT WITH CHECK (public.is_admin_or_above());


--
-- Name: approval_delegations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.approval_delegations ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_delegations approval_delegations_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_delegations_insert ON public.approval_delegations FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND ((delegator_id = auth.uid()) OR public.is_admin_or_above())));


--
-- Name: approval_delegations approval_delegations_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_delegations_read ON public.approval_delegations FOR SELECT TO authenticated USING (((delegator_id = auth.uid()) OR (delegate_id = auth.uid()) OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.is_manager_or_above())) OR public.is_super_admin()));


--
-- Name: approval_delegations approval_delegations_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_delegations_update ON public.approval_delegations FOR UPDATE TO authenticated USING ((company_id = public.get_user_company_id())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: approval_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.approval_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_logs approval_logs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_logs_insert ON public.approval_logs FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND (actor_id = auth.uid())));


--
-- Name: approval_logs approval_logs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_logs_read ON public.approval_logs FOR SELECT TO authenticated USING ((company_id = public.get_user_company_id()));


--
-- Name: approval_rules; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.approval_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_rules approval_rules_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_rules_insert ON public.approval_rules FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: approval_rules approval_rules_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_rules_read ON public.approval_rules FOR SELECT TO authenticated USING ((company_id = public.get_user_company_id()));


--
-- Name: approval_rules approval_rules_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_rules_update ON public.approval_rules FOR UPDATE TO authenticated USING ((company_id = public.get_user_company_id())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: approval_workflow_steps; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.approval_workflow_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_workflow_steps approval_workflow_steps_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_workflow_steps_access ON public.approval_workflow_steps TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.approval_workflows aw
  WHERE ((aw.id = approval_workflow_steps.workflow_id) AND (((aw.company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.approval_workflows aw
  WHERE ((aw.id = approval_workflow_steps.workflow_id) AND (((aw.company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())))));


--
-- Name: approval_workflows; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.approval_workflows ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_workflows approval_workflows_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY approval_workflows_access ON public.approval_workflows TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: ar_btbs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.ar_btbs ENABLE ROW LEVEL SECURITY;

--
-- Name: ar_btbs ar_btbs_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_btbs_delete ON public.ar_btbs FOR DELETE TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.ar_ttfs t
  WHERE ((t.id = ar_btbs.ttf_id) AND (t.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))))));


--
-- Name: ar_btbs ar_btbs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_btbs_insert ON public.ar_btbs FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.ar_ttfs t
  WHERE ((t.id = ar_btbs.ttf_id) AND (t.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))))));


--
-- Name: ar_btbs ar_btbs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_btbs_read ON public.ar_btbs FOR SELECT TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.ar_ttfs t
  WHERE ((t.id = ar_btbs.ttf_id) AND (t.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))))));


--
-- Name: ar_ttfs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.ar_ttfs ENABLE ROW LEVEL SECURITY;

--
-- Name: ar_ttfs ar_ttfs_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_ttfs_delete ON public.ar_ttfs FOR DELETE TO authenticated USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))));


--
-- Name: ar_ttfs ar_ttfs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_ttfs_insert ON public.ar_ttfs FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))));


--
-- Name: ar_ttfs ar_ttfs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_ttfs_read ON public.ar_ttfs FOR SELECT TO authenticated USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))));


--
-- Name: ar_ttfs ar_ttfs_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ar_ttfs_update ON public.ar_ttfs FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text))))) WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('ceo'::text) OR public.has_role('finance_controller'::text) OR public.has_role('finance'::text)))));


--
-- Name: asset_categories; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: asset_categories asset_categories_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY asset_categories_insert ON public.asset_categories FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: asset_categories asset_categories_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY asset_categories_read ON public.asset_categories FOR SELECT TO authenticated USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: asset_categories asset_categories_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY asset_categories_update ON public.asset_categories FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND public.is_admin_or_above())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: asset_fuel_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_fuel_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: asset_locations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: asset_locations asset_locations_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY asset_locations_insert ON public.asset_locations FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: asset_locations asset_locations_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY asset_locations_read ON public.asset_locations FOR SELECT TO authenticated USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: asset_locations asset_locations_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY asset_locations_update ON public.asset_locations FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND public.is_admin_or_above())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: asset_maintenance_records; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_maintenance_records ENABLE ROW LEVEL SECURITY;

--
-- Name: asset_network; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_network ENABLE ROW LEVEL SECURITY;

--
-- Name: asset_software_licenses; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_software_licenses ENABLE ROW LEVEL SECURITY;

--
-- Name: asset_specifications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.asset_specifications ENABLE ROW LEVEL SECURITY;

--
-- Name: assets; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.assets ENABLE ROW LEVEL SECURITY;

--
-- Name: assets assets_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY assets_insert ON public.assets FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: assets assets_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY assets_read ON public.assets FOR SELECT TO authenticated USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: assets assets_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY assets_update ON public.assets FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND public.is_admin_or_above())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: audit_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_logs audit_logs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY audit_logs_insert ON public.audit_logs FOR INSERT WITH CHECK ((auth.uid() IS NOT NULL));


--
-- Name: audit_logs audit_logs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY audit_logs_read ON public.audit_logs FOR SELECT USING (public.is_admin_or_above());


--
-- Name: backfill_sp_order_items_20260808; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backfill_sp_order_items_20260808 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_b4_inquiries_20260725; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_b4_inquiries_20260725 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_dedup_accounts_20260725; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_dedup_accounts_20260725 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_dedup_activities_20260725; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_dedup_activities_20260725 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_dedup_alliance_20260725; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_dedup_alliance_20260725 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_dedup_inquiries_20260725; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_dedup_inquiries_20260725 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_dedup_quotations_20260725; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_dedup_quotations_20260725 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_leadpool_c1_won_20260724; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_leadpool_c1_won_20260724 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_leadpool_trap_20260724; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_leadpool_trap_20260724 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_prf_20260727; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_prf_20260727 ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_prf_cost_items_20260727; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.backup_prf_cost_items_20260727 ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_authorized_users; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_authorized_users ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_authorized_users bnf_authorized_users_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_authorized_users_insert ON public.bnf_authorized_users FOR INSERT WITH CHECK (public.is_super_admin());


--
-- Name: bnf_authorized_users bnf_authorized_users_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_authorized_users_read ON public.bnf_authorized_users FOR SELECT USING (public.is_super_admin());


--
-- Name: bnf_authorized_users bnf_authorized_users_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_authorized_users_update ON public.bnf_authorized_users FOR UPDATE USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: bnf_department_scopes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_department_scopes ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_department_scopes bnf_department_scopes_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_department_scopes_read ON public.bnf_department_scopes FOR SELECT USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: bnf_department_scopes bnf_department_scopes_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_department_scopes_write ON public.bnf_department_scopes USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: bnf_departments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_departments ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_departments bnf_departments_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_departments_insert ON public.bnf_departments FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: bnf_departments bnf_departments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_departments_read ON public.bnf_departments FOR SELECT USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL)) OR ((deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM public.bnf_department_scopes s
  WHERE ((s.department_id = bnf_departments.id) AND (s.company_id = public.get_user_company_id())))))));


--
-- Name: bnf_departments bnf_departments_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_departments_update ON public.bnf_departments FOR UPDATE TO authenticated USING ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id())))) WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: bnf_division_scopes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_division_scopes ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_division_scopes bnf_division_scopes_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_division_scopes_read ON public.bnf_division_scopes FOR SELECT USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: bnf_division_scopes bnf_division_scopes_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_division_scopes_write ON public.bnf_division_scopes USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: bnf_divisions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_divisions ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_divisions bnf_divisions_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_divisions_insert ON public.bnf_divisions FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: bnf_divisions bnf_divisions_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_divisions_read ON public.bnf_divisions FOR SELECT USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL)) OR ((deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM public.bnf_division_scopes s
  WHERE ((s.division_id = bnf_divisions.id) AND (s.company_id = public.get_user_company_id())))))));


--
-- Name: bnf_divisions bnf_divisions_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_divisions_update ON public.bnf_divisions FOR UPDATE TO authenticated USING ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id())))) WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: bnf_report_action_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_report_action_items ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_report_action_items bnf_report_action_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_action_items_insert ON public.bnf_report_action_items FOR INSERT WITH CHECK ((public.is_bnf_authorized() AND (public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM ((public.bnf_reports r
     LEFT JOIN public.bnf_department_scopes deps ON (((deps.department_id = r.department_id) AND (deps.company_id = public.get_user_company_id()))))
     LEFT JOIN public.bnf_division_scopes divs ON (((divs.division_id = r.division_id) AND (divs.company_id = public.get_user_company_id()))))
  WHERE ((r.id = bnf_report_action_items.report_id) AND (r.deleted_at IS NULL) AND ((r.company_id = public.get_user_company_id()) OR (deps.id IS NOT NULL) OR (divs.id IS NOT NULL))))))));


--
-- Name: bnf_report_action_items bnf_report_action_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_action_items_read ON public.bnf_report_action_items FOR SELECT USING ((public.is_bnf_authorized() AND (public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM ((public.bnf_reports r
     LEFT JOIN public.bnf_department_scopes deps ON (((deps.department_id = r.department_id) AND (deps.company_id = public.get_user_company_id()))))
     LEFT JOIN public.bnf_division_scopes divs ON (((divs.division_id = r.division_id) AND (divs.company_id = public.get_user_company_id()))))
  WHERE ((r.id = bnf_report_action_items.report_id) AND (r.deleted_at IS NULL) AND ((r.company_id = public.get_user_company_id()) OR (deps.id IS NOT NULL) OR (divs.id IS NOT NULL))))))));


--
-- Name: bnf_report_action_items bnf_report_action_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_action_items_update ON public.bnf_report_action_items FOR UPDATE USING ((public.is_bnf_authorized() AND (public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM ((public.bnf_reports r
     LEFT JOIN public.bnf_department_scopes deps ON (((deps.department_id = r.department_id) AND (deps.company_id = public.get_user_company_id()))))
     LEFT JOIN public.bnf_division_scopes divs ON (((divs.division_id = r.division_id) AND (divs.company_id = public.get_user_company_id()))))
  WHERE ((r.id = bnf_report_action_items.report_id) AND (r.deleted_at IS NULL) AND ((r.company_id = public.get_user_company_id()) OR (deps.id IS NOT NULL) OR (divs.id IS NOT NULL)))))))) WITH CHECK ((public.is_bnf_authorized() AND (public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM ((public.bnf_reports r
     LEFT JOIN public.bnf_department_scopes deps ON (((deps.department_id = r.department_id) AND (deps.company_id = public.get_user_company_id()))))
     LEFT JOIN public.bnf_division_scopes divs ON (((divs.division_id = r.division_id) AND (divs.company_id = public.get_user_company_id()))))
  WHERE ((r.id = bnf_report_action_items.report_id) AND (r.deleted_at IS NULL) AND ((r.company_id = public.get_user_company_id()) OR (deps.id IS NOT NULL) OR (divs.id IS NOT NULL))))))));


--
-- Name: bnf_report_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_report_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_report_logs bnf_report_logs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_logs_insert ON public.bnf_report_logs FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.bnf_reports r
  WHERE ((r.id = bnf_report_logs.report_id) AND (r.company_id = public.get_user_company_id()))))));


--
-- Name: bnf_report_logs bnf_report_logs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_logs_read ON public.bnf_report_logs FOR SELECT TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.bnf_reports r
  WHERE ((r.id = bnf_report_logs.report_id) AND (r.company_id = public.get_user_company_id()))))));


--
-- Name: bnf_report_related_departments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_report_related_departments ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_report_related_departments bnf_report_related_departments_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_related_departments_delete ON public.bnf_report_related_departments FOR DELETE TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.bnf_reports r
  WHERE ((r.id = bnf_report_related_departments.report_id) AND (r.company_id = public.get_user_company_id()) AND ((r.created_by = auth.uid()) OR public.is_admin_or_above()))))));


--
-- Name: bnf_report_related_departments bnf_report_related_departments_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_related_departments_insert ON public.bnf_report_related_departments FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.bnf_reports r
  WHERE ((r.id = bnf_report_related_departments.report_id) AND (r.company_id = public.get_user_company_id()) AND ((r.created_by = auth.uid()) OR public.is_admin_or_above()))))));


--
-- Name: bnf_report_related_departments bnf_report_related_departments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_report_related_departments_read ON public.bnf_report_related_departments FOR SELECT TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.bnf_reports r
  WHERE ((r.id = bnf_report_related_departments.report_id) AND (r.company_id = public.get_user_company_id()))))));


--
-- Name: bnf_reports; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.bnf_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: bnf_reports bnf_reports_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_reports_insert ON public.bnf_reports FOR INSERT WITH CHECK (((company_id = public.get_user_company_id()) AND (created_by = auth.uid()) AND public.is_bnf_authorized()));


--
-- Name: bnf_reports bnf_reports_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_reports_select ON public.bnf_reports FOR SELECT USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL) AND public.is_bnf_authorized())));


--
-- Name: bnf_reports bnf_reports_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY bnf_reports_update ON public.bnf_reports FOR UPDATE USING ((((company_id = public.get_user_company_id()) AND (deleted_at IS NULL)) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND (deleted_at IS NULL)) OR public.is_super_admin()));


--
-- Name: branches; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;

--
-- Name: branches branches_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY branches_insert ON public.branches FOR INSERT WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: branches branches_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY branches_read ON public.branches FOR SELECT TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL))));


--
-- Name: branches branches_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY branches_update ON public.branches FOR UPDATE USING ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id())))) WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: channel_types; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.channel_types ENABLE ROW LEVEL SECURITY;

--
-- Name: channel_types channel_types_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY channel_types_delete ON public.channel_types FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: channel_types channel_types_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY channel_types_insert ON public.channel_types FOR INSERT TO authenticated WITH CHECK (((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.is_admin_or_above()));


--
-- Name: channel_types channel_types_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY channel_types_read ON public.channel_types FOR SELECT TO authenticated USING ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (deleted_at IS NULL)) OR public.is_super_admin()));


--
-- Name: channel_types channel_types_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY channel_types_update ON public.channel_types FOR UPDATE TO authenticated USING (((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) OR public.is_super_admin())) WITH CHECK ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: chart_of_accounts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: chart_of_accounts chart_of_accounts_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY chart_of_accounts_insert ON public.chart_of_accounts FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND (public.has_role('finance_controller'::text) OR public.is_super_admin())));


--
-- Name: chart_of_accounts chart_of_accounts_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY chart_of_accounts_read ON public.chart_of_accounts FOR SELECT TO authenticated USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: chart_of_accounts chart_of_accounts_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY chart_of_accounts_update ON public.chart_of_accounts FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND (public.has_role('finance_controller'::text) OR public.is_super_admin()))) WITH CHECK (((company_id = public.get_user_company_id()) AND (public.has_role('finance_controller'::text) OR public.is_super_admin())));


--
-- Name: companies; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

--
-- Name: companies companies_read_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY companies_read_own ON public.companies FOR SELECT TO authenticated USING (((id = public.get_user_company_id()) OR (id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) OR public.is_super_admin()));


--
-- Name: companies companies_super_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY companies_super_admin_write ON public.companies TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: contacts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;

--
-- Name: contacts contacts_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY contacts_delete ON public.contacts FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: contacts contacts_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY contacts_insert ON public.contacts FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.accounts a
  WHERE (a.id = contacts.account_id))));


--
-- Name: contacts contacts_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY contacts_select ON public.contacts FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.accounts a
  WHERE (a.id = contacts.account_id))));


--
-- Name: contacts contacts_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY contacts_update ON public.contacts FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.accounts a
  WHERE (a.id = contacts.account_id))));


--
-- Name: cost_centers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.cost_centers ENABLE ROW LEVEL SECURITY;

--
-- Name: cost_centers cost_centers_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY cost_centers_insert ON public.cost_centers FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: cost_centers cost_centers_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY cost_centers_read ON public.cost_centers FOR SELECT TO authenticated USING (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: cost_centers cost_centers_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY cost_centers_update ON public.cost_centers FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND public.is_admin_or_above())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: currencies; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;

--
-- Name: currencies currencies_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY currencies_read_all ON public.currencies FOR SELECT TO authenticated USING (true);


--
-- Name: currencies currencies_super_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY currencies_super_admin_write ON public.currencies TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: customers customers_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY customers_insert ON public.customers FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: customers customers_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY customers_read ON public.customers FOR SELECT USING (((company_id = public.get_user_company_id()) AND ((deleted_at IS NULL) OR public.is_super_admin())));


--
-- Name: customers customers_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY customers_update ON public.customers FOR UPDATE USING ((company_id = public.get_user_company_id()));


--
-- Name: daily_report_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.daily_report_items ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_items daily_report_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY daily_report_items_insert ON public.daily_report_items FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (created_by = auth.uid()))));


--
-- Name: daily_report_items daily_report_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY daily_report_items_read ON public.daily_report_items FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: daily_report_items daily_report_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY daily_report_items_update ON public.daily_report_items FOR UPDATE USING ((public.is_super_admin() OR (company_id = public.get_user_company_id()))) WITH CHECK ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: dc_master; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.dc_master ENABLE ROW LEVEL SECURITY;

--
-- Name: dc_master dc_master_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dc_master_delete ON public.dc_master FOR DELETE USING (public.is_super_admin());


--
-- Name: dc_master dc_master_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dc_master_insert ON public.dc_master FOR INSERT WITH CHECK ((public.is_super_admin() OR (((company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: dc_master dc_master_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dc_master_read ON public.dc_master FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: dc_master dc_master_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dc_master_update ON public.dc_master FOR UPDATE USING ((public.is_super_admin() OR (((company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: deal_handovers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.deal_handovers ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_incidents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.delivery_incidents ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_incidents delivery_incidents_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY delivery_incidents_delete ON public.delivery_incidents FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: delivery_incidents delivery_incidents_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY delivery_incidents_insert ON public.delivery_incidents FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: delivery_incidents delivery_incidents_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY delivery_incidents_read ON public.delivery_incidents FOR SELECT TO authenticated USING ((public.is_super_admin() OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: delivery_incidents delivery_incidents_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY delivery_incidents_update ON public.delivery_incidents FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR public.has_role('operations'::text))))) WITH CHECK ((public.is_super_admin() OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: delivery_note_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.delivery_note_items ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_notes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.delivery_notes ENABLE ROW LEVEL SECURITY;

--
-- Name: departments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;

--
-- Name: departments departments_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY departments_insert ON public.departments FOR INSERT WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: departments departments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY departments_read ON public.departments FOR SELECT TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL))));


--
-- Name: departments departments_select_global; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY departments_select_global ON public.departments FOR SELECT TO authenticated USING (((company_id IS NULL) AND (deleted_at IS NULL)));


--
-- Name: departments departments_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY departments_update ON public.departments FOR UPDATE USING ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id())))) WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: delivery_notes dn_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dn_delete ON public.delivery_notes FOR DELETE TO authenticated USING (true);


--
-- Name: delivery_notes dn_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dn_insert ON public.delivery_notes FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: delivery_notes dn_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dn_read ON public.delivery_notes FOR SELECT TO authenticated USING (true);


--
-- Name: delivery_notes dn_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dn_update ON public.delivery_notes FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: delivery_note_items dni_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dni_delete ON public.delivery_note_items FOR DELETE TO authenticated USING (true);


--
-- Name: delivery_note_items dni_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dni_insert ON public.delivery_note_items FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: delivery_note_items dni_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dni_read ON public.delivery_note_items FOR SELECT TO authenticated USING (true);


--
-- Name: delivery_note_items dni_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dni_update ON public.delivery_note_items FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: document_numbering; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.document_numbering ENABLE ROW LEVEL SECURITY;

--
-- Name: document_numbering document_numbering_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_numbering_access ON public.document_numbering TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: document_sequences; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.document_sequences ENABLE ROW LEVEL SECURITY;

--
-- Name: document_sequences document_sequences_increment; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_sequences_increment ON public.document_sequences FOR UPDATE TO authenticated USING ((company_id = public.get_user_company_id())) WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: document_sequences document_sequences_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_sequences_insert ON public.document_sequences FOR INSERT TO authenticated WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: POLICY document_sequences_insert ON document_sequences; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON POLICY document_sequences_insert ON public.document_sequences IS 'Any authenticated company user may insert a new sequence row. Atomic increment is handled by increment_document_sequence() RPC (SECURITY DEFINER). Policy relaxed from admin-only in migration 023 to support first-document-of-year by non-admin staff across all document types.';


--
-- Name: document_sequences document_sequences_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_sequences_read ON public.document_sequences FOR SELECT TO authenticated USING ((company_id = public.get_user_company_id()));


--
-- Name: document_templates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.document_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: document_templates document_templates_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_templates_access ON public.document_templates TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: document_types; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

--
-- Name: document_types document_types_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_types_insert ON public.document_types FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: document_types document_types_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_types_read ON public.document_types FOR SELECT TO authenticated USING ((company_id = public.get_user_company_id()));


--
-- Name: document_types document_types_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY document_types_update ON public.document_types FOR UPDATE TO authenticated USING ((company_id = public.get_user_company_id())) WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: dropdown_options; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.dropdown_options ENABLE ROW LEVEL SECURITY;

--
-- Name: dropdown_options dropdown_options_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dropdown_options_delete ON public.dropdown_options FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: dropdown_options dropdown_options_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dropdown_options_insert ON public.dropdown_options FOR INSERT TO authenticated WITH CHECK (public.is_super_admin());


--
-- Name: dropdown_options dropdown_options_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dropdown_options_read ON public.dropdown_options FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND ((company_id IS NULL) OR (company_id = public.get_user_company_id()) OR public.is_super_admin())));


--
-- Name: dropdown_options dropdown_options_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY dropdown_options_update ON public.dropdown_options FOR UPDATE TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: entity_bank_accounts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.entity_bank_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: entity_bank_accounts entity_bank_accounts_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY entity_bank_accounts_access ON public.entity_bank_accounts TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: entity_finance_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.entity_finance_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: entity_finance_settings entity_finance_settings_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY entity_finance_settings_access ON public.entity_finance_settings TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: entity_signatories; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.entity_signatories ENABLE ROW LEVEL SECURITY;

--
-- Name: entity_signatories entity_signatories_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY entity_signatories_access ON public.entity_signatories TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: exchange_rates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.exchange_rates ENABLE ROW LEVEL SECURITY;

--
-- Name: exchange_rates exchange_rates_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY exchange_rates_insert ON public.exchange_rates FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('finance_controller'::text))));


--
-- Name: exchange_rates exchange_rates_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY exchange_rates_read ON public.exchange_rates FOR SELECT TO authenticated USING ((company_id = public.get_user_company_id()));


--
-- Name: asset_fuel_logs fuel_logs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY fuel_logs_insert ON public.asset_fuel_logs FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: asset_fuel_logs fuel_logs_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY fuel_logs_select ON public.asset_fuel_logs FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: asset_fuel_logs fuel_logs_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY fuel_logs_update ON public.asset_fuel_logs FOR UPDATE USING ((company_id = public.get_user_company_id()));


--
-- Name: deal_handovers handover_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY handover_read ON public.deal_handovers FOR SELECT USING ((company_id = public.get_user_company_id()));


--
-- Name: deal_handovers handover_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY handover_update ON public.deal_handovers FOR UPDATE USING (((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))));


--
-- Name: deal_handovers handover_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY handover_write ON public.deal_handovers FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: hrga_approval_configs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_approval_configs ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_approval_configs hrga_approval_configs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_approval_configs_insert ON public.hrga_approval_configs FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))));


--
-- Name: hrga_approval_configs hrga_approval_configs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_approval_configs_read ON public.hrga_approval_configs FOR SELECT TO authenticated USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: hrga_approval_configs hrga_approval_configs_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_approval_configs_update ON public.hrga_approval_configs FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text))))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))));


--
-- Name: hrga_notification_queue; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_notification_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_notification_queue hrga_notification_queue_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_notification_queue_insert ON public.hrga_notification_queue FOR INSERT TO authenticated WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: hrga_notification_queue hrga_notification_queue_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_notification_queue_read ON public.hrga_notification_queue FOR SELECT TO authenticated USING ((((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.is_manager_or_above())) OR public.is_super_admin()));


--
-- Name: hrga_notification_queue hrga_notification_queue_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_notification_queue_update ON public.hrga_notification_queue FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above()))) WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: hrga_offboarding_checklists; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_offboarding_checklists ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_checklists_insert ON public.hrga_offboarding_checklists FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))));


--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_checklists_read ON public.hrga_offboarding_checklists FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND (public.is_super_admin() OR (company_id = public.get_user_company_id()))));


--
-- Name: hrga_offboarding_checklists hrga_offboarding_checklists_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_checklists_update ON public.hrga_offboarding_checklists FOR UPDATE TO authenticated USING (((deleted_at IS NULL) AND (public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))));


--
-- Name: hrga_offboarding_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_offboarding_items ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_offboarding_items hrga_offboarding_items_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_items_delete ON public.hrga_offboarding_items FOR DELETE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_offboarding_items.request_id) AND (r.company_id = public.get_user_company_id()) AND public.is_manager_or_above()))) OR public.is_super_admin()));


--
-- Name: hrga_offboarding_items hrga_offboarding_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_items_insert ON public.hrga_offboarding_items FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_offboarding_items.request_id) AND (r.company_id = public.get_user_company_id()) AND (r.deleted_at IS NULL)))));


--
-- Name: hrga_offboarding_items hrga_offboarding_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_items_read ON public.hrga_offboarding_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_offboarding_items.request_id) AND (r.deleted_at IS NULL) AND (public.is_super_admin() OR (r.company_id = public.get_user_company_id()))))));


--
-- Name: hrga_offboarding_items hrga_offboarding_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_offboarding_items_update ON public.hrga_offboarding_items FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_offboarding_items.request_id) AND (r.deleted_at IS NULL) AND (r.company_id = public.get_user_company_id()) AND (public.is_super_admin() OR public.is_admin_or_above() OR public.has_role('hrga'::text) OR public.has_role('it'::text) OR public.has_role('finance'::text)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_offboarding_items.request_id) AND (r.company_id = public.get_user_company_id())))));


--
-- Name: hrga_request_approvals; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_request_approvals ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_request_approvals hrga_request_approvals_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_approvals_insert ON public.hrga_request_approvals FOR INSERT TO authenticated WITH CHECK (((approver_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_approvals.request_id) AND (r.company_id = public.get_user_company_id()) AND (r.deleted_at IS NULL))))));


--
-- Name: hrga_request_approvals hrga_request_approvals_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_approvals_read ON public.hrga_request_approvals FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_approvals.request_id) AND (r.deleted_at IS NULL) AND (public.is_super_admin() OR (r.company_id = public.get_user_company_id()))))));


--
-- Name: hrga_request_attachments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_request_attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_request_attachments hrga_request_attachments_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_attachments_insert ON public.hrga_request_attachments FOR INSERT TO authenticated WITH CHECK (((uploaded_by = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_attachments.request_id) AND (r.deleted_at IS NULL) AND (r.company_id = public.get_user_company_id()))))));


--
-- Name: hrga_request_attachments hrga_request_attachments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_attachments_read ON public.hrga_request_attachments FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_attachments.request_id) AND (r.deleted_at IS NULL) AND (public.is_super_admin() OR (r.company_id = public.get_user_company_id())))))));


--
-- Name: hrga_request_attachments hrga_request_attachments_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_attachments_update ON public.hrga_request_attachments FOR UPDATE TO authenticated USING (((deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_attachments.request_id) AND (r.company_id = public.get_user_company_id())))) AND (public.is_super_admin() OR public.is_admin_or_above() OR public.has_role('hrga'::text) OR (uploaded_by = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_attachments.request_id) AND (r.company_id = public.get_user_company_id())))));


--
-- Name: hrga_request_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_request_items ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_request_items hrga_request_items_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_items_delete ON public.hrga_request_items FOR DELETE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_items.request_id) AND ((r.requester_id = auth.uid()) OR public.is_manager_or_above()) AND (r.company_id = public.get_user_company_id())))) OR public.is_super_admin()));


--
-- Name: hrga_request_items hrga_request_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_items_insert ON public.hrga_request_items FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_items.request_id) AND (r.requester_id = auth.uid()) AND ((r.status)::text = ANY ((ARRAY['draft'::character varying, 'submitted'::character varying])::text[])) AND (r.company_id = public.get_user_company_id())))));


--
-- Name: POLICY hrga_request_items_insert ON hrga_request_items; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON POLICY hrga_request_items_insert ON public.hrga_request_items IS 'Requester can insert line items while parent request is draft or submitted. Items are created atomically with the header in submitHrgaRequest(). Status guard prevents adding items to requests already under_review or approved.';


--
-- Name: hrga_request_items hrga_request_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_items_read ON public.hrga_request_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_items.request_id) AND (r.deleted_at IS NULL) AND (public.is_super_admin() OR (r.company_id = public.get_user_company_id()))))));


--
-- Name: hrga_request_items hrga_request_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_items_update ON public.hrga_request_items FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_items.request_id) AND (r.requester_id = auth.uid()) AND ((r.status)::text = ANY ((ARRAY['draft'::character varying, 'revision_requested'::character varying])::text[])) AND (r.company_id = public.get_user_company_id()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.hrga_requests r
  WHERE ((r.id = hrga_request_items.request_id) AND (r.requester_id = auth.uid()) AND (r.company_id = public.get_user_company_id())))));


--
-- Name: hrga_request_types; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_request_types ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_request_types hrga_request_types_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_types_insert ON public.hrga_request_types FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))));


--
-- Name: hrga_request_types hrga_request_types_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_types_read ON public.hrga_request_types FOR SELECT TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL))));


--
-- Name: hrga_request_types hrga_request_types_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_request_types_update ON public.hrga_request_types FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text))))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('hrga'::text)))));


--
-- Name: hrga_requests; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.hrga_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: hrga_requests hrga_requests_cancel_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_requests_cancel_own ON public.hrga_requests FOR UPDATE TO authenticated USING (((requester_id = auth.uid()) AND ((status)::text = 'submitted'::text))) WITH CHECK (((requester_id = auth.uid()) AND ((status)::text = 'cancelled'::text)));


--
-- Name: hrga_requests hrga_requests_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_requests_insert ON public.hrga_requests FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND (requester_id = auth.uid())));


--
-- Name: hrga_requests hrga_requests_read_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_requests_read_own ON public.hrga_requests FOR SELECT TO authenticated USING (((requester_id = auth.uid()) OR ((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.is_manager_or_above() OR public.has_role('hrga'::text) OR public.has_role('it'::text) OR public.has_role('finance'::text))) OR public.is_super_admin()));


--
-- Name: hrga_requests hrga_requests_update_draft; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY hrga_requests_update_draft ON public.hrga_requests FOR UPDATE TO authenticated USING (((deleted_at IS NULL) AND (company_id = public.get_user_company_id()) AND (requester_id = auth.uid()) AND ((status)::text = ANY ((ARRAY['draft'::character varying, 'revision_requested'::character varying])::text[])))) WITH CHECK (((company_id = public.get_user_company_id()) AND (requester_id = auth.uid())));


--
-- Name: inquiries; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.inquiries ENABLE ROW LEVEL SECURITY;

--
-- Name: inquiries inquiries_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiries_insert ON public.inquiries FOR INSERT WITH CHECK ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)));


--
-- Name: inquiries inquiries_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiries_read ON public.inquiries FOR SELECT USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR (created_by = auth.uid()) OR (public.has_role('procurement'::text) AND (EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.inquiry_id = inquiries.id) AND (p.company_id = inquiries.company_id) AND (p.deleted_at IS NULL)))))))));


--
-- Name: inquiries inquiries_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiries_update ON public.inquiries FOR UPDATE USING ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR (created_by = auth.uid()))) OR public.is_super_admin())) WITH CHECK ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: inquiry_comment_mentions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.inquiry_comment_mentions ENABLE ROW LEVEL SECURITY;

--
-- Name: inquiry_comment_mentions inquiry_comment_mentions_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiry_comment_mentions_insert ON public.inquiry_comment_mentions FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.inquiry_comments c
  WHERE ((c.id = inquiry_comment_mentions.comment_id) AND (c.created_by = auth.uid())))));


--
-- Name: inquiry_comment_mentions inquiry_comment_mentions_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiry_comment_mentions_read ON public.inquiry_comment_mentions FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (public.inquiry_comments c
     JOIN public.inquiries i ON ((i.id = c.inquiry_id)))
  WHERE (c.id = inquiry_comment_mentions.comment_id))));


--
-- Name: inquiry_comments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.inquiry_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: inquiry_comments inquiry_comments_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiry_comments_insert ON public.inquiry_comments FOR INSERT WITH CHECK (((created_by = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.inquiries i
  WHERE (i.id = inquiry_comments.inquiry_id)))));


--
-- Name: inquiry_comments inquiry_comments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiry_comments_read ON public.inquiry_comments FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.inquiries i
  WHERE (i.id = inquiry_comments.inquiry_id))));


--
-- Name: inquiry_comments inquiry_comments_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiry_comments_update ON public.inquiry_comments FOR UPDATE USING ((created_by = auth.uid())) WITH CHECK ((created_by = auth.uid()));


--
-- Name: inquiry_status_history; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.inquiry_status_history ENABLE ROW LEVEL SECURITY;

--
-- Name: inquiry_status_history inquiry_status_history_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY inquiry_status_history_read ON public.inquiry_status_history FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.inquiries i
  WHERE (i.id = inquiry_status_history.inquiry_id))));


--
-- Name: journal_entries; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_entries journal_entries_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY journal_entries_read ON public.journal_entries FOR SELECT TO authenticated USING ((public.is_super_admin() OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: journal_entry_lines; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.journal_entry_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_entry_lines journal_entry_lines_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY journal_entry_lines_read ON public.journal_entry_lines FOR SELECT TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.journal_entries je
  WHERE ((je.id = journal_entry_lines.journal_entry_id) AND (je.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)))))));


--
-- Name: loss_reasons; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.loss_reasons ENABLE ROW LEVEL SECURITY;

--
-- Name: loss_reasons loss_reasons_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY loss_reasons_delete ON public.loss_reasons FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: loss_reasons loss_reasons_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY loss_reasons_insert ON public.loss_reasons FOR INSERT TO authenticated WITH CHECK (public.is_admin_or_above());


--
-- Name: loss_reasons loss_reasons_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY loss_reasons_read ON public.loss_reasons FOR SELECT TO authenticated USING (((deleted_at IS NULL) OR public.is_super_admin()));


--
-- Name: loss_reasons loss_reasons_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY loss_reasons_update ON public.loss_reasons FOR UPDATE TO authenticated USING (public.is_admin_or_above()) WITH CHECK (public.is_admin_or_above());


--
-- Name: asset_maintenance_records maintenance_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY maintenance_insert ON public.asset_maintenance_records FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: asset_maintenance_records maintenance_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY maintenance_select ON public.asset_maintenance_records FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: asset_maintenance_records maintenance_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY maintenance_update ON public.asset_maintenance_records FOR UPDATE USING ((company_id = public.get_user_company_id()));


--
-- Name: meeting_moms; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.meeting_moms ENABLE ROW LEVEL SECURITY;

--
-- Name: menu_actions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.menu_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: menu_actions menu_actions_admin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY menu_actions_admin_only ON public.menu_actions TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: menu_actions menu_actions_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY menu_actions_read_all ON public.menu_actions FOR SELECT USING (true);


--
-- Name: module_actions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.module_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: module_actions module_actions_admin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY module_actions_admin_only ON public.module_actions TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: module_actions module_actions_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY module_actions_read_all ON public.module_actions FOR SELECT USING (true);


--
-- Name: module_menus; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.module_menus ENABLE ROW LEVEL SECURITY;

--
-- Name: module_menus module_menus_admin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY module_menus_admin_only ON public.module_menus TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: module_menus module_menus_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY module_menus_read_all ON public.module_menus FOR SELECT USING (true);


--
-- Name: modules; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.modules ENABLE ROW LEVEL SECURITY;

--
-- Name: modules modules_admin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY modules_admin_only ON public.modules TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: modules modules_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY modules_read_all ON public.modules FOR SELECT USING (true);


--
-- Name: mom_action_plans; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.mom_action_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: mom_action_plans mom_children_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_children_delete ON public.mom_action_plans FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_action_plans.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_action_plans mom_children_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_children_insert ON public.mom_action_plans FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_action_plans.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_action_plans mom_children_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_children_read ON public.mom_action_plans FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_action_plans.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_action_plans mom_children_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_children_update ON public.mom_action_plans FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_action_plans.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_improvements; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.mom_improvements ENABLE ROW LEVEL SECURITY;

--
-- Name: mom_improvements mom_improvements_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_improvements_delete ON public.mom_improvements FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_improvements.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_improvements mom_improvements_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_improvements_insert ON public.mom_improvements FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_improvements.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_improvements mom_improvements_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_improvements_read ON public.mom_improvements FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_improvements.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_improvements mom_improvements_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_improvements_update ON public.mom_improvements FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_improvements.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_issues; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.mom_issues ENABLE ROW LEVEL SECURITY;

--
-- Name: mom_issues mom_issues_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_issues_delete ON public.mom_issues FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_issues.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_issues mom_issues_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_issues_insert ON public.mom_issues FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_issues.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_issues mom_issues_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_issues_read ON public.mom_issues FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_issues.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_issues mom_issues_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_issues_update ON public.mom_issues FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_issues.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_progress_updates mom_progress_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_progress_delete ON public.mom_progress_updates FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_progress_updates.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_progress_updates mom_progress_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_progress_insert ON public.mom_progress_updates FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_progress_updates.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_progress_updates mom_progress_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_progress_read ON public.mom_progress_updates FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_progress_updates.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_progress_updates mom_progress_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY mom_progress_update ON public.mom_progress_updates FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.meeting_moms m
  WHERE ((m.id = mom_progress_updates.mom_id) AND (m.company_id = public.get_user_company_id())))));


--
-- Name: mom_progress_updates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.mom_progress_updates ENABLE ROW LEVEL SECURITY;

--
-- Name: meeting_moms moms_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY moms_delete ON public.meeting_moms FOR DELETE USING (public.is_super_admin());


--
-- Name: meeting_moms moms_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY moms_insert ON public.meeting_moms FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: meeting_moms moms_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY moms_read ON public.meeting_moms FOR SELECT USING ((company_id = public.get_user_company_id()));


--
-- Name: meeting_moms moms_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY moms_update ON public.meeting_moms FOR UPDATE USING (((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))));


--
-- Name: asset_network network_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY network_insert ON public.asset_network FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: asset_network network_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY network_select ON public.asset_network FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: asset_network network_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY network_update ON public.asset_network FOR UPDATE USING ((company_id = public.get_user_company_id()));


--
-- Name: notification_rules; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.notification_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_rules notification_rules_access; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY notification_rules_access ON public.notification_rules TO authenticated USING ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY notifications_delete ON public.notifications FOR DELETE TO authenticated USING ((user_id = auth.uid()));


--
-- Name: notifications notifications_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY notifications_insert ON public.notifications FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: notifications notifications_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY notifications_read ON public.notifications FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: notifications notifications_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY notifications_update ON public.notifications FOR UPDATE TO authenticated USING ((user_id = auth.uid()));


--
-- Name: payment_terms; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.payment_terms ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_terms payment_terms_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY payment_terms_insert ON public.payment_terms FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('finance_controller'::text))));


--
-- Name: payment_terms payment_terms_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY payment_terms_read ON public.payment_terms FOR SELECT TO authenticated USING ((((company_id = public.get_user_company_id()) AND (deleted_at IS NULL)) OR public.is_super_admin()));


--
-- Name: payment_terms payment_terms_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY payment_terms_update ON public.payment_terms FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND ((deleted_at IS NULL) OR public.is_super_admin()))) WITH CHECK (((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('finance_controller'::text))));


--
-- Name: permissions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: permissions permissions_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY permissions_read_all ON public.permissions FOR SELECT TO authenticated USING (true);


--
-- Name: permissions permissions_super_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY permissions_super_admin_write ON public.permissions TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: picking_list_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.picking_list_items ENABLE ROW LEVEL SECURITY;

--
-- Name: picking_list_materials; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.picking_list_materials ENABLE ROW LEVEL SECURITY;

--
-- Name: picking_lists; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.picking_lists ENABLE ROW LEVEL SECURITY;

--
-- Name: picking_lists picking_lists_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY picking_lists_delete ON public.picking_lists FOR DELETE TO authenticated USING (true);


--
-- Name: picking_lists picking_lists_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY picking_lists_insert ON public.picking_lists FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: picking_lists picking_lists_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY picking_lists_read ON public.picking_lists FOR SELECT TO authenticated USING (true);


--
-- Name: picking_lists picking_lists_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY picking_lists_update ON public.picking_lists FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: picking_list_items pli_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pli_delete ON public.picking_list_items FOR DELETE TO authenticated USING (true);


--
-- Name: picking_list_items pli_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pli_insert ON public.picking_list_items FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: picking_list_items pli_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pli_read ON public.picking_list_items FOR SELECT TO authenticated USING (true);


--
-- Name: picking_list_items pli_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pli_update ON public.picking_list_items FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: picking_list_materials plm_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY plm_delete ON public.picking_list_materials FOR DELETE TO authenticated USING (true);


--
-- Name: picking_list_materials plm_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY plm_insert ON public.picking_list_materials FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: picking_list_materials plm_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY plm_read ON public.picking_list_materials FOR SELECT TO authenticated USING (true);


--
-- Name: picking_list_materials plm_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY plm_update ON public.picking_list_materials FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: positions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.positions ENABLE ROW LEVEL SECURITY;

--
-- Name: positions positions_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY positions_insert ON public.positions FOR INSERT WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: positions positions_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY positions_read ON public.positions FOR SELECT TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (deleted_at IS NULL))));


--
-- Name: positions positions_select_global; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY positions_select_global ON public.positions FOR SELECT TO authenticated USING (((company_id IS NULL) AND (deleted_at IS NULL)));


--
-- Name: positions positions_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY positions_update ON public.positions FOR UPDATE USING ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id())))) WITH CHECK ((public.is_super_admin() OR (public.is_admin_or_above() AND (company_id = public.get_user_company_id()))));


--
-- Name: product_price_history pph_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pph_read ON public.product_price_history FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: prf; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prf ENABLE ROW LEVEL SECURITY;

--
-- Name: prf_cost_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prf_cost_items ENABLE ROW LEVEL SECURITY;

--
-- Name: prf_cost_items prf_cost_items_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_cost_items_delete ON public.prf_cost_items FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_cost_items.prf_id) AND (public.is_super_admin() OR ((p.deleted_at IS NULL) AND (p.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND ((p.status)::text = ANY (ARRAY['SUBMITTED'::text, 'ACKNOWLEDGED'::text, 'QUOTED'::text])) AND ((p.acknowledged_by IS NULL) OR (p.acknowledged_by = auth.uid()))))))));


--
-- Name: prf_cost_items prf_cost_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_cost_items_insert ON public.prf_cost_items FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_cost_items.prf_id) AND (public.is_super_admin() OR ((p.deleted_at IS NULL) AND (p.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND ((p.status)::text = ANY (ARRAY['SUBMITTED'::text, 'ACKNOWLEDGED'::text, 'QUOTED'::text])) AND ((p.acknowledged_by IS NULL) OR (p.acknowledged_by = auth.uid()))))))));


--
-- Name: prf_cost_items prf_cost_items_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_cost_items_select ON public.prf_cost_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_cost_items.prf_id) AND (public.is_super_admin() OR ((p.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND ((p.created_by = auth.uid()) OR public.has_role('procurement'::text) OR public.is_manager_or_above())))))));


--
-- Name: prf_cost_items prf_cost_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_cost_items_update ON public.prf_cost_items FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_cost_items.prf_id) AND (public.is_super_admin() OR ((p.deleted_at IS NULL) AND (p.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND ((p.status)::text = ANY (ARRAY['SUBMITTED'::text, 'ACKNOWLEDGED'::text, 'QUOTED'::text])) AND ((p.acknowledged_by IS NULL) OR (p.acknowledged_by = auth.uid())))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_cost_items.prf_id) AND (public.is_super_admin() OR ((p.deleted_at IS NULL) AND (p.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND ((p.status)::text = ANY (ARRAY['SUBMITTED'::text, 'ACKNOWLEDGED'::text, 'QUOTED'::text])) AND ((p.acknowledged_by IS NULL) OR (p.acknowledged_by = auth.uid()))))))));


--
-- Name: prf prf_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_insert ON public.prf FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (created_by = auth.uid()) AND (public.has_role('sales'::text) OR public.has_role('gm_bd'::text)))));


--
-- Name: prf prf_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_select ON public.prf FOR SELECT USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND ((created_by = auth.uid()) OR public.has_role('procurement'::text) OR public.is_manager_or_above()))));


--
-- Name: prf prf_update_draft; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_update_draft ON public.prf FOR UPDATE USING ((public.is_super_admin() OR ((deleted_at IS NULL) AND (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (created_by = auth.uid()) AND ((status)::text = 'DRAFT'::text)))) WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (created_by = auth.uid()))));


--
-- Name: prf prf_update_status; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_update_status ON public.prf FOR UPDATE USING ((public.is_super_admin() OR ((deleted_at IS NULL) AND (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND ((status)::text = ANY (ARRAY['SUBMITTED'::text, 'ACKNOWLEDGED'::text, 'QUOTED'::text])) AND ((acknowledged_by IS NULL) OR (acknowledged_by = auth.uid()))))) WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text))));


--
-- Name: prf_vendor_offers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prf_vendor_offers ENABLE ROW LEVEL SECURITY;

--
-- Name: prf_vendor_offers prf_vendor_offers_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_vendor_offers_delete ON public.prf_vendor_offers FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: prf_vendor_offers prf_vendor_offers_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_vendor_offers_insert ON public.prf_vendor_offers FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND (created_by = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_vendor_offers.prf_id) AND (p.acknowledged_by = auth.uid())))))));


--
-- Name: prf_vendor_offers prf_vendor_offers_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_vendor_offers_select ON public.prf_vendor_offers FOR SELECT USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.has_role('procurement'::text) OR public.is_manager_or_above() OR (EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_vendor_offers.prf_id) AND (p.created_by = auth.uid()))))))));


--
-- Name: prf_vendor_offers prf_vendor_offers_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prf_vendor_offers_update ON public.prf_vendor_offers FOR UPDATE USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND (EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_vendor_offers.prf_id) AND (p.acknowledged_by = auth.uid()))))))) WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.has_role('procurement'::text) AND (EXISTS ( SELECT 1
   FROM public.prf p
  WHERE ((p.id = prf_vendor_offers.prf_id) AND (p.acknowledged_by = auth.uid())))))));


--
-- Name: product_price_history; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.product_price_history ENABLE ROW LEVEL SECURITY;

--
-- Name: product_warehouse_location; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.product_warehouse_location ENABLE ROW LEVEL SECURITY;

--
-- Name: products; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

--
-- Name: products products_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY products_insert ON public.products FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND public.is_admin_or_above()));


--
-- Name: products products_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY products_read ON public.products FOR SELECT USING ((public.is_super_admin() OR (((company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))) AND ((deleted_at IS NULL) OR public.is_super_admin()))));


--
-- Name: products products_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY products_update ON public.products FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND ((deleted_at IS NULL) OR public.is_super_admin())))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above())));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY profiles_read ON public.profiles FOR SELECT TO authenticated USING (true);


--
-- Name: profiles profiles_read_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY profiles_read_own ON public.profiles FOR SELECT USING ((auth.uid() = id));


--
-- Name: profiles profiles_service_role_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY profiles_service_role_read ON public.profiles FOR SELECT USING ((auth.role() = 'service_role'::text));


--
-- Name: profiles profiles_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY profiles_update ON public.profiles FOR UPDATE TO authenticated USING (((id = auth.uid()) OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin())) WITH CHECK (((id = auth.uid()) OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: accounts prospects_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prospects_insert ON public.accounts FOR INSERT WITH CHECK ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)));


--
-- Name: accounts prospects_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prospects_read ON public.accounts FOR SELECT USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR (assigned_to = auth.uid()) OR (created_by = auth.uid()) OR (public.has_role('operations'::text) AND ((account_status)::text = 'customer'::text)) OR public.has_role('procurement'::text)))));


--
-- Name: accounts prospects_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY prospects_update ON public.accounts FOR UPDATE USING ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR (assigned_to = auth.uid()) OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: product_warehouse_location pwl_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pwl_delete ON public.product_warehouse_location FOR DELETE TO authenticated USING (true);


--
-- Name: product_warehouse_location pwl_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pwl_insert ON public.product_warehouse_location FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: product_warehouse_location pwl_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pwl_read ON public.product_warehouse_location FOR SELECT TO authenticated USING (true);


--
-- Name: product_warehouse_location pwl_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pwl_update ON public.product_warehouse_location FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: quotation_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.quotation_items ENABLE ROW LEVEL SECURITY;

--
-- Name: quotation_items quotation_items_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotation_items_delete ON public.quotation_items FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.quotations q
  WHERE ((q.id = quotation_items.quotation_id) AND ((q.company_id = public.get_user_company_id()) OR public.is_super_admin())))));


--
-- Name: quotation_items quotation_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotation_items_insert ON public.quotation_items FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.quotations q
  WHERE ((q.id = quotation_items.quotation_id) AND ((q.company_id = public.get_user_company_id()) OR public.is_super_admin())))));


--
-- Name: quotation_items quotation_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotation_items_read ON public.quotation_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.quotations q
  WHERE ((q.id = quotation_items.quotation_id) AND ((q.company_id = public.get_user_company_id()) OR public.is_super_admin())))));


--
-- Name: quotation_items quotation_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotation_items_update ON public.quotation_items FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.quotations q
  WHERE ((q.id = quotation_items.quotation_id) AND ((q.company_id = public.get_user_company_id()) OR public.is_super_admin()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.quotations q
  WHERE ((q.id = quotation_items.quotation_id) AND ((q.company_id = public.get_user_company_id()) OR public.is_super_admin())))));


--
-- Name: quotations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.quotations ENABLE ROW LEVEL SECURITY;

--
-- Name: quotations quotations_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotations_insert ON public.quotations FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) OR public.is_super_admin()));


--
-- Name: quotations quotations_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotations_read ON public.quotations FOR SELECT USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: quotations quotations_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY quotations_update ON public.quotations FOR UPDATE USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))) OR public.is_super_admin())) WITH CHECK ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: rate_sheets; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.rate_sheets ENABLE ROW LEVEL SECURITY;

--
-- Name: rate_sheets rate_sheets_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rate_sheets_delete ON public.rate_sheets FOR DELETE TO authenticated USING (((created_by = auth.uid()) OR public.is_manager_or_above()));


--
-- Name: rate_sheets rate_sheets_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rate_sheets_insert ON public.rate_sheets FOR INSERT TO authenticated WITH CHECK ((created_by = auth.uid()));


--
-- Name: rate_sheets rate_sheets_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rate_sheets_select ON public.rate_sheets FOR SELECT TO authenticated USING (((created_by = auth.uid()) OR public.is_manager_or_above()));


--
-- Name: rate_sheets rate_sheets_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rate_sheets_update ON public.rate_sheets FOR UPDATE TO authenticated USING ((((created_by = auth.uid()) OR public.is_manager_or_above()) AND ((valid_until IS NULL) OR (valid_until >= CURRENT_DATE)))) WITH CHECK ((((created_by = auth.uid()) OR public.is_manager_or_above()) AND ((valid_until IS NULL) OR (valid_until >= CURRENT_DATE))));


--
-- Name: role_menu_permissions rmp_admin_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rmp_admin_all ON public.role_menu_permissions TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: role_menu_permissions rmp_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rmp_select ON public.role_menu_permissions FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.user_roles ur
  WHERE ((ur.role_id = role_menu_permissions.role_id) AND (ur.user_id = auth.uid()) AND (ur.is_active = true)))));


--
-- Name: role_menu_permissions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.role_menu_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permission_templates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.role_permission_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permissions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permissions role_permissions_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY role_permissions_delete ON public.role_permissions FOR DELETE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.roles r
  WHERE ((r.id = role_permissions.role_id) AND (r.company_id = public.get_user_company_id())))) AND public.is_admin_or_above()));


--
-- Name: role_permissions role_permissions_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY role_permissions_insert ON public.role_permissions FOR INSERT TO authenticated WITH CHECK (((EXISTS ( SELECT 1
   FROM public.roles r
  WHERE ((r.id = role_permissions.role_id) AND (r.company_id = public.get_user_company_id())))) AND public.is_admin_or_above()));


--
-- Name: role_permissions role_permissions_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY role_permissions_read ON public.role_permissions FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.roles r
  WHERE ((r.id = role_permissions.role_id) AND (r.company_id = public.get_user_company_id())))));


--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

--
-- Name: roles roles_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY roles_insert ON public.roles FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above())));


--
-- Name: roles roles_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY roles_read ON public.roles FOR SELECT TO authenticated USING (((((company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))) AND (deleted_at IS NULL)) OR public.is_super_admin()));


--
-- Name: roles roles_select_global; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY roles_select_global ON public.roles FOR SELECT TO authenticated USING (((company_id IS NULL) AND (deleted_at IS NULL)));


--
-- Name: roles roles_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY roles_update ON public.roles FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above()))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above())));


--
-- Name: role_permission_templates rpt_admin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rpt_admin_only ON public.role_permission_templates TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: role_permission_templates rpt_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY rpt_read_all ON public.role_permission_templates FOR SELECT USING (true);


--
-- Name: sales_calls; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sales_calls ENABLE ROW LEVEL SECURITY;

--
-- Name: sales_calls sales_calls_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_calls_delete ON public.sales_calls FOR DELETE USING (((company_id = public.get_user_company_id()) AND public.is_manager_or_above()));


--
-- Name: sales_calls sales_calls_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_calls_insert ON public.sales_calls FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: sales_calls sales_calls_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_calls_read ON public.sales_calls FOR SELECT USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (salesperson_id = auth.uid()) OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: sales_calls sales_calls_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_calls_update ON public.sales_calls FOR UPDATE USING (((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (salesperson_id = auth.uid()) OR (created_by = auth.uid()))));


--
-- Name: sales_orders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sales_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: sales_orders sales_orders_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_orders_delete ON public.sales_orders FOR DELETE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (created_by = auth.uid()))));


--
-- Name: sales_orders sales_orders_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_orders_insert ON public.sales_orders FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (created_by = auth.uid()) AND (public.has_role('sales'::text) OR public.has_role('gm_bd'::text)))));


--
-- Name: sales_orders sales_orders_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_orders_select ON public.sales_orders FOR SELECT TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND ((created_by = auth.uid()) OR public.has_role('procurement'::text) OR public.is_manager_or_above()))));


--
-- Name: sales_orders sales_orders_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_orders_update ON public.sales_orders FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((deleted_at IS NULL) AND (company_id = public.get_user_company_id()) AND (created_by = auth.uid())))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (created_by = auth.uid()))));


--
-- Name: sales_visit_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sales_visit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: sales_visits; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sales_visits ENABLE ROW LEVEL SECURITY;

--
-- Name: sales_visits sales_visits_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_visits_delete ON public.sales_visits FOR DELETE USING (((company_id = public.get_user_company_id()) AND public.is_manager_or_above()));


--
-- Name: sales_visits sales_visits_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_visits_insert ON public.sales_visits FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: sales_visits sales_visits_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_visits_read ON public.sales_visits FOR SELECT USING ((((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (salesperson_id = auth.uid()) OR (created_by = auth.uid()))) OR public.is_super_admin()));


--
-- Name: sales_visits sales_visits_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sales_visits_update ON public.sales_visits FOR UPDATE USING (((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (salesperson_id = auth.uid()) OR (created_by = auth.uid()))));


--
-- Name: sla_policies; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sla_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: sla_policies sla_policies_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sla_policies_delete ON public.sla_policies FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: sla_policies sla_policies_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sla_policies_insert ON public.sla_policies FOR INSERT TO authenticated WITH CHECK (((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.is_admin_or_above()));


--
-- Name: sla_policies sla_policies_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sla_policies_read ON public.sla_policies FOR SELECT TO authenticated USING ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (deleted_at IS NULL)) OR public.is_super_admin()));


--
-- Name: sla_policies sla_policies_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sla_policies_update ON public.sla_policies FOR UPDATE TO authenticated USING (((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) OR public.is_super_admin())) WITH CHECK ((((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND public.is_admin_or_above()) OR public.is_super_admin()));


--
-- Name: asset_software_licenses software_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY software_insert ON public.asset_software_licenses FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: asset_software_licenses software_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY software_select ON public.asset_software_licenses FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: asset_software_licenses software_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY software_update ON public.asset_software_licenses FOR UPDATE USING ((company_id = public.get_user_company_id()));


--
-- Name: sp_btb; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_btb ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_btb sp_btb_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btb_delete ON public.sp_btb FOR DELETE USING (public.is_super_admin());


--
-- Name: sp_btb sp_btb_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btb_insert ON public.sp_btb FOR INSERT WITH CHECK ((public.is_super_admin() OR (((company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: sp_btb sp_btb_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btb_read ON public.sp_btb FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: sp_btb sp_btb_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btb_update ON public.sp_btb FOR UPDATE USING ((public.is_super_admin() OR (((company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: sp_btbs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_btbs ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_btbs sp_btbs_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btbs_delete ON public.sp_btbs FOR DELETE TO authenticated USING (true);


--
-- Name: sp_btbs sp_btbs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btbs_insert ON public.sp_btbs FOR INSERT WITH CHECK ((auth.uid() IS NOT NULL));


--
-- Name: sp_btbs sp_btbs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btbs_read ON public.sp_btbs FOR SELECT USING (true);


--
-- Name: sp_btbs sp_btbs_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_btbs_update ON public.sp_btbs FOR UPDATE USING ((auth.uid() IS NOT NULL));


--
-- Name: sp_invoice_lines; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_invoice_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_invoice_lines sp_invoice_lines_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoice_lines_delete ON public.sp_invoice_lines FOR DELETE USING (public.is_super_admin());


--
-- Name: sp_invoice_lines sp_invoice_lines_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoice_lines_insert ON public.sp_invoice_lines FOR INSERT WITH CHECK ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.sp_invoices i
  WHERE ((i.id = sp_invoice_lines.invoice_id) AND (i.company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('finance_controller'::text)))))));


--
-- Name: sp_invoice_lines sp_invoice_lines_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoice_lines_read ON public.sp_invoice_lines FOR SELECT USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.sp_invoices i
  WHERE ((i.id = sp_invoice_lines.invoice_id) AND (i.company_id = public.get_user_company_id()))))));


--
-- Name: sp_invoice_lines sp_invoice_lines_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoice_lines_update ON public.sp_invoice_lines FOR UPDATE USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.sp_invoices i
  WHERE ((i.id = sp_invoice_lines.invoice_id) AND (i.company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('finance_controller'::text)))))));


--
-- Name: sp_invoices; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_invoices ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_invoices sp_invoices_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoices_delete ON public.sp_invoices FOR DELETE USING (public.is_super_admin());


--
-- Name: sp_invoices sp_invoices_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoices_insert ON public.sp_invoices FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('finance_controller'::text)))));


--
-- Name: sp_invoices sp_invoices_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoices_read ON public.sp_invoices FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: sp_invoices sp_invoices_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_invoices_update ON public.sp_invoices FOR UPDATE USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('finance_controller'::text)))));


--
-- Name: sp_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_items ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_items sp_items_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_items_delete ON public.sp_items FOR DELETE TO authenticated USING ((public.is_super_admin() OR public.is_sp_item_writer()));


--
-- Name: sp_items sp_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_items_insert ON public.sp_items FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: sp_items sp_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_items_read ON public.sp_items FOR SELECT TO authenticated USING (true);


--
-- Name: sp_items sp_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_items_update ON public.sp_items FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: sp_manifest_staging_20260810; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_manifest_staging_20260810 ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_order_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_order_items ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_order_items sp_order_items_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_order_items_delete ON public.sp_order_items FOR DELETE USING (public.is_super_admin());


--
-- Name: sp_order_items sp_order_items_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_order_items_insert ON public.sp_order_items FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: sp_order_items sp_order_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_order_items_read ON public.sp_order_items FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: sp_order_items sp_order_items_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_order_items_update ON public.sp_order_items FOR UPDATE USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: sp_orders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_orders sp_orders_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_orders_delete ON public.sp_orders FOR DELETE USING (public.is_super_admin());


--
-- Name: sp_orders sp_orders_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_orders_insert ON public.sp_orders FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: sp_orders sp_orders_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_orders_read ON public.sp_orders FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id()) OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: sp_orders sp_orders_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_orders_update ON public.sp_orders FOR UPDATE USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR public.has_role('operations'::text)))));


--
-- Name: sp_payments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sp_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: sp_payments sp_payments_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_payments_delete ON public.sp_payments FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: sp_payments sp_payments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_payments_read ON public.sp_payments FOR SELECT TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.sp_invoices i
  WHERE ((i.id = sp_payments.invoice_id) AND (i.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)))))));


--
-- Name: sp_payments sp_payments_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sp_payments_update ON public.sp_payments FOR UPDATE TO authenticated USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.sp_invoices i
  WHERE ((i.id = sp_payments.invoice_id) AND (i.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR public.has_role('finance_controller'::text))))))) WITH CHECK ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.sp_invoices i
  WHERE ((i.id = sp_payments.invoice_id) AND (i.company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR public.has_role('finance_controller'::text)))))));


--
-- Name: asset_specifications specs_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY specs_insert ON public.asset_specifications FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: asset_specifications specs_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY specs_select ON public.asset_specifications FOR SELECT USING ((public.is_super_admin() OR (company_id = public.get_user_company_id())));


--
-- Name: asset_specifications specs_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY specs_update ON public.asset_specifications FOR UPDATE USING ((company_id = public.get_user_company_id()));


--
-- Name: status_catalog; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.status_catalog ENABLE ROW LEVEL SECURITY;

--
-- Name: status_catalog status_catalog_read_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY status_catalog_read_all ON public.status_catalog FOR SELECT TO authenticated USING (true);


--
-- Name: status_catalog status_catalog_super_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY status_catalog_super_admin_write ON public.status_catalog TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: stock_ledger; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.stock_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: stock_ledger stock_ledger_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY stock_ledger_insert ON public.stock_ledger FOR INSERT WITH CHECK ((auth.uid() IS NOT NULL));


--
-- Name: stock_ledger stock_ledger_modify; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY stock_ledger_modify ON public.stock_ledger FOR UPDATE USING (public.is_super_admin());


--
-- Name: stock_ledger stock_ledger_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY stock_ledger_select ON public.stock_ledger FOR SELECT USING (true);


--
-- Name: taxes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.taxes ENABLE ROW LEVEL SECURITY;

--
-- Name: taxes taxes_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY taxes_insert ON public.taxes FOR INSERT TO authenticated WITH CHECK (((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('finance_controller'::text))));


--
-- Name: taxes taxes_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY taxes_read ON public.taxes FOR SELECT TO authenticated USING (((company_id = public.get_user_company_id()) AND ((deleted_at IS NULL) OR public.is_super_admin())));


--
-- Name: taxes taxes_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY taxes_update ON public.taxes FOR UPDATE TO authenticated USING (((company_id = public.get_user_company_id()) AND ((deleted_at IS NULL) OR public.is_super_admin()))) WITH CHECK (((company_id = public.get_user_company_id()) AND (public.is_admin_or_above() OR public.has_role('finance_controller'::text))));


--
-- Name: top_requests top_request_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY top_request_read ON public.top_requests FOR SELECT USING ((company_id = public.get_user_company_id()));


--
-- Name: top_requests top_request_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY top_request_update ON public.top_requests FOR UPDATE USING (((company_id = public.get_user_company_id()) AND (public.is_manager_or_above() OR (created_by = auth.uid()))));


--
-- Name: top_requests top_request_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY top_request_write ON public.top_requests FOR INSERT WITH CHECK ((company_id = public.get_user_company_id()));


--
-- Name: top_requests; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.top_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: user_menu_permissions ump_admin_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ump_admin_all ON public.user_menu_permissions TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: user_menu_permissions ump_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ump_select ON public.user_menu_permissions FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_login_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.user_login_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: user_login_logs user_login_logs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY user_login_logs_read ON public.user_login_logs FOR SELECT TO authenticated USING ((public.is_super_admin() OR (user_id = auth.uid()) OR (public.is_manager_or_above() AND (EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = user_login_logs.user_id) AND (p.company_id = public.get_user_company_id())))))));


--
-- Name: user_menu_permissions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.user_menu_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_roles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: user_roles user_roles_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY user_roles_insert ON public.user_roles FOR INSERT TO authenticated WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above() AND (NOT public.is_admin_tier_role(role_id)))));


--
-- Name: user_roles user_roles_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY user_roles_read ON public.user_roles FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR ((company_id = public.get_user_company_id()) AND public.is_manager_or_above()) OR public.is_super_admin()));


--
-- Name: user_roles user_roles_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY user_roles_update ON public.user_roles FOR UPDATE TO authenticated USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above() AND (NOT public.is_admin_tier_role(role_id))))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_admin_or_above() AND (NOT public.is_admin_tier_role(role_id)))));


--
-- Name: vendors; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;

--
-- Name: vendors vendors_delete; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY vendors_delete ON public.vendors FOR DELETE TO authenticated USING (public.is_super_admin());


--
-- Name: vendors vendors_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY vendors_insert ON public.vendors FOR INSERT WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR public.has_role('procurement'::text)))));


--
-- Name: vendors vendors_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY vendors_select ON public.vendors FOR SELECT USING ((public.is_super_admin() OR (company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids))));


--
-- Name: vendors vendors_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY vendors_update ON public.vendors FOR UPDATE USING ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (deleted_at IS NULL) AND (public.is_manager_or_above() OR public.has_role('procurement'::text))))) WITH CHECK ((public.is_super_admin() OR ((company_id IN ( SELECT public.get_user_company_ids() AS get_user_company_ids)) AND (public.is_manager_or_above() OR public.has_role('procurement'::text)))));


--
-- Name: sales_visit_logs visit_logs_company; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY visit_logs_company ON public.sales_visit_logs USING ((visit_id IN ( SELECT sales_visits.id
   FROM public.sales_visits
  WHERE (sales_visits.company_id = public.get_user_company_id()))));


--
-- Name: warehouses; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;

--
-- Name: warehouses warehouses_modify; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY warehouses_modify ON public.warehouses USING (public.is_super_admin());


--
-- Name: warehouses warehouses_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY warehouses_select ON public.warehouses FOR SELECT USING (true);


--
-- Name: weekly_meeting_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.weekly_meeting_items ENABLE ROW LEVEL SECURITY;

--
-- Name: weekly_meeting_items weekly_meeting_items_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY weekly_meeting_items_all ON public.weekly_meeting_items USING ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.weekly_meetings m
  WHERE ((m.id = weekly_meeting_items.weekly_meeting_id) AND (m.company_id = public.get_user_company_id()) AND public.is_bnf_authorized()))))) WITH CHECK ((public.is_super_admin() OR (EXISTS ( SELECT 1
   FROM public.weekly_meetings m
  WHERE ((m.id = weekly_meeting_items.weekly_meeting_id) AND (m.company_id = public.get_user_company_id()) AND public.is_bnf_authorized())))));


--
-- Name: weekly_meetings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.weekly_meetings ENABLE ROW LEVEL SECURITY;

--
-- Name: weekly_meetings weekly_meetings_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY weekly_meetings_all ON public.weekly_meetings USING ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_bnf_authorized()))) WITH CHECK ((public.is_super_admin() OR ((company_id = public.get_user_company_id()) AND public.is_bnf_authorized())));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION add_picking_material(p_picking_list_id uuid, p_product_id uuid, p_qty integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.add_picking_material(p_picking_list_id uuid, p_product_id uuid, p_qty integer) TO authenticated;


--
-- Name: FUNCTION attach_price_contract_info(p_history_id uuid, p_contract_no text, p_valid_from date, p_valid_until date); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.attach_price_contract_info(p_history_id uuid, p_contract_no text, p_valid_from date, p_valid_until date) TO authenticated;


--
-- Name: FUNCTION bulk_update_product_prices(p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.bulk_update_product_prices(p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.bulk_update_product_prices(p_rows jsonb) TO service_role;


--
-- Name: FUNCTION cancel_delivery(p_delivery_note_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.cancel_delivery(p_delivery_note_id uuid) TO authenticated;


--
-- Name: FUNCTION cancel_picking(p_picking_list_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.cancel_picking(p_picking_list_id uuid) TO authenticated;


--
-- Name: FUNCTION check_similar_accounts(p_name text, p_company_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.check_similar_accounts(p_name text, p_company_id uuid) TO authenticated;


--
-- Name: FUNCTION complete_picking(p_picking_list_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.complete_picking(p_picking_list_id uuid) TO authenticated;


--
-- Name: FUNCTION create_invoice(p_sp_order_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.create_invoice(p_sp_order_id uuid) TO authenticated;


--
-- Name: FUNCTION create_sp_order_dual(p_company_id uuid, p_customer_id uuid, p_sp_no text, p_sp_date date, p_dc_id uuid, p_status text, p_expired_date date, p_notes text, p_items jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.create_sp_order_dual(p_company_id uuid, p_customer_id uuid, p_sp_no text, p_sp_date date, p_dc_id uuid, p_status text, p_expired_date date, p_notes text, p_items jsonb) TO authenticated;


--
-- Name: FUNCTION delete_picking_material(p_material_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.delete_picking_material(p_material_id uuid) TO authenticated;


--
-- Name: FUNCTION delete_sp_dual(p_customer_id uuid, p_sp_no text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.delete_sp_dual(p_customer_id uuid, p_sp_no text) TO authenticated;


--
-- Name: FUNCTION delete_sp_item_dual(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_sp_item_dual(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_sp_item_dual(p_id uuid) TO authenticated;


--
-- Name: FUNCTION dispatch_delivery(p_delivery_note_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.dispatch_delivery(p_delivery_note_id uuid) TO authenticated;


--
-- Name: FUNCTION exec_sql(sql text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.exec_sql(sql text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.exec_sql(sql text) TO service_role;


--
-- Name: FUNCTION generate_delivery_from_picking(p_picking_list_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_delivery_from_picking(p_picking_list_id uuid) TO authenticated;


--
-- Name: FUNCTION generate_picking_from_sp(p_sp_no text, p_customer_id uuid, p_warehouse_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_picking_from_sp(p_sp_no text, p_customer_id uuid, p_warehouse_id uuid) TO authenticated;


--
-- Name: FUNCTION get_storbit_dashboard_stats(p_customer_id uuid, p_price_category text, p_company_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_dashboard_stats(p_customer_id uuid, p_price_category text, p_company_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_dashboard_stats(p_customer_id uuid, p_price_category text, p_company_id uuid) TO authenticated;


--
-- Name: FUNCTION get_storbit_outstanding_summary(p_company_id uuid, p_customer_id uuid, p_price_category text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_outstanding_summary(p_company_id uuid, p_customer_id uuid, p_price_category text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_outstanding_summary(p_company_id uuid, p_customer_id uuid, p_price_category text) TO authenticated;


--
-- Name: FUNCTION get_storbit_product_report(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_product_report(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_product_report(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date) TO authenticated;


--
-- Name: FUNCTION get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_product_sp_list(p_product_id uuid, p_company_id uuid, p_date_from date, p_date_to date, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_storbit_sp_drilldown(p_category text, p_customer_id uuid, p_price_category text, p_company_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_sp_drilldown(p_category text, p_customer_id uuid, p_price_category text, p_company_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_sp_drilldown(p_category text, p_customer_id uuid, p_price_category text, p_company_id uuid, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_storbit_stock_drilldown(p_category text, p_company_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_stock_drilldown(p_category text, p_company_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_stock_drilldown(p_category text, p_company_id uuid, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_storbit_top_outstanding_products(p_company_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_storbit_top_outstanding_products(p_company_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storbit_top_outstanding_products(p_company_id uuid, p_limit integer) TO authenticated;


--
-- Name: FUNCTION get_table_columns(p_table text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_table_columns(p_table text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_table_columns(p_table text) TO service_role;
GRANT ALL ON FUNCTION public.get_table_columns(p_table text) TO authenticated;


--
-- Name: FUNCTION get_user_company_ids(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_user_company_ids() TO authenticated;


--
-- Name: FUNCTION hrga_submit_approval(p_request_id uuid, p_action text, p_comment text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.hrga_submit_approval(p_request_id uuid, p_action text, p_comment text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.hrga_submit_approval(p_request_id uuid, p_action text, p_comment text) TO authenticated;


--
-- Name: FUNCTION indomarco_dashboard_stats(p_customer_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.indomarco_dashboard_stats(p_customer_id uuid) TO anon;
GRANT ALL ON FUNCTION public.indomarco_dashboard_stats(p_customer_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.indomarco_dashboard_stats(p_customer_id uuid) TO service_role;


--
-- Name: FUNCTION is_sp_item_writer(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.is_sp_item_writer() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_sp_item_writer() TO authenticated;


--
-- Name: FUNCTION mark_delivery_delivered(p_delivery_note_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.mark_delivery_delivered(p_delivery_note_id uuid) TO authenticated;


--
-- Name: FUNCTION mark_inquiry_won(p_inquiry_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.mark_inquiry_won(p_inquiry_id uuid) TO authenticated;


--
-- Name: FUNCTION mark_ttf_received(p_invoice_id uuid, p_received_by text, p_ttf_no text, p_notes text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.mark_ttf_received(p_invoice_id uuid, p_received_by text, p_ttf_no text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_ttf_received(p_invoice_id uuid, p_received_by text, p_ttf_no text, p_notes text) TO authenticated;


--
-- Name: FUNCTION prf_claim(p_prf_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.prf_claim(p_prf_id uuid) TO authenticated;


--
-- Name: FUNCTION prf_mark_quoted(p_prf_id uuid, p_waiver_reason text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.prf_mark_quoted(p_prf_id uuid, p_waiver_reason text) TO authenticated;


--
-- Name: FUNCTION prf_release(p_prf_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.prf_release(p_prf_id uuid) TO authenticated;


--
-- Name: FUNCTION prf_select_offer(p_prf_id uuid, p_offer_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.prf_select_offer(p_prf_id uuid, p_offer_id uuid) TO authenticated;


--
-- Name: FUNCTION record_payment(p_invoice_id uuid, p_amount numeric, p_payment_date date, p_reference text, p_pph numeric, p_bukti_potong_url text, p_bukti_potong_no text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_payment(p_invoice_id uuid, p_amount numeric, p_payment_date date, p_reference text, p_pph numeric, p_bukti_potong_url text, p_bukti_potong_no text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_payment(p_invoice_id uuid, p_amount numeric, p_payment_date date, p_reference text, p_pph numeric, p_bukti_potong_url text, p_bukti_potong_no text) TO authenticated;


--
-- Name: FUNCTION save_prf_pricing(p_prf_id uuid, p_header jsonb, p_items jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.save_prf_pricing(p_prf_id uuid, p_header jsonb, p_items jsonb) TO authenticated;


--
-- Name: FUNCTION save_quotation(p_quotation_id uuid, p_header jsonb, p_items jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.save_quotation(p_quotation_id uuid, p_header jsonb, p_items jsonb) TO authenticated;


--
-- Name: FUNCTION set_product_category_prices(p_product_id uuid, p_semester numeric, p_tahunan numeric, p_project numeric); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_product_category_prices(p_product_id uuid, p_semester numeric, p_tahunan numeric, p_project numeric) TO authenticated;


--
-- Name: FUNCTION set_sp_expired_date(p_customer_id uuid, p_sp_no text, p_expired_date date); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_sp_expired_date(p_customer_id uuid, p_sp_no text, p_expired_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_sp_expired_date(p_customer_id uuid, p_sp_no text, p_expired_date date) TO authenticated;


--
-- Name: FUNCTION set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_sp_finance_docs(p_customer_id uuid, p_sp_no text, p_inv boolean, p_fp boolean, p_submit boolean, p_kirim boolean, p_submit_date date, p_email_status text) TO authenticated;


--
-- Name: FUNCTION set_sp_status(p_sp_no text, p_status text, p_reason text, p_customer_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_sp_status(p_sp_no text, p_status text, p_reason text, p_customer_id uuid) TO authenticated;


--
-- Name: FUNCTION sp_delete_btb(p_btb_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sp_delete_btb(p_btb_id uuid) TO authenticated;


--
-- Name: FUNCTION sp_issue_btb(p_customer_id uuid, p_sp_no text, p_btb_no text, p_qty integer, p_btb_date date, p_delivery_note_id uuid, p_remarks text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sp_issue_btb(p_customer_id uuid, p_sp_no text, p_btb_no text, p_qty integer, p_btb_date date, p_delivery_note_id uuid, p_remarks text) TO authenticated;


--
-- Name: FUNCTION sp_recompute_status(p_customer_id uuid, p_sp_no text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sp_recompute_status(p_customer_id uuid, p_sp_no text) FROM PUBLIC;


--
-- Name: FUNCTION storbit_sp_customers(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.storbit_sp_customers() TO anon;
GRANT ALL ON FUNCTION public.storbit_sp_customers() TO authenticated;
GRANT ALL ON FUNCTION public.storbit_sp_customers() TO service_role;


--
-- Name: FUNCTION submit_invoice(p_invoice_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.submit_invoice(p_invoice_id uuid) TO authenticated;


--
-- Name: FUNCTION update_sp_item_dual(p_id uuid, p_item jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_sp_item_dual(p_id uuid, p_item jsonb) TO authenticated;


--
-- Name: TABLE account_lifecycle_history; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.account_lifecycle_history TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.account_lifecycle_history TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.account_lifecycle_history TO service_role;


--
-- Name: TABLE accounts; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.accounts TO authenticated;
GRANT ALL ON TABLE public.accounts TO service_role;


--
-- Name: TABLE activities; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.activities TO anon;
GRANT ALL ON TABLE public.activities TO authenticated;
GRANT ALL ON TABLE public.activities TO service_role;


--
-- Name: TABLE activity_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.activity_logs TO anon;
GRANT ALL ON TABLE public.activity_logs TO authenticated;
GRANT ALL ON TABLE public.activity_logs TO service_role;


--
-- Name: TABLE app_settings; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.app_settings TO anon;
GRANT ALL ON TABLE public.app_settings TO authenticated;
GRANT ALL ON TABLE public.app_settings TO service_role;


--
-- Name: TABLE approval_delegations; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.approval_delegations TO anon;
GRANT ALL ON TABLE public.approval_delegations TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.approval_delegations TO service_role;


--
-- Name: TABLE approval_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.approval_logs TO anon;
GRANT ALL ON TABLE public.approval_logs TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.approval_logs TO service_role;


--
-- Name: TABLE approval_rules; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.approval_rules TO anon;
GRANT ALL ON TABLE public.approval_rules TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.approval_rules TO service_role;


--
-- Name: TABLE approval_workflow_steps; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.approval_workflow_steps TO authenticated;
GRANT ALL ON TABLE public.approval_workflow_steps TO service_role;


--
-- Name: TABLE approval_workflows; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.approval_workflows TO authenticated;
GRANT ALL ON TABLE public.approval_workflows TO service_role;


--
-- Name: TABLE ar_btbs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.ar_btbs TO anon;
GRANT ALL ON TABLE public.ar_btbs TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.ar_btbs TO service_role;


--
-- Name: TABLE ar_ttfs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.ar_ttfs TO anon;
GRANT ALL ON TABLE public.ar_ttfs TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.ar_ttfs TO service_role;


--
-- Name: TABLE asset_categories; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_categories TO anon;
GRANT ALL ON TABLE public.asset_categories TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_categories TO service_role;


--
-- Name: TABLE asset_fuel_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_fuel_logs TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_fuel_logs TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_fuel_logs TO service_role;


--
-- Name: TABLE asset_locations; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_locations TO anon;
GRANT ALL ON TABLE public.asset_locations TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_locations TO service_role;


--
-- Name: TABLE asset_maintenance_records; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_maintenance_records TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.asset_maintenance_records TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_maintenance_records TO service_role;


--
-- Name: TABLE asset_network; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_network TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.asset_network TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_network TO service_role;


--
-- Name: TABLE asset_software_licenses; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_software_licenses TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.asset_software_licenses TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_software_licenses TO service_role;


--
-- Name: TABLE asset_specifications; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_specifications TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.asset_specifications TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_specifications TO service_role;


--
-- Name: TABLE assets; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.assets TO anon;
GRANT ALL ON TABLE public.assets TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.assets TO service_role;


--
-- Name: TABLE audit_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.audit_logs TO anon;
GRANT ALL ON TABLE public.audit_logs TO authenticated;
GRANT ALL ON TABLE public.audit_logs TO service_role;


--
-- Name: TABLE backfill_sp_order_items_20260808; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backfill_sp_order_items_20260808 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backfill_sp_order_items_20260808 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backfill_sp_order_items_20260808 TO service_role;


--
-- Name: TABLE backup_b4_inquiries_20260725; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_b4_inquiries_20260725 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_b4_inquiries_20260725 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_b4_inquiries_20260725 TO service_role;


--
-- Name: TABLE backup_dedup_accounts_20260725; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_accounts_20260725 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_accounts_20260725 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_accounts_20260725 TO service_role;


--
-- Name: TABLE backup_dedup_activities_20260725; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_activities_20260725 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_activities_20260725 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_activities_20260725 TO service_role;


--
-- Name: TABLE backup_dedup_alliance_20260725; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_alliance_20260725 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_alliance_20260725 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_alliance_20260725 TO service_role;


--
-- Name: TABLE backup_dedup_inquiries_20260725; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_inquiries_20260725 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_inquiries_20260725 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_inquiries_20260725 TO service_role;


--
-- Name: TABLE backup_dedup_quotations_20260725; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_quotations_20260725 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_quotations_20260725 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_dedup_quotations_20260725 TO service_role;


--
-- Name: TABLE backup_leadpool_c1_won_20260724; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_leadpool_c1_won_20260724 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_leadpool_c1_won_20260724 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_leadpool_c1_won_20260724 TO service_role;


--
-- Name: TABLE backup_leadpool_trap_20260724; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_leadpool_trap_20260724 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_leadpool_trap_20260724 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_leadpool_trap_20260724 TO service_role;


--
-- Name: TABLE backup_prf_20260727; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_prf_20260727 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_prf_20260727 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_prf_20260727 TO service_role;


--
-- Name: TABLE backup_prf_cost_items_20260727; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_prf_cost_items_20260727 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_prf_cost_items_20260727 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.backup_prf_cost_items_20260727 TO service_role;


--
-- Name: TABLE bnf_authorized_users; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_authorized_users TO anon;
GRANT ALL ON TABLE public.bnf_authorized_users TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_authorized_users TO service_role;


--
-- Name: TABLE bnf_department_scopes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_department_scopes TO anon;
GRANT ALL ON TABLE public.bnf_department_scopes TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_department_scopes TO service_role;


--
-- Name: TABLE bnf_departments; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_departments TO anon;
GRANT ALL ON TABLE public.bnf_departments TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_departments TO service_role;


--
-- Name: TABLE bnf_division_scopes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_division_scopes TO anon;
GRANT ALL ON TABLE public.bnf_division_scopes TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_division_scopes TO service_role;


--
-- Name: TABLE bnf_divisions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_divisions TO anon;
GRANT ALL ON TABLE public.bnf_divisions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_divisions TO service_role;


--
-- Name: TABLE bnf_report_action_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_report_action_items TO anon;
GRANT ALL ON TABLE public.bnf_report_action_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_report_action_items TO service_role;


--
-- Name: TABLE bnf_report_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_report_logs TO anon;
GRANT ALL ON TABLE public.bnf_report_logs TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_report_logs TO service_role;


--
-- Name: TABLE bnf_report_related_departments; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_report_related_departments TO anon;
GRANT ALL ON TABLE public.bnf_report_related_departments TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_report_related_departments TO service_role;


--
-- Name: TABLE bnf_reports; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_reports TO anon;
GRANT ALL ON TABLE public.bnf_reports TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.bnf_reports TO service_role;


--
-- Name: TABLE branches; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.branches TO anon;
GRANT ALL ON TABLE public.branches TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.branches TO service_role;


--
-- Name: TABLE channel_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.channel_types TO anon;
GRANT ALL ON TABLE public.channel_types TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.channel_types TO service_role;


--
-- Name: TABLE chart_of_accounts; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.chart_of_accounts TO anon;
GRANT ALL ON TABLE public.chart_of_accounts TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.chart_of_accounts TO service_role;


--
-- Name: TABLE code_counters; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.code_counters TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.code_counters TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.code_counters TO service_role;


--
-- Name: TABLE companies; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.companies TO anon;
GRANT ALL ON TABLE public.companies TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.companies TO service_role;


--
-- Name: TABLE contacts; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.contacts TO anon;
GRANT ALL ON TABLE public.contacts TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.contacts TO service_role;


--
-- Name: TABLE cost_centers; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.cost_centers TO anon;
GRANT ALL ON TABLE public.cost_centers TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.cost_centers TO service_role;


--
-- Name: TABLE currencies; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.currencies TO anon;
GRANT ALL ON TABLE public.currencies TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.currencies TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.customers TO service_role;


--
-- Name: TABLE daily_report_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.daily_report_items TO anon;
GRANT ALL ON TABLE public.daily_report_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.daily_report_items TO service_role;


--
-- Name: TABLE dc_master; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.dc_master TO anon;
GRANT ALL ON TABLE public.dc_master TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.dc_master TO service_role;


--
-- Name: TABLE deal_handovers; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.deal_handovers TO anon;
GRANT ALL ON TABLE public.deal_handovers TO authenticated;
GRANT ALL ON TABLE public.deal_handovers TO service_role;


--
-- Name: TABLE delivery_incidents; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.delivery_incidents TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.delivery_incidents TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.delivery_incidents TO service_role;


--
-- Name: COLUMN delivery_incidents.company_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(company_id) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.delivery_note_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(delivery_note_id) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.incident_type; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(incident_type),UPDATE(incident_type) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.severity; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(severity),UPDATE(severity) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.description; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(description),UPDATE(description) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.occurred_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(occurred_at),UPDATE(occurred_at) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.reported_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(reported_by) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.status; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(status) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.resolution; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(resolution) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.resolved_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(resolved_at) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.resolved_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(resolved_by) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.delay_minutes; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(delay_minutes),UPDATE(delay_minutes) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.vendor_name; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT(vendor_name),UPDATE(vendor_name) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: COLUMN delivery_incidents.deleted_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(deleted_at) ON TABLE public.delivery_incidents TO authenticated;


--
-- Name: TABLE delivery_note_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.delivery_note_items TO anon;
GRANT ALL ON TABLE public.delivery_note_items TO authenticated;
GRANT ALL ON TABLE public.delivery_note_items TO service_role;


--
-- Name: TABLE delivery_notes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.delivery_notes TO anon;
GRANT ALL ON TABLE public.delivery_notes TO authenticated;
GRANT ALL ON TABLE public.delivery_notes TO service_role;


--
-- Name: TABLE departments; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.departments TO anon;
GRANT ALL ON TABLE public.departments TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.departments TO service_role;


--
-- Name: TABLE document_numbering; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.document_numbering TO authenticated;
GRANT ALL ON TABLE public.document_numbering TO service_role;


--
-- Name: TABLE document_sequences; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.document_sequences TO anon;
GRANT ALL ON TABLE public.document_sequences TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.document_sequences TO service_role;


--
-- Name: TABLE document_templates; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.document_templates TO authenticated;
GRANT ALL ON TABLE public.document_templates TO service_role;


--
-- Name: TABLE document_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.document_types TO anon;
GRANT ALL ON TABLE public.document_types TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.document_types TO service_role;


--
-- Name: TABLE dropdown_options; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.dropdown_options TO anon;
GRANT ALL ON TABLE public.dropdown_options TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.dropdown_options TO service_role;


--
-- Name: TABLE entity_bank_accounts; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.entity_bank_accounts TO authenticated;
GRANT ALL ON TABLE public.entity_bank_accounts TO service_role;


--
-- Name: TABLE entity_finance_settings; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.entity_finance_settings TO authenticated;
GRANT ALL ON TABLE public.entity_finance_settings TO service_role;


--
-- Name: TABLE entity_signatories; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.entity_signatories TO authenticated;
GRANT ALL ON TABLE public.entity_signatories TO service_role;


--
-- Name: TABLE exchange_rates; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.exchange_rates TO anon;
GRANT ALL ON TABLE public.exchange_rates TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.exchange_rates TO service_role;


--
-- Name: TABLE hrga_approval_configs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_approval_configs TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_approval_configs TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_approval_configs TO service_role;


--
-- Name: TABLE hrga_notification_queue; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_notification_queue TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_notification_queue TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_notification_queue TO service_role;


--
-- Name: TABLE hrga_offboarding_checklists; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_offboarding_checklists TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_offboarding_checklists TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_offboarding_checklists TO service_role;


--
-- Name: TABLE hrga_offboarding_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_offboarding_items TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_offboarding_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_offboarding_items TO service_role;


--
-- Name: TABLE hrga_request_approvals; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_approvals TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_approvals TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_approvals TO service_role;


--
-- Name: TABLE hrga_request_attachments; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_attachments TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_request_attachments TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_attachments TO service_role;


--
-- Name: TABLE hrga_request_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_items TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_request_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_items TO service_role;


--
-- Name: TABLE hrga_request_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_types TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_request_types TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_request_types TO service_role;


--
-- Name: TABLE hrga_requests; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_requests TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.hrga_requests TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.hrga_requests TO service_role;


--
-- Name: TABLE inquiries; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.inquiries TO authenticated;
GRANT ALL ON TABLE public.inquiries TO service_role;


--
-- Name: TABLE inquiry_comment_mentions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_comment_mentions TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_comment_mentions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_comment_mentions TO service_role;


--
-- Name: TABLE inquiry_comments; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_comments TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.inquiry_comments TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_comments TO service_role;


--
-- Name: TABLE inquiry_status_history; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_status_history TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_status_history TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inquiry_status_history TO service_role;


--
-- Name: TABLE journal_entries; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.journal_entries TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.journal_entries TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.journal_entries TO service_role;


--
-- Name: TABLE journal_entry_lines; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.journal_entry_lines TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.journal_entry_lines TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.journal_entry_lines TO service_role;


--
-- Name: TABLE loss_reasons; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.loss_reasons TO anon;
GRANT ALL ON TABLE public.loss_reasons TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.loss_reasons TO service_role;


--
-- Name: TABLE meeting_moms; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.meeting_moms TO anon;
GRANT ALL ON TABLE public.meeting_moms TO authenticated;
GRANT ALL ON TABLE public.meeting_moms TO service_role;


--
-- Name: TABLE menu_actions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.menu_actions TO authenticated;
GRANT ALL ON TABLE public.menu_actions TO service_role;


--
-- Name: TABLE module_actions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.module_actions TO authenticated;
GRANT ALL ON TABLE public.module_actions TO service_role;


--
-- Name: TABLE module_menus; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.module_menus TO authenticated;
GRANT ALL ON TABLE public.module_menus TO service_role;


--
-- Name: TABLE modules; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.modules TO authenticated;
GRANT ALL ON TABLE public.modules TO service_role;


--
-- Name: TABLE mom_action_plans; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.mom_action_plans TO anon;
GRANT ALL ON TABLE public.mom_action_plans TO authenticated;
GRANT ALL ON TABLE public.mom_action_plans TO service_role;


--
-- Name: TABLE mom_improvements; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.mom_improvements TO anon;
GRANT ALL ON TABLE public.mom_improvements TO authenticated;
GRANT ALL ON TABLE public.mom_improvements TO service_role;


--
-- Name: TABLE mom_issues; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.mom_issues TO anon;
GRANT ALL ON TABLE public.mom_issues TO authenticated;
GRANT ALL ON TABLE public.mom_issues TO service_role;


--
-- Name: TABLE mom_progress_updates; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.mom_progress_updates TO anon;
GRANT ALL ON TABLE public.mom_progress_updates TO authenticated;
GRANT ALL ON TABLE public.mom_progress_updates TO service_role;


--
-- Name: TABLE notification_rules; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.notification_rules TO authenticated;
GRANT ALL ON TABLE public.notification_rules TO service_role;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.notifications TO authenticated;
GRANT ALL ON TABLE public.notifications TO service_role;


--
-- Name: TABLE payment_terms; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.payment_terms TO anon;
GRANT ALL ON TABLE public.payment_terms TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.payment_terms TO service_role;


--
-- Name: TABLE permissions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.permissions TO anon;
GRANT ALL ON TABLE public.permissions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.permissions TO service_role;


--
-- Name: TABLE picking_list_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.picking_list_items TO anon;
GRANT ALL ON TABLE public.picking_list_items TO authenticated;
GRANT ALL ON TABLE public.picking_list_items TO service_role;


--
-- Name: TABLE picking_list_materials; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.picking_list_materials TO anon;
GRANT ALL ON TABLE public.picking_list_materials TO authenticated;
GRANT ALL ON TABLE public.picking_list_materials TO service_role;


--
-- Name: TABLE picking_lists; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.picking_lists TO anon;
GRANT ALL ON TABLE public.picking_lists TO authenticated;
GRANT ALL ON TABLE public.picking_lists TO service_role;


--
-- Name: TABLE positions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.positions TO anon;
GRANT ALL ON TABLE public.positions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.positions TO service_role;


--
-- Name: TABLE prf; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prf TO anon;
GRANT ALL ON TABLE public.prf TO authenticated;
GRANT ALL ON TABLE public.prf TO service_role;


--
-- Name: TABLE prf_cost_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.prf_cost_items TO anon;
GRANT ALL ON TABLE public.prf_cost_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.prf_cost_items TO service_role;


--
-- Name: TABLE prf_vendor_offers; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.prf_vendor_offers TO anon;
GRANT ALL ON TABLE public.prf_vendor_offers TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.prf_vendor_offers TO service_role;


--
-- Name: TABLE product_price_history; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.product_price_history TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.product_price_history TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.product_price_history TO service_role;


--
-- Name: TABLE product_warehouse_location; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.product_warehouse_location TO anon;
GRANT ALL ON TABLE public.product_warehouse_location TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.product_warehouse_location TO service_role;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.products TO authenticated;
GRANT ALL ON TABLE public.products TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: TABLE quotation_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.quotation_items TO authenticated;
GRANT ALL ON TABLE public.quotation_items TO service_role;


--
-- Name: TABLE quotations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.quotations TO authenticated;
GRANT ALL ON TABLE public.quotations TO service_role;


--
-- Name: TABLE rate_sheets; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.rate_sheets TO anon;
GRANT ALL ON TABLE public.rate_sheets TO authenticated;
GRANT ALL ON TABLE public.rate_sheets TO service_role;


--
-- Name: TABLE role_menu_permissions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.role_menu_permissions TO anon;
GRANT ALL ON TABLE public.role_menu_permissions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.role_menu_permissions TO service_role;


--
-- Name: TABLE role_permission_templates; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.role_permission_templates TO authenticated;
GRANT ALL ON TABLE public.role_permission_templates TO service_role;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.role_permissions TO anon;
GRANT ALL ON TABLE public.role_permissions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.role_permissions TO service_role;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.roles TO anon;
GRANT ALL ON TABLE public.roles TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.roles TO service_role;


--
-- Name: TABLE sales_calls; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sales_calls TO authenticated;
GRANT ALL ON TABLE public.sales_calls TO service_role;


--
-- Name: TABLE sales_orders; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sales_orders TO anon;
GRANT ALL ON TABLE public.sales_orders TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sales_orders TO service_role;


--
-- Name: TABLE sales_visit_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sales_visit_logs TO authenticated;
GRANT ALL ON TABLE public.sales_visit_logs TO service_role;


--
-- Name: TABLE sales_visits; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sales_visits TO authenticated;
GRANT ALL ON TABLE public.sales_visits TO service_role;


--
-- Name: TABLE sla_policies; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sla_policies TO anon;
GRANT ALL ON TABLE public.sla_policies TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sla_policies TO service_role;


--
-- Name: TABLE sp_btb; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_btb TO anon;
GRANT ALL ON TABLE public.sp_btb TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_btb TO service_role;


--
-- Name: TABLE sp_btbs; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sp_btbs TO authenticated;
GRANT ALL ON TABLE public.sp_btbs TO service_role;


--
-- Name: TABLE sp_invoice_lines; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_invoice_lines TO anon;
GRANT ALL ON TABLE public.sp_invoice_lines TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_invoice_lines TO service_role;


--
-- Name: TABLE sp_invoices; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_invoices TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_invoices TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_invoices TO service_role;


--
-- Name: COLUMN sp_invoices.id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(id) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.company_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(company_id) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.sp_order_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(sp_order_id) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.faktur_no; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(faktur_no) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.invoice_date; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(invoice_date) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.submit_ref; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(submit_ref) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.created_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(created_by) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.created_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(created_at) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.updated_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(updated_at) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: COLUMN sp_invoices.deleted_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(deleted_at) ON TABLE public.sp_invoices TO authenticated;


--
-- Name: TABLE sp_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_items TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.sp_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_items TO service_role;


--
-- Name: TABLE sp_manifest_staging_20260810; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_manifest_staging_20260810 TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_manifest_staging_20260810 TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_manifest_staging_20260810 TO service_role;


--
-- Name: TABLE sp_order_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_order_items TO anon;
GRANT ALL ON TABLE public.sp_order_items TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_order_items TO service_role;


--
-- Name: TABLE sp_orders; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_orders TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_orders TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_orders TO service_role;


--
-- Name: COLUMN sp_orders.id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(id) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.company_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(company_id) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.customer_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(customer_id) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.sp_no; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(sp_no) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.sp_date; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(sp_date) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.dc_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(dc_id) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.is_disputed; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(is_disputed) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.dispute_reason; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(dispute_reason) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.disputed_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(disputed_at) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.disputed_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(disputed_by) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.expired_date; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(expired_date) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.sp_category; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(sp_category) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.external_url; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(external_url) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.notes; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(notes) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.confirmed_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(confirmed_at) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.confirmed_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(confirmed_by) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.cancelled_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(cancelled_at) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.cancelled_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(cancelled_by) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.cancel_reason; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(cancel_reason) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.created_by; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(created_by) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.created_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(created_at) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.updated_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(updated_at) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.deleted_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(deleted_at) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.had_cancelled_picking; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(had_cancelled_picking) ON TABLE public.sp_orders TO authenticated;


--
-- Name: COLUMN sp_orders.price_category; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(price_category) ON TABLE public.sp_orders TO authenticated;


--
-- Name: TABLE sp_payments; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_payments TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_payments TO service_role;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sp_payments TO authenticated;


--
-- Name: COLUMN sp_payments.reference; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(reference) ON TABLE public.sp_payments TO authenticated;


--
-- Name: COLUMN sp_payments.bukti_potong_url; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(bukti_potong_url) ON TABLE public.sp_payments TO authenticated;


--
-- Name: COLUMN sp_payments.bukti_potong_no; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(bukti_potong_no) ON TABLE public.sp_payments TO authenticated;


--
-- Name: TABLE status_catalog; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.status_catalog TO anon;
GRANT ALL ON TABLE public.status_catalog TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.status_catalog TO service_role;


--
-- Name: TABLE stock_ledger; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.stock_ledger TO authenticated;
GRANT ALL ON TABLE public.stock_ledger TO service_role;


--
-- Name: TABLE stock_summary; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.stock_summary TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.stock_summary TO service_role;


--
-- Name: TABLE taxes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.taxes TO anon;
GRANT ALL ON TABLE public.taxes TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.taxes TO service_role;


--
-- Name: TABLE top_requests; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.top_requests TO anon;
GRANT ALL ON TABLE public.top_requests TO authenticated;
GRANT ALL ON TABLE public.top_requests TO service_role;


--
-- Name: TABLE user_login_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.user_login_logs TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.user_login_logs TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.user_login_logs TO service_role;


--
-- Name: TABLE user_menu_permissions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.user_menu_permissions TO authenticated;
GRANT ALL ON TABLE public.user_menu_permissions TO service_role;


--
-- Name: TABLE user_roles; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.user_roles TO anon;
GRANT ALL ON TABLE public.user_roles TO authenticated;
GRANT ALL ON TABLE public.user_roles TO service_role;


--
-- Name: TABLE vendors; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.vendors TO authenticated;
GRANT ALL ON TABLE public.vendors TO service_role;


--
-- Name: TABLE warehouses; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.warehouses TO authenticated;
GRANT ALL ON TABLE public.warehouses TO service_role;


--
-- Name: TABLE weekly_meeting_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.weekly_meeting_items TO anon;
GRANT ALL ON TABLE public.weekly_meeting_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.weekly_meeting_items TO service_role;


--
-- Name: TABLE weekly_meetings; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.weekly_meetings TO anon;
GRANT ALL ON TABLE public.weekly_meetings TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.weekly_meetings TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict 3woiD72JOIOrITSz9owCfJJydeaRgnZE5b41SgztrxyVBLLq74hJESHzWPsasNu


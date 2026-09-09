SET ROLE plaa_owner;

-- Finite business timestamps, not PostgreSQL's special +/-infinity sentinels.
-- NULL still means an unknown optional source date; it is never fabricated.
ALTER TABLE plaa.member ADD CHECK(onboarded_at IS NULL OR isfinite(onboarded_at));
ALTER TABLE plaa.buyback_auction ADD CHECK(auction_number > 0);
ALTER TABLE plaa.buyback_auction ADD CHECK(opened_at IS NULL OR isfinite(opened_at));
ALTER TABLE plaa.buyback_auction ADD CHECK(closed_at IS NULL OR isfinite(closed_at));
ALTER TABLE plaa.buyback_bid ADD CHECK(submitted_at IS NULL OR isfinite(submitted_at));
ALTER TABLE plaa.activity_submission ADD CHECK(isfinite(submitted_at));
ALTER TABLE plaa.settlement_batch ADD CHECK(settled_at IS NULL OR isfinite(settled_at));
ALTER TABLE plaa.kudos_policy ADD CHECK(isfinite(valid_from) AND (valid_to IS NULL OR isfinite(valid_to)));

-- NUMERIC(p,s) rejects Infinity but accepts NaN, which even passes n >= 0.
-- Runtime APIs already reject NaN before a cast; defend the stored contract too.
DO $$ DECLARE c record; BEGIN
 FOR c IN SELECT cols.table_schema,cols.table_name,cols.column_name FROM information_schema.columns cols
 JOIN information_schema.tables t USING(table_schema,table_name)
 WHERE cols.table_schema IN ('plaa','export') AND cols.data_type='numeric' AND t.table_type='BASE TABLE' LOOP
  EXECUTE format('ALTER TABLE %I.%I ADD CHECK (%I <> ''NaN''::numeric)',c.table_schema,c.table_name,c.column_name);
 END LOOP;
END $$;

-- Validate even zero-result batches, which have no issuance row to enforce time.
CREATE FUNCTION plaa.validate_settlement_manifest() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,ingest,pg_temp AS $$
DECLARE q jsonb; cutoff timestamptz; effective_time timestamptz;
BEGIN
 SELECT payload INTO STRICT q FROM ingest.source_manifest WHERE manifest_id=NEW.manifest_id;
 cutoff=(q->'inputs'->>'cutoff')::timestamptz;
 effective_time=(q->>'effective_at')::timestamptz;
 IF cutoff IS NULL OR NOT isfinite(cutoff) OR effective_time IS NULL OR NOT isfinite(effective_time) THEN
  RAISE EXCEPTION 'finite settlement cutoff and effective_at required';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validate_settlement_manifest BEFORE INSERT ON plaa.settlement_batch
 FOR EACH ROW EXECUTE FUNCTION plaa.validate_settlement_manifest();

-- Preserve the supplied reviewer principal on review mutations, not an old creator.
CREATE OR REPLACE FUNCTION plaa.audit_write() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE b jsonb; a jsonb; keys text; reviewer text;
BEGIN
 IF TG_OP<>'INSERT' THEN b=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN a=to_jsonb(NEW); END IF;
 IF a->>'reviewed_by' IS DISTINCT FROM b->>'reviewed_by' THEN reviewer=a->>'reviewed_by'; END IF;
 SELECT string_agg(k.attname||'='||(coalesce(a,b)->>k.attname), ',' ORDER BY array_position(i.indkey::smallint[],k.attnum)) INTO keys
 FROM pg_index i JOIN pg_attribute k ON k.attrelid=i.indrelid AND k.attnum=ANY(i.indkey)
 WHERE i.indrelid=TG_RELID AND i.indisprimary;
 INSERT INTO plaa.audit_log(actor,action,table_name,row_pk,before,after,correlation)
 VALUES(coalesce(reviewer,a->>'created_by',a->>'entered_by',a->>'imported_by',a->>'updated_by',a->>'actor',session_user),TG_OP,TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME,coalesce(keys,'?'),b,a,
 coalesce(a->>'manifest_id',a->>'source_ref',txid_current()::text));
 RETURN coalesce(NEW,OLD);
END $$;
RESET ROLE;

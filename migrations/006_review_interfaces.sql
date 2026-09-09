SET ROLE plaa_owner;
-- Finite domain dates: NULL is the only unbounded interval representation.
ALTER TABLE plaa.round ADD CHECK(isfinite(lower(period)) AND isfinite(upper(period)));
ALTER TABLE plaa.activity_point_value ADD CHECK(isfinite(valid_from) AND (valid_to IS NULL OR isfinite(valid_to)));
ALTER TABLE plaa.region ADD CHECK(isfinite(valid_from) AND (valid_to IS NULL OR isfinite(valid_to)));
ALTER TABLE plaa.asset ADD CHECK(isfinite(valid_from) AND (valid_to IS NULL OR isfinite(valid_to)));
ALTER TABLE plaa.trust_valuation_snapshot ADD CHECK(isfinite(received_at));
ALTER TABLE plaa.ir_current ADD FOREIGN KEY(settlement_batch_id,round_id) REFERENCES plaa.settlement_batch(settlement_batch_id,round_id);
CREATE FUNCTION plaa.validate_ir_pointer() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM plaa.settlement_batch WHERE settlement_batch_id=NEW.settlement_batch_id AND round_id=NEW.round_id AND allocation_source='infra_rewards') THEN RAISE EXCEPTION 'IR pointer linkage'; END IF; RETURN NEW;
END $$;
CREATE TRIGGER validate_ir_pointer BEFORE INSERT OR UPDATE ON plaa.ir_current FOR EACH ROW EXECUTE FUNCTION plaa.validate_ir_pointer();

-- Legacy identifiers are restricted evidence, never an alternative core member PK.
CREATE TABLE ingest.identity_crosswalk (
 crosswalk_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest,
 legacy_type text NOT NULL CHECK(btrim(legacy_type)<>''), legacy_value text NOT NULL CHECK(btrim(legacy_value)<>''),
 aa_id bigint REFERENCES plaa.member,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','confirmed','rejected')),
 reviewed_by text, review_note text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK((status='confirmed')=(aa_id IS NOT NULL)),
 CHECK(status='pending' OR (nullif(btrim(reviewed_by),'') IS NOT NULL AND nullif(btrim(review_note),'') IS NOT NULL))
);
ALTER TABLE ingest.identity_crosswalk ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingest.identity_crosswalk FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_access ON ingest.identity_crosswalk TO plaa_owner USING(true) WITH CHECK(true);
CREATE TRIGGER audit_write AFTER INSERT OR UPDATE OR DELETE ON ingest.identity_crosswalk FOR EACH ROW EXECUTE FUNCTION plaa.audit_write();
CREATE TRIGGER touch BEFORE UPDATE ON ingest.identity_crosswalk FOR EACH ROW EXECUTE FUNCTION plaa.touch();
CREATE FUNCTION ingest.stage_crosswalk(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ingest,pg_temp AS $$
DECLARE m bigint; id bigint;
BEGIN
 m=ingest.claim(q,'identity_crosswalk');
 INSERT INTO ingest.identity_crosswalk(manifest_id,legacy_type,legacy_value) VALUES(m,q->>'legacy_type',q->>'legacy_value') ON CONFLICT(manifest_id) DO NOTHING;
 SELECT crosswalk_id INTO STRICT id FROM ingest.identity_crosswalk WHERE manifest_id=m; RETURN id;
END $$;
CREATE FUNCTION ingest.review_crosswalk(id bigint,member_id bigint,reviewer text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ingest,pg_temp AS $$
BEGIN
 UPDATE ingest.identity_crosswalk SET aa_id=member_id,status=CASE WHEN member_id IS NULL THEN 'rejected' ELSE 'confirmed' END,reviewed_by=reviewer,review_note=note WHERE crosswalk_id=id AND status='pending';
 IF NOT FOUND THEN RAISE EXCEPTION 'crosswalk missing or already reviewed'; END IF;
 -- This does NOT install a verified Directory mapping or merge participants.
END $$;
CREATE FUNCTION ingest.crosswalk_queue() RETURNS SETOF ingest.identity_crosswalk LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,ingest,pg_temp AS $$
 SELECT * FROM ingest.identity_crosswalk WHERE status='pending' ORDER BY crosswalk_id LIMIT 100;
$$;
GRANT EXECUTE ON FUNCTION ingest.stage_crosswalk(jsonb) TO plaa_ingest;
GRANT EXECUTE ON FUNCTION ingest.review_crosswalk(bigint,bigint,text,text),ingest.crosswalk_queue() TO plaa_admin;

ALTER TABLE plaa.buyback_bid ADD COLUMN supersedes_bid_id bigint UNIQUE REFERENCES plaa.buyback_bid;
CREATE FUNCTION plaa.link_bid_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE old plaa.buyback_bid; pred bigint;
BEGIN
 SELECT (payload->>'supersedes_bid_id')::bigint INTO pred FROM ingest.source_manifest WHERE manifest_id=NEW.manifest_id;
 IF pred IS NOT NULL THEN
 SELECT * INTO STRICT old FROM plaa.buyback_bid WHERE bid_id=pred FOR UPDATE;
 IF (old.aa_id,old.auction_id) IS DISTINCT FROM (NEW.aa_id,NEW.auction_id) THEN RAISE EXCEPTION 'bid revision linkage'; END IF;
 NEW.supersedes_bid_id=pred;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER link_bid_revision BEFORE INSERT ON plaa.buyback_bid FOR EACH ROW EXECUTE FUNCTION plaa.link_bid_revision();

CREATE FUNCTION plaa.settlement_reconciliation(rid bigint) RETURNS TABLE(allocation_source plaa.allocation_source,category_id bigint,current_batch bigint,confirmed_total numeric,ledger_net numeric) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT 'incentivized_activities'::plaa.allocation_source,c.category_id,c.settlement_batch_id,r.plaa_distributed,
 (SELECT coalesce(sum(amount),0) FROM plaa.plaa_ledger_entry e WHERE e.round_id=rid AND e.category_id=c.category_id AND e.allocation_source='incentivized_activities')
 FROM plaa.round_category_current c JOIN plaa.round_category_result r USING(round_id,category_id,settlement_batch_id) WHERE c.round_id=rid
 UNION ALL
 SELECT 'infra_rewards'::plaa.allocation_source,NULL,c.settlement_batch_id,(m.payload->>'distributed')::numeric,
 (SELECT coalesce(sum(amount),0) FROM plaa.plaa_ledger_entry e WHERE e.round_id=rid AND e.allocation_source='infra_rewards')
 FROM plaa.ir_current c JOIN plaa.settlement_batch b USING(settlement_batch_id) JOIN ingest.source_manifest m USING(manifest_id) WHERE c.round_id=rid;
$$;
CREATE FUNCTION plaa.trust_report(cutoff timestamptz) RETURNS TABLE(kind text,report jsonb) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT 'holding',to_jsonb(h) FROM plaa.holdings_as_reported(cutoff) h UNION ALL SELECT 'valuation',to_jsonb(v) FROM plaa.valuation_as_reported(cutoff) v;
$$;
CREATE FUNCTION plaa.update_activity_copy(id bigint,label text,description text,active boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN UPDATE plaa.activity SET name=label,description=update_activity_copy.description,is_active=active WHERE activity_id=id;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown activity'; END IF; END $$;
GRANT EXECUTE ON FUNCTION plaa.settlement_reconciliation(bigint),plaa.trust_report(timestamptz),plaa.update_activity_copy(bigint,text,text,boolean) TO plaa_admin;
RESET ROLE;

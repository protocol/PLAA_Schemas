SET ROLE plaa_owner;
ALTER TABLE plaa.plaa_ledger_entry ADD COLUMN manifest_id bigint NOT NULL REFERENCES ingest.source_manifest;
ALTER TABLE plaa.round_category_result ADD COLUMN predecessor_batch_id bigint;
ALTER TABLE plaa.round_category_result ADD FOREIGN KEY(round_id,predecessor_batch_id,category_id) REFERENCES plaa.round_category_result(round_id,settlement_batch_id,category_id);

CREATE FUNCTION plaa.settle(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint; rid bigint=(q->>'round')::bigint; src plaa.allocation_source=(q->>'allocation_source')::plaa.allocation_source;
 c jsonb; e jsonb; predecessor bigint; expected bigint; cat bigint; total numeric; actual numeric; r plaa.round; o plaa.plaa_ledger_entry;
BEGIN
 -- Import confirmed allocations, never calculate conversion or invent rounding.
 IF q->>'policy_version' IS DISTINCT FROM 'source-confirmed-v1' OR jsonb_typeof(q->'inputs') IS DISTINCT FROM 'object' OR NOT (q->'inputs' ?& ARRAY['event_ids','cutoff','allocation_version']) THEN RAISE EXCEPTION 'confirmed input/policy manifest required'; END IF;
 IF jsonb_typeof(q->'inputs'->'event_ids') IS DISTINCT FROM 'array' OR nullif(q->'inputs'->>'allocation_version','') IS NULL OR (q->'inputs'->>'cutoff')::timestamptz IS NULL THEN RAISE EXCEPTION 'invalid input provenance'; END IF;
 PERFORM 1 FROM plaa.point_event WHERE point_event_id IN (SELECT value::text::bigint FROM jsonb_array_elements(q->'inputs'->'event_ids'));
 IF EXISTS(SELECT FROM jsonb_array_elements(q->'inputs'->'event_ids') x WHERE NOT EXISTS(SELECT FROM plaa.point_event WHERE point_event_id=x.value::text::bigint AND round_id=rid AND created_at<=(q->'inputs'->>'cutoff')::timestamptz)) THEN RAISE EXCEPTION 'invalid input event/cutoff'; END IF;
 m=ingest.claim(q,'settlement'); SELECT settlement_batch_id INTO id FROM plaa.settlement_batch WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 SELECT * INTO STRICT r FROM plaa.round WHERE round_id=rid FOR UPDATE;
 IF r.status NOT IN ('closed','settled') THEN RAISE EXCEPTION 'round must be closed'; END IF;
 IF src='infra_rewards' THEN
 SELECT settlement_batch_id INTO predecessor FROM plaa.ir_current WHERE round_id=rid;
 expected=(q->>'expected_predecessor')::bigint;
 IF predecessor IS DISTINCT FROM expected THEN RAISE EXCEPTION 'stale IR predecessor'; END IF;
 END IF;
 INSERT INTO plaa.settlement_batch(allocation_source,round_id,source,source_ref,source_period,settled_at,created_by,manifest_id,predecessor_batch_id,input_manifest,calculation_policy_version)
 VALUES(src,rid,q->>'source',q->>'source_ref',r.period,(q->>'occurred_at')::timestamptz,q->>'actor',m,predecessor,
 q->'inputs'||jsonb_build_object('allocation_snapshot',(SELECT jsonb_agg(to_jsonb(a)) FROM plaa.round_category_allocation a WHERE round_id=rid)),q->>'policy_version') RETURNING settlement_batch_id INTO id;
 IF src='incentivized_activities' AND (jsonb_typeof(q->'categories') IS DISTINCT FROM 'array' OR jsonb_array_length(q->'categories')=0) THEN RAISE EXCEPTION 'categories required'; END IF;
 FOR c IN SELECT value FROM jsonb_array_elements(CASE WHEN src='incentivized_activities' THEN q->'categories' ELSE jsonb_build_array(q) END) LOOP
 cat=CASE WHEN src='incentivized_activities' THEN (c->>'category')::bigint END;
 IF src='incentivized_activities' THEN
 SELECT settlement_batch_id INTO predecessor FROM plaa.round_category_current WHERE round_id=rid AND category_id=cat;
 expected=(c->>'expected_predecessor')::bigint;
 IF predecessor IS DISTINCT FROM expected THEN RAISE EXCEPTION 'stale IA predecessor'; END IF;
 INSERT INTO plaa.round_category_result(settlement_batch_id,round_id,category_id,total_points,plaa_distributed,predecessor_batch_id)
 VALUES(id,rid,cat,plaa.exact((c->>'total_points')::numeric,14,2),plaa.exact((c->>'distributed')::numeric,20,8),predecessor);
 END IF;
 total=plaa.exact((c->>'distributed')::numeric,20,8); actual=0;
 IF total<0 OR jsonb_typeof(c->'issuances') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'nonnegative confirmed total and issuance array required'; END IF;
 FOR o IN SELECT * FROM plaa.plaa_ledger_entry WHERE settlement_batch_id=predecessor AND category_id IS NOT DISTINCT FROM cat AND entry_type='issuance' ORDER BY entry_id LOOP
 INSERT INTO plaa.plaa_ledger_entry(aa_id,round_id,settlement_batch_id,allocation_source,category_id,entry_type,amount,effective_at,source_ref,reverses_entry_id,created_by,manifest_id)
 VALUES(o.aa_id,o.round_id,o.settlement_batch_id,o.allocation_source,o.category_id,'reversal',-o.amount,o.effective_at,'manifest:'||m||':reverse:'||o.entry_id,o.entry_id,q->>'actor',m);
 END LOOP;
 FOR e IN SELECT value FROM jsonb_array_elements(c->'issuances') LOOP
 INSERT INTO plaa.plaa_ledger_entry(aa_id,round_id,settlement_batch_id,allocation_source,category_id,entry_type,amount,effective_at,source_ref,created_by,manifest_id)
 VALUES((e->>'aa_id')::bigint,rid,id,src,cat,'issuance',plaa.exact((e->>'amount')::numeric,20,8),(q->>'effective_at')::timestamptz,'manifest:'||m||':'||coalesce(cat::text,'ir')||':'||(e->>'aa_id'),q->>'actor',m);
 actual=actual+plaa.exact((e->>'amount')::numeric,20,8);
 END LOOP;
 IF actual<>total THEN RAISE EXCEPTION 'confirmed issuance set does not reconcile'; END IF;
 IF src='incentivized_activities' THEN
 INSERT INTO plaa.round_category_current(round_id,category_id,settlement_batch_id) VALUES(rid,cat,id) ON CONFLICT(round_id,category_id) DO UPDATE SET settlement_batch_id=excluded.settlement_batch_id;
 ELSE
 INSERT INTO plaa.ir_current(round_id,settlement_batch_id) VALUES(rid,id) ON CONFLICT(round_id) DO UPDATE SET settlement_batch_id=excluded.settlement_batch_id;
 END IF;
 END LOOP;
 UPDATE plaa.round SET status='settled' WHERE round_id=rid; RETURN id;
END $$;

CREATE FUNCTION plaa.revise_holding(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint; old plaa.trust_holding_snapshot; month date=(q->>'month')::date; asset_key text=q->>'asset';
BEGIN
 m=ingest.claim(q,'trust_holding'); SELECT holding_snapshot_id INTO id FROM plaa.trust_holding_snapshot WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('holding:'||month||':'||asset_key,0));
 SELECT * INTO old FROM plaa.trust_holding_snapshot WHERE snapshot_month=month AND asset_code=asset_key ORDER BY revision DESC LIMIT 1;
 IF old.holding_snapshot_id IS DISTINCT FROM (q->>'predecessor')::bigint OR (q->>'revision')::int<>coalesce(old.revision,0)+1 THEN RAISE EXCEPTION 'stale/skipped holding revision'; END IF;
 IF q->>'unit' IS DISTINCT FROM (SELECT default_unit FROM plaa.asset WHERE asset_code=asset_key) THEN RAISE EXCEPTION 'unit mismatch'; END IF;
 INSERT INTO plaa.trust_holding_snapshot(snapshot_month,asset_code,revision,quantity,unit,source_ref,supersedes_snapshot_id,entered_by,manifest_id)
 VALUES(month,asset_key,(q->>'revision')::int,plaa.exact((q->>'quantity')::numeric,24,8),q->>'unit',q->>'source_ref',old.holding_snapshot_id,q->>'actor',m) RETURNING holding_snapshot_id INTO id; RETURN id;
END $$;
CREATE FUNCTION plaa.revise_valuation(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint; old plaa.trust_valuation_snapshot; month date=(q->>'month')::date;
BEGIN
 m=ingest.claim(q,'trust_valuation'); SELECT valuation_snapshot_id INTO id FROM plaa.trust_valuation_snapshot WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('valuation:'||month,0));
 SELECT * INTO old FROM plaa.trust_valuation_snapshot WHERE reporting_month=month ORDER BY revision DESC LIMIT 1;
 IF old.valuation_snapshot_id IS DISTINCT FROM (q->>'predecessor')::bigint OR (q->>'revision')::int<>coalesce(old.revision,0)+1 THEN RAISE EXCEPTION 'stale/skipped valuation revision'; END IF;
 INSERT INTO plaa.trust_valuation_snapshot(reporting_month,revision,trust_value_usd,nav_usd_per_plaa,source_ref,supersedes_snapshot_id,received_at,imported_by,manifest_id)
 VALUES(month,(q->>'revision')::int,plaa.exact((q->>'trust_value')::numeric,24,8),plaa.exact((q->>'nav')::numeric,20,8),q->>'source_ref',old.valuation_snapshot_id,(q->>'received_at')::timestamptz,q->>'actor',m) RETURNING valuation_snapshot_id INTO id; RETURN id;
END $$;
CREATE FUNCTION plaa.record_auction(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint;
BEGIN m=ingest.claim(q,'auction'); SELECT auction_id INTO id FROM plaa.buyback_auction WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 INSERT INTO plaa.buyback_auction(round_id,auction_number,source,source_ref,opened_at,closed_at,raw_payload,manifest_id)
 VALUES((q->>'round')::bigint,(q->>'number')::int,q->>'source',q->>'source_ref',(q->>'opened_at')::timestamptz,(q->>'closed_at')::timestamptz,q,m) RETURNING auction_id INTO id; RETURN id;
END $$;
CREATE FUNCTION plaa.record_bid(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint;
BEGIN m=ingest.claim(q,'bid'); SELECT bid_id INTO id FROM plaa.buyback_bid WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 INSERT INTO plaa.buyback_bid(auction_id,aa_id,source_ref,price_usd_per_right,rights_bid,bid_amount_usd,source_format_version,submitted_at,raw_payload,manifest_id)
 VALUES((q->>'auction')::bigint,(q->>'aa_id')::bigint,q->>'source_ref',plaa.exact((q->>'price')::numeric,20,8),plaa.exact((q->>'quantity')::numeric,20,8),CASE WHEN q->>'source_amount' IS NOT NULL THEN plaa.exact((q->>'source_amount')::numeric,20,8) END,q->>'format',(q->>'occurred_at')::timestamptz,q,m) RETURNING bid_id INTO id; RETURN id;
END $$;
CREATE VIEW plaa.v_quantity_bid WITH(security_invoker=true) AS SELECT bid_id,auction_id,aa_id,price_usd_per_right,rights_bid,bid_amount_usd,price_usd_per_right*rights_bid AS calculated_notional_usd,source_format_version FROM plaa.buyback_bid;
CREATE VIEW plaa.v_trust_holding_current WITH(security_invoker=true) AS SELECT DISTINCT ON(snapshot_month,asset_code) * FROM plaa.trust_holding_snapshot ORDER BY snapshot_month,asset_code,revision DESC;
CREATE VIEW plaa.v_trust_valuation_current WITH(security_invoker=true) AS SELECT DISTINCT ON(reporting_month) * FROM plaa.trust_valuation_snapshot ORDER BY reporting_month,revision DESC;
CREATE FUNCTION plaa.balance_as_of(effective_cutoff timestamptz,known_cutoff timestamptz DEFAULT 'infinity') RETURNS TABLE(aa_id bigint,ia_net_plaa numeric,ir_net_plaa numeric,unallocated_net_plaa numeric,plaa_balance numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT aa_id,coalesce(sum(amount) FILTER(WHERE allocation_source='incentivized_activities'),0),coalesce(sum(amount) FILTER(WHERE allocation_source='infra_rewards'),0),coalesce(sum(amount) FILTER(WHERE allocation_source IS NULL),0),sum(amount) FROM plaa.plaa_ledger_entry WHERE effective_at<=effective_cutoff AND created_at<=known_cutoff GROUP BY aa_id;
$$;
CREATE FUNCTION plaa.holdings_as_reported(cutoff timestamptz) RETURNS SETOF plaa.trust_holding_snapshot LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT DISTINCT ON(snapshot_month,asset_code) * FROM plaa.trust_holding_snapshot WHERE created_at<=cutoff ORDER BY snapshot_month,asset_code,revision DESC;
$$;
CREATE FUNCTION plaa.valuation_as_reported(cutoff timestamptz) RETURNS SETOF plaa.trust_valuation_snapshot LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT DISTINCT ON(reporting_month) * FROM plaa.trust_valuation_snapshot WHERE received_at<=cutoff AND created_at<=cutoff ORDER BY reporting_month,revision DESC;
$$;
RESET ROLE;

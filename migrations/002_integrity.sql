SET ROLE plaa_owner;

-- Untyped API numeric inputs are checked BEFORE assignment to typmod columns.
CREATE FUNCTION plaa.exact(n numeric, p int, s int) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF n IS NULL OR n::text IN ('NaN','Infinity','-Infinity') OR n <> trunc(n,s) OR abs(n) >= power(10::numeric,p-s) THEN
  RAISE EXCEPTION 'invalid exact numeric(%,%): %',p,s,n USING ERRCODE='22003';
 END IF; RETURN n;
END $$;

CREATE TABLE ingest.source_manifest (
 manifest_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 kind text NOT NULL, source text NOT NULL CHECK (btrim(source) <> ''),
 source_ref text NOT NULL CHECK (btrim(source_ref) <> ''),
 source_revision int NOT NULL CHECK (source_revision > 0),
 source_occurred_at timestamptz NOT NULL CHECK (isfinite(source_occurred_at)),
 received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 content_hash text NOT NULL CHECK (length(content_hash)=64),
 payload jsonb NOT NULL, import_batch text, actor text NOT NULL,
 UNIQUE(source,source_ref)
);
ALTER TABLE ingest.raw_submission ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.activity_submission ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.point_event ADD COLUMN manifest_id bigint NOT NULL REFERENCES ingest.source_manifest;
ALTER TABLE plaa.settlement_batch ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.settlement_batch ADD COLUMN predecessor_batch_id bigint REFERENCES plaa.settlement_batch;
ALTER TABLE plaa.settlement_batch ADD COLUMN input_manifest jsonb NOT NULL;
ALTER TABLE plaa.settlement_batch ADD COLUMN calculation_policy_version text NOT NULL;
ALTER TABLE plaa.buyback_auction ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.buyback_bid ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.trust_holding_snapshot ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.trust_valuation_snapshot ADD COLUMN manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest;
ALTER TABLE plaa.audit_log ADD COLUMN database_principal text NOT NULL DEFAULT session_user;
ALTER TABLE plaa.audit_log ADD COLUMN transaction_id bigint NOT NULL DEFAULT txid_current();
ALTER TABLE plaa.audit_log ADD COLUMN correlation text;
CREATE TABLE plaa.point_correction_manifest (
 correction_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 manifest_id bigint NOT NULL UNIQUE REFERENCES ingest.source_manifest,
 original_event_id bigint NOT NULL UNIQUE REFERENCES plaa.point_event,
 correction_version int NOT NULL CHECK(correction_version>0),
 reason text NOT NULL CHECK(btrim(reason)<>''), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE plaa.ir_current (
 round_id bigint PRIMARY KEY REFERENCES plaa.round,
 settlement_batch_id bigint NOT NULL REFERENCES plaa.settlement_batch
);
CREATE TABLE plaa.kudos_policy (
 policy_version text PRIMARY KEY, mode text NOT NULL CHECK(mode IN ('receiver_only','paired')),
 owner_approval text NOT NULL CHECK(btrim(owner_approval)<>''),
 valid_from date NOT NULL, valid_to date, synthetic_only boolean NOT NULL DEFAULT true,
 CHECK(valid_to IS NULL OR valid_to>valid_from), created_at timestamptz NOT NULL DEFAULT now()
);
-- No runtime policy-approval grant. Production policy insertion requires reviewed migration.
ALTER TABLE plaa.member_identity ADD COLUMN verified boolean NOT NULL DEFAULT false;
ALTER TABLE plaa.member_identity ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.member_identity ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.round ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.category ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.category ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.activity ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.activity_point_value ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.activity_point_value ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.round_category_allocation ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.round_category_allocation ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.round_category_current ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.ir_current ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE plaa.round ADD CHECK(round_number>0 AND plaa_pool>=0 AND NOT isempty(period) AND NOT lower_inf(period) AND NOT upper_inf(period));
ALTER TABLE plaa.round_category_allocation ADD CHECK(plaa_allocated>=0);
ALTER TABLE plaa.activity_point_value ADD CHECK (coalesce(points_default,points_min,points_max) IS NOT NULL AND coalesce(points_default,0)>=0 AND coalesce(points_min,0)>=0 AND coalesce(points_max,0)>=0 AND (points_default IS NULL OR points_min IS NULL OR points_default>=points_min) AND (points_default IS NULL OR points_max IS NULL OR points_default<=points_max));
ALTER TABLE plaa.round_category_result ADD CHECK(total_points>=0 AND plaa_distributed>=0);
ALTER TABLE plaa.round_category_result ADD FOREIGN KEY(round_id,category_id) REFERENCES plaa.round_category_allocation;
ALTER TABLE plaa.plaa_ledger_entry ADD FOREIGN KEY(settlement_batch_id,round_id) REFERENCES plaa.settlement_batch(settlement_batch_id,round_id);
ALTER TABLE plaa.buyback_auction ADD UNIQUE(round_id);
ALTER TABLE plaa.buyback_auction ADD CHECK(closed_at IS NULL OR opened_at IS NULL OR closed_at>opened_at);
ALTER TABLE plaa.buyback_bid ADD CHECK(bid_amount_usd IS NULL OR bid_amount_usd>=0);
ALTER TABLE plaa.buyback_bid ADD CHECK(source_format_version='quantity-v1');
ALTER TABLE plaa.trust_holding_snapshot ADD CHECK(extract(day FROM snapshot_month)=1 AND isfinite(snapshot_month) AND quantity>=0 AND btrim(unit)<>'');
ALTER TABLE plaa.trust_valuation_snapshot ADD CHECK(extract(day FROM reporting_month)=1 AND isfinite(reporting_month) AND trust_value_usd>=0 AND nav_usd_per_plaa>=0);
ALTER TABLE plaa.point_event ADD CHECK(points<>0 AND ((event_type='reversal')=(reverses_event_id IS NOT NULL)));
ALTER TABLE plaa.point_event ADD FOREIGN KEY(round_id,activity_id) REFERENCES plaa.round_activity;
ALTER TABLE plaa.point_event ADD CHECK(isfinite(source_occurred_at));
ALTER TABLE plaa.plaa_ledger_entry ADD CHECK(isfinite(effective_at));
ALTER TABLE plaa.member_identity ADD CHECK(id_type IN ('directory_uid','legacy_member_uid','email','wallet','surus') AND btrim(id_value)=id_value AND id_value<>'' AND (id_type<>'email' OR id_value=lower(id_value)) AND isfinite(valid_from) AND (valid_to IS NULL OR isfinite(valid_to)));

CREATE FUNCTION plaa.immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN RAISE EXCEPTION '% is append-only',TG_TABLE_NAME USING ERRCODE='55000'; END $$;
CREATE FUNCTION plaa.audit_write() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE b jsonb; a jsonb; keys text;
BEGIN
 IF TG_OP<>'INSERT' THEN b=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN a=to_jsonb(NEW); END IF;
 SELECT string_agg(k.attname||'='||(coalesce(a,b)->>k.attname), ',' ORDER BY array_position(i.indkey::smallint[],k.attnum)) INTO keys
 FROM pg_index i JOIN pg_attribute k ON k.attrelid=i.indrelid AND k.attnum=ANY(i.indkey)
 WHERE i.indrelid=TG_RELID AND i.indisprimary;
 INSERT INTO plaa.audit_log(actor,action,table_name,row_pk,before,after,correlation)
 VALUES(coalesce(a->>'created_by',a->>'entered_by',a->>'imported_by',a->>'updated_by',a->>'actor',session_user),TG_OP,TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME,coalesce(keys,'?'),b,a,
 coalesce(a->>'manifest_id',a->>'source_ref',txid_current()::text));
 RETURN coalesce(NEW,OLD);
END $$;
CREATE FUNCTION plaa.touch() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN NEW.updated_at=clock_timestamp(); RETURN NEW; END $$;
CREATE FUNCTION plaa.validate_point() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE old plaa.point_event; v plaa.activity_point_value; s plaa.activity_submission;
BEGIN
 IF NOT EXISTS(SELECT FROM plaa.round WHERE round_id=NEW.round_id AND period @> (NEW.source_occurred_at AT TIME ZONE 'UTC')::date) THEN RAISE EXCEPTION 'point outside round'; END IF;
 IF NEW.submission_id IS NOT NULL THEN
 SELECT * INTO STRICT s FROM plaa.activity_submission WHERE submission_id=NEW.submission_id;
 IF (s.aa_id,s.round_id,s.activity_id) IS DISTINCT FROM (NEW.aa_id,NEW.round_id,NEW.activity_id) THEN RAISE EXCEPTION 'submission linkage'; END IF;
 END IF;
 IF NEW.activity_point_value_id IS NOT NULL THEN
 SELECT * INTO STRICT v FROM plaa.activity_point_value WHERE activity_point_value_id=NEW.activity_point_value_id;
 IF v.activity_id<>NEW.activity_id OR NOT daterange(v.valid_from,v.valid_to,'[)') @> (NEW.source_occurred_at AT TIME ZONE 'UTC')::date THEN RAISE EXCEPTION 'point version/time mismatch'; END IF;
 END IF;
 IF NEW.event_type='reversal' THEN
 SELECT * INTO STRICT old FROM plaa.point_event WHERE point_event_id=NEW.reverses_event_id;
 IF old.event_type='reversal' OR (NEW.aa_id,NEW.round_id,NEW.activity_id,NEW.points,NEW.activity_point_value_id,NEW.source_occurred_at) IS DISTINCT FROM (old.aa_id,old.round_id,old.activity_id,-old.points,old.activity_point_value_id,old.source_occurred_at) THEN RAISE EXCEPTION 'invalid point reversal'; END IF;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER validate_point BEFORE INSERT ON plaa.point_event FOR EACH ROW EXECUTE FUNCTION plaa.validate_point();
CREATE FUNCTION plaa.freeze_point_value() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN
 IF (NEW.activity_id,NEW.valid_from,NEW.points_default,NEW.points_min,NEW.points_max) IS DISTINCT FROM (OLD.activity_id,OLD.valid_from,OLD.points_default,OLD.points_min,OLD.points_max) OR OLD.valid_to IS NOT NULL OR NEW.valid_to IS NULL THEN RAISE EXCEPTION 'schedule is immutable except open closure'; END IF;
 IF EXISTS(SELECT FROM plaa.point_event WHERE activity_point_value_id=OLD.activity_point_value_id AND (source_occurred_at AT TIME ZONE 'UTC')::date>=NEW.valid_to) THEN RAISE EXCEPTION 'closure precedes recorded use'; END IF; RETURN NEW;
END $$;
CREATE TRIGGER freeze_point_value BEFORE UPDATE ON plaa.activity_point_value FOR EACH ROW EXECUTE FUNCTION plaa.freeze_point_value();
CREATE FUNCTION plaa.validate_ledger() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE o plaa.plaa_ledger_entry; b plaa.settlement_batch;
BEGIN
 IF NEW.settlement_batch_id IS NOT NULL THEN
 SELECT * INTO STRICT b FROM plaa.settlement_batch WHERE settlement_batch_id=NEW.settlement_batch_id;
 IF (NEW.round_id,NEW.allocation_source) IS DISTINCT FROM (b.round_id,b.allocation_source) OR (b.allocation_source='infra_rewards' AND NEW.category_id IS NOT NULL) THEN RAISE EXCEPTION 'batch linkage'; END IF;
 END IF;
 IF NEW.entry_type='reversal' THEN
 SELECT * INTO STRICT o FROM plaa.plaa_ledger_entry WHERE entry_id=NEW.reverses_entry_id;
 IF o.entry_type='reversal' OR (NEW.aa_id,NEW.round_id,NEW.settlement_batch_id,NEW.allocation_source,NEW.category_id,NEW.amount,NEW.effective_at) IS DISTINCT FROM (o.aa_id,o.round_id,o.settlement_batch_id,o.allocation_source,o.category_id,-o.amount,o.effective_at) THEN RAISE EXCEPTION 'invalid ledger reversal'; END IF;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER validate_ledger BEFORE INSERT ON plaa.plaa_ledger_entry FOR EACH ROW EXECUTE FUNCTION plaa.validate_ledger();
CREATE FUNCTION plaa.validate_result() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM plaa.settlement_batch WHERE settlement_batch_id=NEW.settlement_batch_id AND allocation_source='incentivized_activities' AND round_id=NEW.round_id) THEN RAISE EXCEPTION 'IA result linkage'; END IF;
 IF (SELECT coalesce(sum(amount),0) FROM plaa.plaa_ledger_entry WHERE settlement_batch_id=NEW.settlement_batch_id AND category_id=NEW.category_id AND entry_type='issuance')<>NEW.plaa_distributed THEN RAISE EXCEPTION 'issuance/result mismatch'; END IF; RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER reconcile_result AFTER INSERT ON plaa.round_category_result DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION plaa.validate_result();

-- Infrastructure is active before any example/backfill, including initial config.
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('plaa','ingest') AND tablename<>'audit_log' LOOP
 EXECUTE format('CREATE TRIGGER audit_write AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION plaa.audit_write()',r.schemaname,r.tablename);
 IF EXISTS(SELECT FROM information_schema.columns WHERE table_schema=r.schemaname AND table_name=r.tablename AND column_name='updated_at') THEN EXECUTE format('CREATE TRIGGER touch BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION plaa.touch()',r.schemaname,r.tablename); END IF;
 END LOOP;
 FOR r IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('plaa','ingest') AND tablename IN ('audit_log','source_manifest','point_event','point_correction_manifest','plaa_ledger_entry','settlement_batch','round_category_result','trust_holding_snapshot','trust_valuation_snapshot','buyback_auction','buyback_bid','kudos_policy') LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE OR TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION plaa.immutable()',r.schemaname,r.tablename);
 END LOOP;
END $$;
RESET ROLE;

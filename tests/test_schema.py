#!/usr/bin/env python3
"""Stdlib/psql integration tests against an explicitly disposable cluster only."""
import concurrent.futures
import copy
from decimal import Decimal
import json
import os
import re
from pathlib import Path
import subprocess
import time
import unittest

MARKER = Path(os.environ.get('PLAA_DISPOSABLE_MARKER', '/nonexistent'))
if not MARKER.is_file() or MARKER.read_text() != 'new-private-cluster-only':
    raise SystemExit('Refusing tests without disposable-runner marker')
PSQL = json.loads(os.environ['PLAA_TEST_PSQL']) + ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1']


def execute(sql, role=None, error=False):
    if role:
        # SET SESSION AUTHORIZATION models actual login privileges, not superuser SET ROLE.
        sql = f'SET SESSION AUTHORIZATION {role};\n' + sql
    result = subprocess.run(PSQL, input=sql, text=True, capture_output=True)
    if error:
        if result.returncode == 0:
            raise AssertionError('Unexpected success: ' + sql)
        return result.stderr
    if result.returncode:
        raise AssertionError(result.stderr + '\nSQL: ' + sql)
    return result.stdout.strip()


def call(fn, q):
    return "SELECT " + fn + "('" + json.dumps(q).replace("'", "''") + "'::jsonb);"


def manifest(ref):
    return json.loads(execute("SELECT payload FROM ingest.source_manifest WHERE source_ref='" + ref + "';")) | {'actor': 'synthetic-test-operator'}


def request(ref, **kw):
    return dict(source='synthetic-test', source_ref=ref, revision=1, occurred_at='2026-09-01T00:00:00Z', actor='synthetic-test-operator', **kw)


class SchemaTests(unittest.TestCase):
    def deny(self, sql, role='plaa_member_reader', contains=None):
        message = execute(sql, role, error=True)
        if contains:
            self.assertIn(contains, message)

    def test_001_fixture_every_core_entity_and_empty_exports(self):
        tables = execute("SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname IN ('plaa','ingest') ORDER BY 1;").splitlines()
        for table in tables:
            with self.subTest(table=table):
                self.assertGreater(int(execute(f'SELECT count(*) FROM {table};')), 0)
        tables = execute("SELECT tablename FROM pg_tables WHERE schemaname='export' AND tablename<>'release_contract';").splitlines()
        self.assertEqual(len(tables), 7)
        for table in tables:
            self.assertEqual(execute(f'SELECT count(*) FROM export.{table};', 'plaa_export_reader'), '0')
        self.assertEqual(execute("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('plaa','ingest') AND c.relkind='r' AND NOT(c.relrowsecurity AND c.relforcerowsecurity);"), '0')

    def test_002_audit_from_first_write(self):
        self.assertEqual(execute("SELECT table_name FROM plaa.audit_log ORDER BY audit_id LIMIT 1;"), 'plaa.kudos_policy')
        self.assertEqual(execute("SELECT count(*) FROM plaa.audit_log WHERE table_name='ingest.source_manifest' AND action='INSERT';"), execute('SELECT count(*) FROM ingest.source_manifest;'))
        self.assertEqual(execute("SELECT count(*) FROM plaa.audit_log WHERE actor='' OR row_pk='?' OR correlation IS NULL OR database_principal IS NULL;"), '0')
        for role in ('plaa_admin','plaa_ingest','plaa_member_reader','plaa_export_reader'):
            self.deny('UPDATE plaa.audit_log SET actor=\'forged\';', role)
            self.deny('TRUNCATE plaa.audit_log;', role)
        self.deny('DELETE FROM plaa.audit_log;', 'plaa_owner', 'append-only')

    def test_003_identity_temporal_reuse_and_verification(self):
        sql = """BEGIN; SELECT plaa.add_identity(1,'legacy_member_uid','synthetic-reuse','2025-01-01','2025-02-01',true);
        SELECT plaa.add_identity(2,'legacy_member_uid','synthetic-reuse','2025-02-01',NULL,true);
        SELECT plaa.resolve_identity('legacy_member_uid','synthetic-reuse','2025-01-15');
        SELECT plaa.resolve_identity('legacy_member_uid','synthetic-reuse','2025-02-01'); ROLLBACK;"""
        self.assertEqual(execute(sql,'plaa_admin').splitlines()[-2:], ['1','2'])
        self.deny("BEGIN; SELECT plaa.add_identity(1,'legacy_member_uid','overlap','2025-01-01',NULL,true); SELECT plaa.add_identity(2,'legacy_member_uid','overlap','2025-02-01',NULL,true);",'plaa_admin','conflicting key')
        for end in ('2025-01-01','2024-12-01'):
            self.deny(f"SELECT plaa.add_identity(1,'email','synthetic@example.invalid','2025-01-01','{end}',false);",'plaa_admin')
        self.assertEqual(execute("BEGIN; SELECT plaa.add_identity(1,'email',' Synthetic@Example.Invalid ','2025-01-01',NULL,false); SELECT coalesce(plaa.resolve_identity('email','synthetic@example.invalid','2025-02-01')::text,'NONE'); ROLLBACK;",'plaa_admin').splitlines()[-1], 'NONE')

    def test_004_point_schedule_history(self):
        self.assertEqual(execute('SELECT points FROM plaa.point_event WHERE point_event_id=1;'), '10.00')
        self.assertEqual(execute("SELECT activity_point_value_id FROM plaa.activity_point_value WHERE activity_id=1 AND daterange(valid_from,valid_to,'[)') @> '2026-08-20'::date;"), '3')
        self.assertEqual(execute("SELECT count(*) FROM plaa.audit_log WHERE table_name='plaa.activity_point_value' AND action='UPDATE' AND before->>'valid_to' IS NULL AND after->>'valid_to'='2026-08-20';"), '1')
        self.deny("SELECT plaa.add_point_value(1,'2026-08-15','2026-08-21',10,10,10);",'plaa_admin','conflicting key')
        self.deny("SELECT plaa.add_point_value(1,'2027-01-01','2027-01-01',10,10,10);",'plaa_admin')
        self.deny("SELECT plaa.succeed_point_value(2,'2026-08-12',10,10,10);",'plaa_admin','recorded use')
        self.deny('UPDATE plaa.activity_point_value SET points_default=99 WHERE activity_point_value_id=1;','plaa_owner','immutable')

    def test_005_submission_replay_conflict_and_triage(self):
        q = manifest('synthetic-submission-1')
        self.assertEqual(execute(call('ingest.land_submission',q),'plaa_ingest'), '1')
        self.assertEqual(execute('SELECT ingest.process_submission(1);','plaa_ingest'), '1')
        self.assertEqual(execute("SELECT plaa.review_submission(1,'accepted','synthetic-reviewer','retry');",'plaa_admin'), '1')
        q['import_batch']='another-batch'
        self.assertEqual(execute(call('ingest.land_submission',q),'plaa_ingest'), '1')
        q['payload']={'changed':True}
        self.deny(call('ingest.land_submission',q),'plaa_ingest','payload conflict')
        q['source_ref']='synthetic-unresolved'; q['id_value']='unknown-synthetic-subject'
        raw = execute(call('ingest.land_submission',q),'plaa_ingest')
        self.assertEqual(execute(f'SELECT ingest.process_submission({raw});','plaa_ingest'), '')
        self.assertIn('unresolved',execute('SELECT error FROM ingest.triage_queue();','plaa_admin'))

    def test_006_kudos_modes_retry_and_policy_gates(self):
        for ref, count in [('kudos-receiver-1','1'),('kudos-paired-1','2')]:
            q=manifest(ref); q['import_batch']='new-batch'
            execute(call('plaa.import_kudos',q),'plaa_ingest')
            self.assertEqual(execute(f"SELECT count(*) FROM plaa.point_event WHERE source_ref='{ref}';"),count)
            q['points']='30'; self.deny(call('plaa.import_kudos',q),'plaa_ingest','payload conflict')
        q=manifest('kudos-paired-1'); q['source_ref']='missing-policy'; q['policy_version']='unapproved'
        self.deny(call('plaa.import_kudos',q),'plaa_ingest')
        q['policy_version']='synthetic-paired-v1'; q['source']='production'
        self.deny(call('plaa.import_kudos',q),'plaa_ingest','synthetic policy')
        self.assertEqual(execute("SELECT sum(points) FROM plaa.point_event WHERE source_ref='kudos-paired-1';"),'0.00')

    def test_007_point_correction_and_invalid_reversal(self):
        q=manifest('point-correction-1')
        self.assertEqual(execute(call('plaa.correct_point',q),'plaa_admin'),'1')
        q['source_ref']='second-reversal'; self.deny(call('plaa.correct_point',q),'plaa_admin')
        q['source_ref']='reverse-reversal'; q['original']=2; self.deny(call('plaa.correct_point',q),'plaa_admin','invalid point reversal')
        self.assertEqual(execute('SELECT sum(points) FROM plaa.point_event WHERE aa_id=1 AND activity_id=1;'),'12.00')

    def test_008_exact_numeric_no_silent_rounding(self):
        for bad in ('1.001','1000000000000','NaN','Infinity','-Infinity'):
            self.deny(f"SELECT plaa.add_point_value(1,'2027-01-01',NULL,'{bad}',NULL,NULL);",'plaa_admin','invalid exact numeric')
        q=manifest('bid-1'); q['source_ref']='bad-bid-scale'; q['price']='1.123456789'
        self.deny(call('plaa.record_bid',q),'plaa_ingest','invalid exact numeric')
        q=manifest('holding-aug-r2'); q.update(source_ref='bad-holding-scale',predecessor=2,revision=3,quantity='1.123456789')
        self.deny(call('plaa.revise_holding',q),'plaa_admin','invalid exact numeric')
        self.assertEqual(execute("SELECT plaa.exact(999999999999.99999999,20,8);"),'999999999999.99999999')

    def test_009_raw_bid_preservation_and_no_holdings_effect(self):
        self.assertEqual(execute('SELECT bid_amount_usd,calculated_notional_usd FROM plaa.v_quantity_bid WHERE bid_id=1;'),'7.00000000|6.0000000000000000')
        self.assertEqual(execute('SELECT bid_amount_usd IS NULL FROM plaa.buyback_bid WHERE bid_id=2;'),'t')
        before=execute('SELECT sum(amount) FROM plaa.plaa_ledger_entry;')
        q=manifest('bid-1'); q['source_ref']='additional-bid'; execute(call('plaa.record_bid',q),'plaa_ingest')
        self.assertEqual(execute('SELECT sum(amount) FROM plaa.plaa_ledger_entry;'),before)
        q['source_ref']='spend-only'; q['format']='maximum-spend-v1'
        self.deny(call('plaa.record_bid',q),'plaa_ingest')

    def test_010_member_context_spoof_and_pool_cleanup(self):
        for setting in ('1','2','garbage',''):
            self.assertEqual(execute(f"SET app.aa_id='{setting}'; SELECT count(*) FROM plaa.member;",'plaa_member_reader'),'0')
        sql="""BEGIN; SELECT plaa.bind_directory('synthetic-subject-1','synthetic-request');
        SET LOCAL ROLE plaa_member_reader; SET LOCAL app.aa_id='2';
        SELECT count(*) FROM plaa.member; SELECT aa_id FROM plaa.v_member_balance;
        SELECT count(*) FROM plaa.point_event p JOIN plaa.member_identity i USING(aa_id) WHERE p.aa_id=2;
        COMMIT; BEGIN; SET LOCAL ROLE plaa_member_reader; SELECT count(*) FROM plaa.member; COMMIT;"""
        self.assertEqual(execute(sql,'plaa_backend').splitlines(),['1','1','0','0'])
        self.deny("SELECT plaa.bind_directory('synthetic-subject-2','spoof');")
        self.deny('INSERT INTO plaa.request_context VALUES(pg_backend_pid(),txid_current(),2,\'x\',\'x\',now());')
        self.deny('SET ROLE plaa_backend;')
        self.deny('SET ROLE plaa_owner;','plaa_admin')
        self.deny("SELECT plaa.bind_directory('unknown','bad');",'plaa_backend')

    def test_011_runtime_privileges_search_path_and_exports(self):
        for role in ('plaa_admin','plaa_ingest','plaa_member_reader','plaa_aggregate_builder','plaa_export_reader'):
            for sql in ('SELECT * FROM ingest.source_manifest;','SELECT * FROM plaa.audit_log;','UPDATE plaa.plaa_ledger_entry SET amount=0;','TRUNCATE plaa.point_event;','CREATE TABLE public.attack(id int);','SELECT ingest.claim(\'{}\',\'attack\');'):
                self.deny(sql,role)
        for sql in ('SELECT * FROM plaa.member;','SELECT * FROM plaa.v_member_balance;','SELECT * FROM export.release_contract;','SELECT plaa.current_member();','SELECT * FROM export.round_summary JOIN plaa.member ON true;','SET ROLE plaa_aggregate_builder;'):
            self.deny(sql,'plaa_export_reader')
        execute('SET ROLE plaa_owner; CREATE TABLE export.future_private(aa_id bigint); RESET ROLE;')
        self.deny('SELECT * FROM export.future_private;','plaa_export_reader')
        execute('DROP TABLE export.future_private;')
        # A malicious temp table cannot replace the explicitly qualified real table.
        self.assertEqual(execute("BEGIN; CREATE TEMP TABLE member(aa_id bigint); INSERT INTO member VALUES(2); SET LOCAL search_path=pg_temp,public,plaa; SELECT plaa.bind_directory('synthetic-subject-1','temp-attack'); SET LOCAL ROLE plaa_member_reader; SELECT aa_id FROM plaa.member; ROLLBACK;",'plaa_backend').splitlines()[-1],'1')
        self.assertEqual(execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('plaa','ingest','export') AND has_function_privilege('public',p.oid,'EXECUTE');"),'0')
        self.assertEqual(execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('plaa','ingest','export') AND p.prosecdef AND NOT EXISTS(SELECT FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=pg_catalog%');"),'0')
        self.assertEqual(execute("SELECT count(*) FROM pg_roles WHERE rolname LIKE 'plaa_%' AND (rolsuper OR rolbypassrls OR rolinherit OR rolcreaterole);"),'0')

    def test_012_export_contract_shape_and_privacy_counterexamples(self):
        expected={
          'round_summary':'round_number,plaa_pool,total_points,participants,regions_count,activities_live',
          'round_category_metrics':'round_number,category_code,points,plaa_distributed,distinct_contributors',
          'activity_engagement':'round_number,activity_code,submission_count,acceptance_rate,distinct_participants',
          'buyback_bid_summary':'auction_number,bid_count,total_rights,total_source_amount_usd,distinct_bidders',
          'trust_holdings':'month,asset_code,quantity,unit',
          'program_growth':'month,cumulative_onboarded,active_participants,retention_rate',
          'trust_valuation':'month,nav_usd_per_plaa,trust_value_usd'}
        for name,columns in expected.items():
            self.assertEqual(execute(f"SELECT string_agg(column_name,',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='export' AND table_name='{name}';"),columns)
        self.deny("SELECT export.build_release('synthetic-pending-v1');",'plaa_aggregate_builder','no approved')
        # Synthetic attack evidence, NOT a generic release implementation.
        cells={'fine-A':set(range(1,5)), 'fine-B':set(range(5,9))}
        self.assertTrue(all(len(v)<5 for v in cells.values()))
        coarse=set.union(*cells.values()); self.assertEqual(len(coarse),8)
        hidden_total=Decimal('9'); visible_total=Decimal('60'); published_total=Decimal('69')
        self.assertEqual(published_total-visible_total,hidden_total)  # complementary suppression needed
        old=set(range(1,8)); new=set(range(1,9))
        self.assertGreaterEqual(len(old),5); self.assertEqual(new-old,{8})  # k alone fails differencing
        self.assertEqual(execute('SELECT count(*) FROM export.round_summary;','plaa_export_reader'),'0')

    def test_013_ia_correction_chain_partial_zero_replay_rollback(self):
        original=manifest('ia-close-1')
        self.assertEqual(execute(call('plaa.settle',original),'plaa_admin'),'1')
        before=execute('SELECT row_to_json(r) FROM plaa.round_category_result r WHERE settlement_batch_id=1 ORDER BY category_id;')
        q=copy.deepcopy(original); q['categories']=q['categories'][:1]
        pred=1
        for i,total in enumerate(('80','70','0','90'),1):
            q['source_ref']=f'ia-correction-{i}'; q['revision']=i+1
            q['categories'][0].update(expected_predecessor=pred,distributed=total,issuances=[] if total=='0' else [{'aa_id':1,'amount':total}])
            pred=int(execute(call('plaa.settle',q),'plaa_admin'))
            self.assertEqual(execute(call('plaa.settle',q),'plaa_admin'),str(pred))
            self.assertEqual(execute('SELECT settlement_batch_id FROM plaa.round_category_current WHERE category_id=2;'),'1')
            self.assertEqual(Decimal(execute("SELECT sum(amount) FROM plaa.plaa_ledger_entry WHERE category_id=1;")),Decimal(total))
        self.assertEqual(execute('SELECT row_to_json(r) FROM plaa.round_category_result r WHERE settlement_batch_id=1 ORDER BY category_id;'),before)
        q['source_ref']='stale-ia'; self.deny(call('plaa.settle',q),'plaa_admin','stale IA')
        q['source_ref']='rollback-ia'; q['categories'][0]['expected_predecessor']=pred
        snapshot=execute('SELECT count(*),sum(amount) FROM plaa.plaa_ledger_entry;')
        audits=execute('SELECT count(*) FROM plaa.audit_log;')
        # Failure after the function has appended reversals/replacements and moved pointer.
        self.deny('BEGIN;'+call('plaa.settle',q)+'SELECT 1/0; COMMIT;','plaa_admin','division by zero')
        self.assertEqual(execute('SELECT count(*),sum(amount) FROM plaa.plaa_ledger_entry;'),snapshot)
        self.assertEqual(execute('SELECT count(*) FROM plaa.audit_log;'),audits)
        q['source_ref']='halfway-ia'; q['categories'][0]['issuances']=[{'aa_id':1,'amount':'5'},{'aa_id':999999,'amount':'85'}]
        self.deny(call('plaa.settle',q),'plaa_admin','foreign key')
        self.assertEqual(execute('SELECT count(*),sum(amount) FROM plaa.plaa_ledger_entry;'),snapshot)

    def test_014_ir_correction_chain_zero_and_atomicity(self):
        q=manifest('ir-close-1'); self.assertEqual(execute(call('plaa.settle',q),'plaa_admin'),'2')
        pred=2
        for i,total in enumerate(('20','0','30'),1):
            q.update(source_ref=f'ir-correction-{i}',expected_predecessor=pred,distributed=total,issuances=[] if total=='0' else [{'aa_id':1,'amount':total}])
            pred=int(execute(call('plaa.settle',q),'plaa_admin'))
            self.assertEqual(execute(call('plaa.settle',q),'plaa_admin'),str(pred))
            self.assertEqual(Decimal(execute("SELECT sum(amount) FROM plaa.plaa_ledger_entry WHERE allocation_source='infra_rewards';")),Decimal(total))
        q['source_ref']='stale-ir'; self.deny(call('plaa.settle',q),'plaa_admin','stale IR')
        q.update(source_ref='rollback-ir',expected_predecessor=pred)
        before=execute('SELECT count(*) FROM plaa.plaa_ledger_entry;')
        self.deny('BEGIN;'+call('plaa.settle',q)+'SELECT 1/0;','plaa_admin')
        self.assertEqual(execute('SELECT count(*) FROM plaa.plaa_ledger_entry;'),before)
        q.update(source_ref='halfway-ir',issuances=[{'aa_id':1,'amount':'10'},{'aa_id':999999,'amount':'20'}])
        self.deny(call('plaa.settle',q),'plaa_admin','foreign key')
        self.assertEqual(execute('SELECT count(*) FROM plaa.plaa_ledger_entry;'),before)

    def race(self, fn, q1, q2):
        def attempt(q):
            return subprocess.run(PSQL,input='SET SESSION AUTHORIZATION plaa_admin; BEGIN;'+call(fn,q)+'SELECT pg_sleep(0.7); COMMIT;',text=True,capture_output=True)
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            jobs=[pool.submit(attempt,q1),pool.submit(attempt,q2)]
            saw_wait=False
            for _ in range(50):
                if execute("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%synthetic%' AND pid<>pg_backend_pid();")!='0':
                    saw_wait=True
                    break
                time.sleep(0.02)
            results=[job.result() for job in jobs]
        self.assertTrue(saw_wait, 'race must exhibit an actual database lock wait')
        self.assertEqual(sorted(r.returncode==0 for r in results),[False,True],str([(r.stdout,r.stderr) for r in results]))
        self.assertTrue(any('stale' in r.stderr for r in results))

    def test_015_competing_ia_ir_corrections(self):
        for src,ref in [('incentivized_activities','ia-close-1'),('infra_rewards','ir-close-1')]:
            q=manifest(ref)
            if src=='incentivized_activities':
                q['categories']=q['categories'][:1]; q['categories'][0]['expected_predecessor']=int(execute('SELECT settlement_batch_id FROM plaa.round_category_current WHERE category_id=1;'))
            else:
                q['expected_predecessor']=int(execute('SELECT settlement_batch_id FROM plaa.ir_current WHERE round_id=1;'))
            q['source_ref']='race-'+src+'-a'; q2=copy.deepcopy(q);q2['source_ref']='race-'+src+'-b'
            self.race('plaa.settle',q,q2)

    def test_016_linkage_invalid_reversals_and_reconcile(self):
        q=manifest('ia-close-1'); q['source_ref']='wrong-category'; q['categories']=[dict(category=999,expected_predecessor=None,total_points='1',distributed='1',issuances=[dict(aa_id=1,amount='1')])]
        self.deny(call('plaa.settle',q),'plaa_admin','foreign key')
        q=manifest('ia-close-1'); q['source_ref']='unapproved-compute';q['policy_version']='invented-formula'
        self.deny(call('plaa.settle',q),'plaa_admin','confirmed input/policy')
        q=manifest('opening-adjustment-1'); q.update(source_ref='wrong-member-reversal',entry_type='reversal',original=5,aa_id=2,amount='-5')
        self.deny(call('plaa.post_confirmed_entry',q),'plaa_admin','invalid ledger reversal')
        # Trigger-level owner probes complement actual runtime direct-DML denial.
        base="INSERT INTO plaa.plaa_ledger_entry(aa_id,round_id,settlement_batch_id,allocation_source,category_id,entry_type,amount,effective_at,source_ref,reverses_entry_id,created_by,manifest_id) "
        self.deny(base+"SELECT 2,round_id,settlement_batch_id,allocation_source,category_id,'reversal',-amount,effective_at,'invalid-member-probe',entry_id,'synthetic',manifest_id FROM plaa.plaa_ledger_entry WHERE entry_id=1;",'plaa_owner','invalid ledger reversal')
        self.deny(base+"SELECT aa_id,999,settlement_batch_id,allocation_source,category_id,'reversal',-amount,effective_at,'invalid-round-probe',entry_id,'synthetic',manifest_id FROM plaa.plaa_ledger_entry WHERE entry_id=1;",'plaa_owner','batch linkage')
        self.deny("INSERT INTO plaa.round_category_result(settlement_batch_id,round_id,category_id,total_points,plaa_distributed) VALUES(2,1,1,0,0);",'plaa_owner','IA result linkage')
        self.assertEqual(execute("SELECT count(*) FROM plaa.round_category_result r WHERE plaa_distributed<>(SELECT coalesce(sum(amount),0) FROM plaa.plaa_ledger_entry e WHERE e.settlement_batch_id=r.settlement_batch_id AND e.category_id=r.category_id AND entry_type='issuance');"),'0')
        self.assertEqual(execute('SELECT count(*) FROM plaa.v_member_balance WHERE ia_net_plaa+ir_net_plaa+unallocated_net_plaa<>plaa_balance;'),'0')
        self.assertEqual(execute("SELECT string_agg(column_name,',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='plaa' AND table_name='v_member_balance';"),'aa_id,ia_net_plaa,ir_net_plaa,unallocated_net_plaa,plaa_balance')

    def test_017_effective_and_known_as_of_late_import(self):
        cutoff=execute('SELECT clock_timestamp();')
        q=request('late-opening',policy_version='source-confirmed-v1',reason='Synthetic late source',aa_id=8,round=1,entry_type='adjustment',amount='10',effective_at='2026-08-01T00:00:00Z')
        eid=int(execute(call('plaa.post_confirmed_entry',q),'plaa_admin'))
        self.assertEqual(execute(f"SELECT count(*) FROM plaa.balance_as_of('2026-08-31','{cutoff}') WHERE aa_id=8;"),'0')
        self.assertEqual(execute("SELECT plaa_balance FROM plaa.balance_as_of('2026-08-31') WHERE aa_id=8;"),'10.00000000')
        known=execute('SELECT clock_timestamp();')
        q.update(source_ref='late-opening-reversal',entry_type='reversal',original=eid,amount='-10')
        execute(call('plaa.post_confirmed_entry',q),'plaa_admin')
        self.assertEqual(execute(f"SELECT plaa_balance FROM plaa.balance_as_of('2026-08-31','{known}') WHERE aa_id=8;"),'10.00000000')
        self.assertEqual(execute("SELECT plaa_balance FROM plaa.balance_as_of('2026-08-31') WHERE aa_id=8;"),'0.00000000')
        q['source_ref']='repeat-opening-reversal';self.deny(call('plaa.post_confirmed_entry',q),'plaa_admin','duplicate key')

    def test_018_trust_revision_replay_as_reported_and_race(self):
        for fn,ref,table,idcol,view in [('plaa.revise_holding','holding-aug-r2','trust_holding_snapshot','holding_snapshot_id','v_trust_holding_current'),('plaa.revise_valuation','valuation-aug-r2','trust_valuation_snapshot','valuation_snapshot_id','v_trust_valuation_current')]:
            q=manifest(ref);self.assertEqual(execute(call(fn,q),'plaa_admin'),'2')
            q['source_ref']=ref+'-skip';q['revision']=4;q['predecessor']=2
            self.deny(call(fn,q),'plaa_admin','stale/skipped')
            q['revision']=3;q['month']='2026-07-01';self.deny(call(fn,q),'plaa_admin','stale/skipped')
            q['month']='2026-08-01';q['source_ref']=ref+'-race-a';q2=copy.deepcopy(q);q2['source_ref']=ref+'-race-b'
            cutoff=execute('SELECT clock_timestamp();');self.race(fn,q,q2)
            self.assertEqual(execute(f'SELECT revision FROM plaa.{view};'),'3')
            asof='holdings_as_reported' if 'holding' in table else 'valuation_as_reported'
            self.assertEqual(execute(f"SELECT revision FROM plaa.{asof}('{cutoff}');"),'2')
            self.assertEqual(execute(f'SELECT revision FROM plaa.{table} WHERE {idcol}=1;'),'1')
            q['source_ref']=ref+'-invalid-day';q['month']='2026-10-02';q['revision']=1;q['predecessor']=None
            self.deny(call(fn,q),'plaa_admin','check constraint')

    def test_019_immutable_runtime_and_owner_protections(self):
        for table in ('point_event','plaa_ledger_entry','settlement_batch','round_category_result','trust_holding_snapshot','trust_valuation_snapshot','buyback_bid','buyback_auction'):
            self.deny(f'DELETE FROM plaa.{table};','plaa_admin')
            self.deny(f'TRUNCATE plaa.{table} CASCADE;','plaa_owner','append-only')
        self.assertEqual(execute("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='plaa' AND c.relkind='v' AND c.relname IN ('v_member_balance','v_member_round_points','v_quantity_bid') AND 'security_invoker=true'=ANY(c.reloptions);"),'3')


    def test_020_additional_numeric_dates_and_reference_validation(self):
        q=manifest('ia-close-1'); q['source_ref']='bad-settle-scale'
        q['categories']=q['categories'][:1]
        q['categories'][0]['expected_predecessor']=int(execute('SELECT settlement_batch_id FROM plaa.round_category_current WHERE category_id=1;'))
        q['categories'][0]['total_points']='1.001'
        self.deny(call('plaa.settle',q),'plaa_admin','invalid exact numeric')
        q=manifest('valuation-aug-r2');q.update(source_ref='bad-nav',revision=4,predecessor=int(execute('SELECT valuation_snapshot_id FROM plaa.v_trust_valuation_current;')),nav='NaN')
        self.deny(call('plaa.revise_valuation',q),'plaa_admin','invalid exact numeric')
        for start,end in [('2026-08-15','2026-09-15'),('2027-01-01','2027-01-01'),('2027-02-01','2027-01-01'),('-infinity','2020-01-01')]:
            q=dict(number=100,start=start,end=end,pool='1',allocations=[],activities=[],regions=[])
            self.deny(call('plaa.configure_round',q),'plaa_admin')
        q=dict(number=100,start='2026-09-01',end='2026-10-01',pool='1',allocations=[],activities=[],regions=[])
        execute('BEGIN;'+call('plaa.configure_round',q)+'ROLLBACK;','plaa_admin')
        self.deny("SELECT plaa.add_point_value(1,'infinity',NULL,1,1,1);",'plaa_admin')
        self.deny("SELECT plaa.maintain_asset('TEST-ASSET','Synthetic','different-units',true,'synthetic');",'plaa_admin','unit change')

    def test_021_acceptance_successor_and_rollback(self):
        q=manifest('synthetic-submission-1');q.update(source_ref='successor-submission',occurred_at='2026-08-21T12:00:00Z')
        raw=int(execute(call('ingest.land_submission',q),'plaa_ingest'))
        sub=int(execute(f'SELECT ingest.process_submission({raw});','plaa_ingest'))
        audits=execute('SELECT count(*) FROM plaa.audit_log;')
        self.deny(f"BEGIN; SELECT plaa.review_submission({sub},'accepted','synthetic-reviewer','injected rollback'); SELECT 1/0;",'plaa_admin')
        self.assertEqual(execute(f'SELECT status FROM plaa.activity_submission WHERE submission_id={sub};'),'pending_review')
        self.assertEqual(execute(f'SELECT count(*) FROM plaa.point_event WHERE submission_id={sub};'),'0')
        self.assertEqual(execute('SELECT count(*) FROM plaa.audit_log;'),audits)
        event=execute(f"SELECT plaa.review_submission({sub},'accepted','synthetic-reviewer','successor');",'plaa_admin')
        self.assertEqual(execute(f'SELECT points,activity_point_value_id FROM plaa.point_event WHERE point_event_id={event};'),'20.00|3')
        self.assertEqual(execute('SELECT points FROM plaa.point_event WHERE point_event_id=1;'),'10.00')
        self.deny(f"SELECT plaa.review_submission({sub},'rejected','synthetic-reviewer','no rewriting');",'plaa_admin','review is final')

    def test_022_kudos_paired_atomic_failure(self):
        q=manifest('kudos-paired-1');q.update(source_ref='kudos-invalid-giver',giver=999999)
        before=execute('SELECT count(*) FROM plaa.point_event;')
        audits=execute('SELECT count(*) FROM plaa.audit_log;')
        self.deny(call('plaa.import_kudos',q),'plaa_ingest','foreign key')
        self.assertEqual(execute('SELECT count(*) FROM plaa.point_event;'),before)
        self.assertEqual(execute('SELECT count(*) FROM plaa.audit_log;'),audits)
        q.update(source_ref='kudos-outside-round',giver=1,occurred_at='2026-09-10T12:00:00Z')
        self.deny(call('plaa.import_kudos',q),'plaa_ingest','outside round')

    def test_023_trust_original_knowledge_and_payload_conflict(self):
        for fn,ref,asof in [('plaa.revise_holding','holding-aug-r1','holdings_as_reported'),('plaa.revise_valuation','valuation-aug-r1','valuation_as_reported')]:
            q=manifest(ref);q.update(source_ref=ref+'-oct1',month='2026-10-01')
            original=int(execute(call(fn,q),'plaa_admin')); cutoff=execute('SELECT clock_timestamp();')
            q.update(source_ref=ref+'-oct2',predecessor=original,revision=2)
            if 'holding' in fn:q['quantity']='222'
            else:q['trust_value']='2222222'
            execute(call(fn,q),'plaa_admin')
            monthcol='snapshot_month' if 'holding' in fn else 'reporting_month'
            self.assertEqual(execute(f"SELECT revision FROM plaa.{asof}('{cutoff}') WHERE {monthcol}='2026-10-01';"),'1')
            self.assertEqual(execute(f"SELECT revision FROM plaa.{asof}('infinity') WHERE {monthcol}='2026-10-01';"),'2')
            q['source_ref']=ref+'-oct1'
            self.deny(call(fn,q),'plaa_admin','payload conflict')

    def test_024_bid_revision_and_crosswalk_triage(self):
        q=manifest('bid-1');q.update(source_ref='corrected-raw-bid',source_amount='8',supersedes_bid_id=1)
        bid=execute(call('plaa.record_bid',q),'plaa_ingest')
        self.assertEqual(execute(f'SELECT supersedes_bid_id,bid_amount_usd FROM plaa.buyback_bid WHERE bid_id={bid};'),'1|8.00000000')
        self.assertEqual(execute('SELECT bid_amount_usd FROM plaa.buyback_bid WHERE bid_id=1;'),'7.00000000')
        q.update(source_ref='wrong-member-bid-correction',aa_id=2)
        self.deny(call('plaa.record_bid',q),'plaa_ingest','bid revision linkage')
        q=request('pending-crosswalk',legacy_type='legacy_member_uid',legacy_value='synthetic-unknown-legacy')
        crosswalk=execute(call('ingest.stage_crosswalk',q),'plaa_ingest')
        self.assertIn('synthetic-unknown-legacy',execute('SELECT legacy_value FROM ingest.crosswalk_queue();','plaa_admin'))
        execute(f"SELECT ingest.review_crosswalk({crosswalk},NULL,'synthetic-triage','Insufficient evidence');",'plaa_admin')
        self.deny(f"SELECT ingest.review_crosswalk({crosswalk},1,'synthetic-triage','Cannot overwrite');",'plaa_admin','already reviewed')
        self.deny('SELECT * FROM ingest.identity_crosswalk;','plaa_member_reader')

    def test_025_concurrent_exact_retry(self):
        q=manifest('ir-close-1');q.update(source_ref='concurrent-exact-retry',expected_predecessor=int(execute('SELECT settlement_batch_id FROM plaa.ir_current WHERE round_id=1;')))
        def attempt(_):return execute('BEGIN;'+call('plaa.settle',q)+'SELECT pg_sleep(0.2); COMMIT;','plaa_admin').strip()
        with concurrent.futures.ThreadPoolExecutor(2) as pool: ids=list(pool.map(attempt,range(2)))
        self.assertEqual(ids[0],ids[1])
        self.assertEqual(execute("SELECT count(*) FROM ingest.source_manifest WHERE source_ref='concurrent-exact-retry';"),'1')
        q['distributed']='999'
        self.deny(call('plaa.settle',q),'plaa_admin','payload conflict')

    def test_026_invalid_source_category_reversal_and_ir_pointer(self):
        base="INSERT INTO plaa.plaa_ledger_entry(aa_id,round_id,settlement_batch_id,allocation_source,category_id,entry_type,amount,effective_at,source_ref,reverses_entry_id,created_by,manifest_id) "
        self.deny(base+"SELECT aa_id,round_id,settlement_batch_id,'infra_rewards',category_id,'reversal',-amount,effective_at,'wrong-source',entry_id,'synthetic',manifest_id FROM plaa.plaa_ledger_entry WHERE entry_id=1;",'plaa_owner','batch linkage')
        self.deny(base+"SELECT aa_id,round_id,settlement_batch_id,allocation_source,2,'reversal',-amount,effective_at,'wrong-category',entry_id,'synthetic',manifest_id FROM plaa.plaa_ledger_entry WHERE entry_id=1;",'plaa_owner','invalid ledger reversal')
        self.deny(base+"SELECT aa_id,round_id,settlement_batch_id,allocation_source,category_id,'reversal',-amount,effective_at,'reverse-reversal',entry_id,'synthetic',manifest_id FROM plaa.plaa_ledger_entry WHERE entry_type='reversal' ORDER BY entry_id LIMIT 1;",'plaa_owner','invalid ledger reversal')
        self.deny('UPDATE plaa.ir_current SET settlement_batch_id=1 WHERE round_id=1;','plaa_owner','IR pointer linkage')
        self.assertEqual(execute('SELECT count(*) FROM plaa.settlement_reconciliation(1) WHERE confirmed_total<>ledger_net;','plaa_admin'),'0')
        self.assertGreater(int(execute("SELECT count(*) FROM plaa.trust_report('infinity');",'plaa_admin')),0)

    def test_027_backend_rebinding_suspension_and_rollback_cleanup(self):
        self.deny("BEGIN; SELECT plaa.bind_directory('synthetic-subject-1','r1'); SELECT plaa.bind_directory('synthetic-subject-2','r2');",'plaa_backend','duplicate key')
        sql="BEGIN; SELECT plaa.bind_directory('synthetic-subject-1','rolled-back'); ROLLBACK; BEGIN; SET LOCAL ROLE plaa_member_reader; SELECT count(*) FROM plaa.member; COMMIT;"
        self.assertEqual(execute(sql,'plaa_backend').strip(),'0')
        execute("SELECT plaa.set_member_status(7,'suspended');",'plaa_admin')
        self.deny("SELECT plaa.bind_directory('synthetic-subject-7','suspended');",'plaa_backend')
        execute("SELECT plaa.set_member_status(7,'active');",'plaa_admin')
        self.deny("SELECT plaa.bind_directory('synthetic-subject-1','');",'plaa_backend','check constraint')
        self.deny('SELECT * FROM plaa.request_context;','plaa_backend')

    def test_028_reconcile_failure_is_atomic(self):
        for ref in ('ia-close-1','ir-close-1'):
            q=manifest(ref);q['source_ref']='mismatch-'+ref
            if ref.startswith('ia'):
                q['categories']=q['categories'][:1];q['categories'][0]['expected_predecessor']=int(execute('SELECT settlement_batch_id FROM plaa.round_category_current WHERE category_id=1;'));q['categories'][0]['distributed']='101'
            else:q['expected_predecessor']=int(execute('SELECT settlement_batch_id FROM plaa.ir_current;'));q['distributed']='26'
            before=execute('SELECT count(*) FROM plaa.plaa_ledger_entry;'); audits=execute('SELECT count(*) FROM plaa.audit_log;')
            self.deny(call('plaa.settle',q),'plaa_admin','does not reconcile')
            self.assertEqual(execute('SELECT count(*) FROM plaa.plaa_ledger_entry;'),before)
            self.assertEqual(execute('SELECT count(*) FROM plaa.audit_log;'),audits)



    def test_029_erd_matches_catalog_entities_and_foreign_keys(self):
        doc=Path('docs/schema.md').read_text()
        nodes=set(re.findall(r'^    (\w+) \{',doc,re.M))
        def node(s):return s[5:] if s.startswith('plaa.') else s.replace('.','_')
        tables={node(x) for x in execute("SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname IN ('plaa','ingest','export');").splitlines()}
        self.assertEqual(nodes,tables)
        edges={(a,b) for a,b in re.findall(r'^    (\w+) [|o}{-]+ (\w+) :',doc,re.M)}
        foreign_keys=execute("SELECT pn.nspname||'.'||p.relname||'|'||cn.nspname||'.'||c.relname FROM pg_constraint fk JOIN pg_class p ON p.oid=fk.confrelid JOIN pg_namespace pn ON pn.oid=p.relnamespace JOIN pg_class c ON c.oid=fk.conrelid JOIN pg_namespace cn ON cn.oid=c.relnamespace WHERE fk.contype='f' AND cn.nspname IN ('plaa','ingest','export');").splitlines()
        actual={(node(row.split('|')[0]),node(row.split('|')[1])) for row in foreign_keys}
        self.assertEqual(edges,actual)

    def test_030_temp_catalog_shadowing_and_default_function_grants(self):
        # pg_temp must be explicitly last: otherwise it implicitly precedes catalogs.
        execute("BEGIN; CREATE TEMP TABLE pg_index(fake text); CREATE TEMP TABLE pg_attribute(fake text); SET LOCAL search_path=pg_temp,public; SELECT plaa.maintain_region('TEMP-TEST','Synthetic temp attack',true,'synthetic-admin'); ROLLBACK;",'plaa_admin')
        execute("SET ROLE plaa_owner; CREATE FUNCTION export.future_private_fn() RETURNS int LANGUAGE sql AS 'SELECT 1'; RESET ROLE;")
        self.deny('SELECT export.future_private_fn();','plaa_export_reader')
        execute('DROP FUNCTION export.future_private_fn();')
        self.assertEqual(execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('plaa','ingest','export') AND p.prosecdef AND NOT EXISTS(SELECT FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=pg_catalog%pg_temp');"),'0')

    def test_031_finite_dates_nan_and_zero_batch_provenance(self):
        self.deny("SELECT plaa.create_member('Synthetic invalid date',NULL,'infinity');",'plaa_admin','check constraint')
        q=manifest('auction-1');q.update(source_ref='infinite-auction',round=None,number=99,opened_at='-infinity')
        self.deny(call('plaa.record_auction',q),'plaa_admin','check constraint')
        q.update(source_ref='negative-auction-number',number=-1,opened_at='2026-08-25T00:00:00Z')
        self.deny(call('plaa.record_auction',q),'plaa_admin','check constraint')
        self.deny("UPDATE plaa.round SET plaa_pool='NaN' WHERE round_id=1;",'plaa_owner','check constraint')
        for bad in (None,'infinity','-infinity'):
            q=manifest('ir-close-1');q.update(source_ref='zero-missing-time',distributed='0',issuances=[],effective_at=bad,expected_predecessor=int(execute('SELECT settlement_batch_id FROM plaa.ir_current WHERE round_id=1;')))
            self.deny(call('plaa.settle',q),'plaa_admin','finite settlement')
        q.update(source_ref='zero-infinite-cutoff',effective_at='2026-08-31T23:00:00Z')
        q['inputs']['cutoff']='infinity'
        self.deny(call('plaa.settle',q),'plaa_admin','finite settlement')
        self.assertEqual(execute("SELECT count(*) FROM ingest.source_manifest WHERE source_ref IN ('zero-missing-time','zero-infinite-cutoff');"),'0')

    def test_032_audit_review_principal(self):
        self.assertEqual(execute("SELECT actor FROM plaa.audit_log WHERE table_name='plaa.activity_submission' AND action='UPDATE' AND after->>'submission_id'='1' AND after->>'status'='accepted';"),'fixture-reviewer')
        self.assertEqual(execute("SELECT actor FROM plaa.audit_log WHERE table_name='ingest.identity_crosswalk' AND action='UPDATE' AND after->>'crosswalk_id'='1';"),'fixture-triage')

    def test_033_export_format_examples_without_release(self):
        rows=json.loads(Path('examples/export-preview.json').read_text())['rows']
        tables=set(execute("SELECT tablename FROM pg_tables WHERE schemaname='export' AND tablename<>'release_contract';").splitlines())
        self.assertEqual(set(rows),tables)
        for table,examples in rows.items():
            columns=set(execute(f"SELECT column_name FROM information_schema.columns WHERE table_schema='export' AND table_name='{table}';").splitlines())
            for row in examples:
                self.assertEqual(set(row),columns)
            payload=json.dumps(examples).replace("'","''")
            execute(f"BEGIN; CREATE TEMP TABLE preview(LIKE export.{table} INCLUDING CONSTRAINTS); INSERT INTO preview SELECT * FROM jsonb_populate_recordset(NULL::export.{table},'{payload}'::jsonb); ROLLBACK;",'plaa_owner')
            self.assertEqual(execute(f'SELECT count(*) FROM export.{table};','plaa_export_reader'),'0')


if __name__=='__main__':
    unittest.main(verbosity=2)

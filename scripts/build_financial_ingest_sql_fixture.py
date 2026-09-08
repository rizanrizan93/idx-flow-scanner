"""Generate offline PostgreSQL integration fixtures from immutable Gate 4 bytes."""
import json
import subprocess
from pathlib import Path

COMMIT = '2f2bdb4123c5f3c6d6a07bca3686f9893c768fab'
BASE = 'evidence_artifacts/financial_facts_v5/run-34225525473/'
URL = 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/'+COMMIT+'/'+BASE
SHA = 'f21574f2970c89d25dfc4ec18ec821c5acde1af40a94e949d6b2016f06dec681'


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def main():
    files = {name: subprocess.check_output(['git', 'show', COMMIT+':'+BASE+name]).decode() for name in
             ['manifest.json', 'artifact_meta.json', 'exclusions.json', 'shard-0025.json']}
    ids = set(json.loads(files['shard-0025.json'])['filing_ids'])
    ids.update(r['filing_id'] for r in json.loads(files['exclusions.json'])['rows'])
    parents = json.loads(Path('data/cache/evidence_v5/block_idx_historical_financial_filings.json').read_text())['rows']
    parents = [p for p in parents if p['filing_id'] in ids]
    columns = ['filing_id','ticker','report_year','report_period','report_period_end','published_at','file_modified_at',
               'file_url','file_name','file_type','report_type','source_key','content_hash','publication_time_verified',
               'source_verified','point_in_time_eligible','extraction_state','provenance_state']
    sql = ["grant usage on schema extensions to service_role;", "grant select on extensions.http_fixture to service_role;",
           "grant select, insert, update on public.flow_financial_filing_evidence_v5 to service_role;",
           "insert into public.flow_financial_filing_evidence_v5 ("+','.join(columns)+") select "+','.join(columns)+
           " from jsonb_populate_recordset(null::public.flow_financial_filing_evidence_v5,"+quote(json.dumps(parents))+"::jsonb);"]
    for name, raw in files.items():
        sql.append('insert into extensions.http_fixture values ('+quote(URL+name)+','+quote(raw)+');')
    sql.append("set role service_role;")
    sql.append("select public.flow_register_block_idx_financial_fact_manifest_v5("+quote(URL+'manifest.json')+','+quote(SHA)+');')
    sql.append("select public.flow_ingest_block_idx_financial_fact_shard_v5("+quote(SHA)+",25);")
    sql.append("do $$ declare r jsonb; begin r:=public.flow_ingest_block_idx_financial_fact_shard_v5("+quote(SHA)+",25); if r->>'status' <> 'ALREADY_COMPLETE' or (r->>'inserted_fact_rows')::integer <> 0 or r->>'actual_relational_sha256' is distinct from r->>'expected_relational_sha256' then raise exception 'IDEMPOTENCY_FAILED'; end if; end $$;")
    sql.append("reset role;")
    sql.append("do $$ begin if (select count(*) from public.flow_financial_fact_evidence_v5) <> 501 or (select count(*) from public.flow_financial_fact_manifest_exclusion_v5) <> 256 or (select count(*) from public.flow_financial_fact_manifest_filing_v5) <> 29 then raise exception 'COUNT_READBACK_FAILED'; end if; end $$;")
    # Roll back each deliberate mutation in a subtransaction after fail-closed validation.
    sql.append("""do $$ declare rejected boolean := false; begin
      begin
        update public.flow_financial_fact_evidence_v5 set metric_value=metric_value+1 where fact_id=(select min(fact_id) from public.flow_financial_fact_evidence_v5);
        begin
          perform public.flow_ingest_block_idx_financial_fact_shard_v5('"""+SHA+"""',25);
        exception when others then
          if SQLERRM not like 'FINANCIAL_FACT_SHARD_EXISTING_FACT_CONFLICT:%' then raise; end if;
          rejected := true;
        end;
        if not rejected then raise exception 'CONFLICT_NOT_REJECTED'; end if;
        raise exception using errcode='ZX001',message='ROLLBACK_EXPECTED_MUTATION';
      exception when sqlstate 'ZX001' then null;
      end;
    end $$;""")
    sql.append("do $$ begin if has_table_privilege('anon','public.flow_financial_fact_manifest_exclusion_v5','SELECT') or has_table_privilege('authenticated','public.flow_financial_fact_evidence_v5','INSERT') or has_function_privilege('anon','public.flow_register_block_idx_financial_fact_manifest_v5(text,text)','EXECUTE') or has_table_privilege('service_role','public.flow_financial_fact_manifest_exclusion_v5','DELETE') then raise exception 'ACL_FAILED'; end if; end $$;")
    sql.append("select 'REAL_ARTIFACT_REGISTRATION_INGEST_IDEMPOTENCY_CONFLICT_ACL_PASS' as result;")
    Path('/tmp/financial_ingest_fixture.sql').write_text('\n'.join(sql)+'\n')


if __name__ == '__main__':
    main()

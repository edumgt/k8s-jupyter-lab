-- Active workloads using ANSI SQL.
SELECT workload_name, owner_name, workload_status
FROM lab_workloads
WHERE workload_status <> 'STOPPED'
ORDER BY updated_at DESC;

-- Recent DAG durations.
SELECT dag_name, run_date, duration_seconds
FROM dag_runtime_summary
QUALIFY ROW_NUMBER() OVER (PARTITION BY dag_name ORDER BY run_date DESC) <= 5;

-- Notebook usage summary.
SELECT notebook_name, owner_name, execution_count
FROM notebook_usage
ORDER BY execution_count DESC;

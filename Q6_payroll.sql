-- =====================================================================
-- ICT371 Advanced Database  |  Question 6: Monthly Payroll Processing
-- DBMS: PostgreSQL 14+   |  Scheduler: pg_cron extension
-- gross = basic_salary + allowance ; net = gross - deduction
-- =====================================================================

-- (a) Database and seed data
DROP TABLE IF EXISTS salary_audit CASCADE;
DROP TABLE IF EXISTS payroll      CASCADE;
DROP TABLE IF EXISTS employees    CASCADE;

CREATE TABLE employees (
    employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_pay_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_employee_month  UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mwila',   8000.00, 1500.00, 1200.00, TRUE),
    ('Boniface Tonga',6000.00, 1000.00,  900.00, TRUE),
    ('Cecilia Nkole', 4500.00,  500.00,  600.00, TRUE),
    ('Daniel Kasonde',5200.00,  800.00,  700.00, TRUE),
    ('Evelyn Musonda',7000.00, 1200.00, 1000.00, TRUE);   -- will become inactive

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$;

-- (d) Trigger: log actual basic_salary changes
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_salary_audit ON employees;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (c) Procedure (query FOR loop over active employees)
-- A procedure runs inside the caller's transaction, so an exception raised by
-- fn_net_pay for any employee aborts the whole CALL (nothing is inserted).
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(rec.employee_id);   -- raises on invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- Two payroll months. Evelyn is paid in September, then becomes inactive.
CALL pr_process_payroll(DATE '2026-09-01');
UPDATE employees SET active = FALSE WHERE employee_id = 5;
CALL pr_process_payroll(DATE '2026-10-01');

-- Re-processing leaves existing rows unchanged (no new rows, no changes)
CALL pr_process_payroll(DATE '2026-10-01');

SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- Trigger demo: salary change is logged; a non-salary change is not
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;
UPDATE employees SET basic_salary = basic_salary, allowance = 1600 WHERE employee_id = 2;
SELECT * FROM salary_audit ORDER BY audit_id;   -- exactly 1 row

SELECT employee_id, fn_net_pay(employee_id) FROM employees ORDER BY 1;

-- Invalid calls (expected to fail)
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-15');   -- not a month start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
-- Negative net pay for one employee must fail the WHOLE call (all rolled back)
DO $$
BEGIN
    INSERT INTO employees (full_name, basic_salary, allowance, deduction)
    VALUES ('Test Negative', 1000, 0, 5000);
    CALL pr_process_payroll(DATE '2026-11-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;
SELECT COUNT(*) AS nov_rows_should_be_0 FROM payroll WHERE pay_month = DATE '2026-11-01';

-- (e) View: LEFT-safe because payroll rows are kept for later-inactive employees
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;   -- no filter on e.active

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- (f) Index
-- The existing UNIQUE (employee_id, pay_month) index leads with employee_id, so
-- it cannot efficiently serve "all employees for one month". This index leads
-- with pay_month (different column order, so it does not duplicate the unique
-- index) and INCLUDEs the report columns so the report can be an index-only scan.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month) INCLUDE (employee_id, gross_pay, net_pay);
ANALYZE payroll;

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on day 1 of each month, previous month's first date
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'payroll_monthly_process',
    '0 2 1 * *',
    $job$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$job$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'payroll_monthly_process';

-- Inspect run history (rows appear after the job has run)
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'payroll_monthly_process')
ORDER BY start_time DESC;

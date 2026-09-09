-- =====================================================================
-- LOAN ROOT CAUSE ANALYSIS (RCA) — FANNIE MAE MORTGAGE DATA
-- SQL script (MySQL Workbench)
-- =====================================================================
-- Sections:
--   1. Table creation: loans, borrowers, loan_monthly_status, default_events
--   2. Sanity checks / row counts
--   3. Segment default rate queries (FICO, LTV, combo, state)
--   4. Vintage / cohort analysis
--   5. Purpose, IFRS9 stage, DPD transitions, root cause, Shift-Share Decomposition by FICO Bucket
-- Rate effect vs. Mix effect vs. Portfolio Default Rate
-- =====================================================================
USE loan_rca_fnma;
-- data cleaning
CREATE TABLE clean_performance AS
SELECT *
FROM raw_performance;
--

ALTER TABLE clean_performance
DROP COLUMN net_loss,
DROP COLUMN zero_balance_code_raw;

-- rename for clarity: this field is Fannie Mae's delinquency status code
-- (months delinquent, e.g. 1 = 30 DPD, 2 = 60 DPD, 3 = 90 DPD), NOT literal days-past-due
ALTER TABLE clean_performance
CHANGE COLUMN current_dpd delinq_status_months INT;
-- rectifying dates
ALTER TABLE clean_performance
ADD COLUMN snapshot_month DATE;
UPDATE clean_performance
SET snapshot_month = STR_TO_DATE(
    CONCAT(
        RIGHT(CAST(reporting_period AS CHAR), 4),
        '-',
        LEFT(
            CAST(reporting_period AS CHAR),
            LENGTH(CAST(reporting_period AS CHAR)) - 4
        ),
        '-01'
    ),
    '%Y-%m-%d'
);

ALTER TABLE clean_performance
ADD COLUMN origination_month DATE;
UPDATE clean_performance
SET origination_month = STR_TO_DATE(
    CONCAT(
        RIGHT(CAST(origination_date AS CHAR), 4),
        '-',
        LEFT(
            CAST(origination_date AS CHAR),
            LENGTH(CAST(origination_date AS CHAR)) - 4
        ),
        '-01'
    ),
    '%Y-%m-%d'
);
-- 1. Table Creation
-- =====================================================================

-- 1a. loans: one row per unique loan
CREATE TABLE loans AS
SELECT DISTINCT
    loan_id,
    origination_date,origination_month,
    orig_upb                AS loan_amount,
    orig_interest_rate,
    orig_loan_term,
    orig_ltv                AS ltv_at_origination,
    CASE
        WHEN orig_ltv <= 60            THEN '<=60'
        WHEN orig_ltv <= 75            THEN '61-75'
        WHEN orig_ltv <= 80            THEN '76-80'
        WHEN orig_ltv <= 90            THEN '81-90'
        WHEN orig_ltv <= 97            THEN '91-97'
        ELSE '>97'
    END                     AS ltv_bucket,
    property_type,
    loan_purpose,
    channel                 AS origination_channel,
    property_state,
    first_time_buyer,
    num_borrowers
FROM clean_performance;

-- 1b. borrowers: FICO and DTI per loan
CREATE TABLE borrowers AS
SELECT DISTINCT
    loan_id,
    fico                    AS fico_at_origination,
    CASE
        WHEN fico < 620            THEN '<620'
        WHEN fico < 660            THEN '620-659'
        WHEN fico < 700            THEN '660-699'
        WHEN fico < 740            THEN '700-739'
        WHEN fico < 780            THEN '740-779'
        ELSE '780+'
    END                     AS fico_bucket,
    dti                     AS dti_ratio
FROM clean_performance;

-- 1c. loan_monthly_status: one row per loan per month
CREATE TABLE loan_monthly_status AS
SELECT
    CONCAT(loan_id, '_', reporting_period)  AS status_id,
    loan_id,
    reporting_period        AS snapshot_date,snapshot_month,
    delinq_status_months             AS dpd,
    CASE
        WHEN delinq_status_months = 0 OR delinq_status_months IS NULL THEN 'Current'
        WHEN delinq_status_months = 1                         THEN '30 DPD'
        WHEN delinq_status_months = 2                         THEN '60 DPD'
        WHEN delinq_status_months = 3                         THEN '90 DPD'
        ELSE '120+ DPD'
        END                     AS dpd_bucket,
    CASE
        WHEN delinq_status_months = 0 OR delinq_status_months IS NULL THEN 'Stage 1'
        WHEN delinq_status_months <= 2                        THEN 'Stage 2'
        ELSE 'Stage 3'
    END                     AS ifrs9_stage,
    current_upb             AS current_balance,
    current_rate
FROM clean_performance;

-- 1d. default_events: only Stage 3 loans
CREATE TABLE default_events AS
SELECT
    CONCAT(loan_id, '_', snapshot_month, '_default')  AS event_id,
    loan_id,
    snapshot_month     AS event_date,
    -- priority waterfall: a loan meeting more than one condition is tagged by
    -- whichever check comes first (DTI checked before LTV before purpose),
    -- so this reflects an assumed dominant driver, not mutually exclusive causes
    CASE
        WHEN dti > 45                           THEN 'High DTI'
        WHEN orig_ltv > 90                      THEN 'High LTV'
        WHEN loan_purpose = 'C'                 THEN 'Cash-Out Refi'
        ELSE 'Other / Unknown'
    END                     AS root_cause_tag,
    -- WHERE clause below already restricts this table to delinq_status_months >= 3,
    CASE
        WHEN delinq_status_months >= 6  THEN 'Severe'
        ELSE 'Moderate'
    END                     AS severity
FROM clean_performance
WHERE delinq_status_months >= 3;

-- 1e. Integrity check: confirm loan-level fields in `loans` and `borrowers`
-- are truly static per loan_id (SELECT DISTINCT above assumes this — if any
-- loan has inconsistent values across its monthly rows, it will show up here
-- as more than one row per loan_id)
SELECT loan_id, COUNT(*) AS row_count
FROM loans
GROUP BY loan_id
HAVING COUNT(*) > 1;

SELECT loan_id, COUNT(*) AS row_count
FROM borrowers
GROUP BY loan_id
HAVING COUNT(*) > 1;
SELECT 
    loan_id,
    snapshot_date,
    COUNT(*) AS row_count
FROM loan_monthly_status
GROUP BY loan_id, snapshot_date
HAVING COUNT(*) > 1;

-- 2. Sanity checks
SELECT COUNT(*) AS loans_count FROM loans;
SELECT COUNT(*) AS borrowers_count FROM borrowers;
SELECT COUNT(*) AS status_count FROM loan_monthly_status;
SELECT COUNT(*) AS default_count FROM default_events;

-- unique loans that ever defaulted
SELECT
    COUNT(DISTINCT loan_id)                          AS total_loans,
    COUNT(DISTINCT CASE WHEN delinq_status_months >= 3
          THEN loan_id END)                          AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN delinq_status_months >= 3
          THEN loan_id END) * 100.0 /
          COUNT(DISTINCT loan_id), 2)                AS default_rate_pct
FROM clean_performance;

-- 3. Segment default rate queries (FICO, LTV, combo, state)
-- 3a. Default rate by FICO bucket
SELECT
    b.fico_bucket,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM clean_performance r
JOIN borrowers b ON r.loan_id = b.loan_id
GROUP BY b.fico_bucket
ORDER BY default_rate_pct DESC;

-- 3b. Default rate by LTV bucket
SELECT
    l.ltv_bucket,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM clean_performance r
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY l.ltv_bucket
ORDER BY default_rate_pct DESC;

-- 3c. Combo: FICO bucket x LTV bucket (top 10)
SELECT
    b.fico_bucket,
    l.ltv_bucket,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM clean_performance r
JOIN borrowers b ON r.loan_id = b.loan_id
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY b.fico_bucket, l.ltv_bucket
ORDER BY default_rate_pct DESC
Limit 15; 

-- 3d. Default rate by property state (min 10 loans, top 15)
SELECT
    l.property_state,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM clean_performance r
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY l.property_state
HAVING total_loans >= 10
ORDER BY default_rate_pct DESC
LIMIT 15;

-- 4. Vintage / cohort analysis
-- 4a. Loans originated by raw origination_date
SELECT
    origination_month AS cohort_month,
    COUNT(DISTINCT loan_id) AS loans_originated
FROM loans
GROUP BY origination_month
ORDER BY origination_month;
-- 4b) Create MOB
CREATE TABLE loan_cohort_history AS
SELECT
    r.loan_id,
    l.origination_month AS cohort_month,
    r.snapshot_month,
    TIMESTAMPDIFF(
        MONTH,
        l.origination_month,
        r.snapshot_month
    ) AS mob,
    r.delinq_status_months,
    r.current_upb
FROM clean_performance r
JOIN loans l
ON r.loan_id = l.loan_id
WHERE r.snapshot_month >= l.origination_month;

-- 4c) Default rate for each vintage × MOB combination
SELECT
    cohort_month,
    mob,
    COUNT(DISTINCT loan_id) AS loans_at_mob,
    COUNT(DISTINCT CASE
        WHEN delinq_status_months >= 3 THEN loan_id
    END) AS defaulted_loans,
    ROUND(
        COUNT(DISTINCT CASE
            WHEN delinq_status_months >= 3 THEN loan_id
        END) * 100.0
        / COUNT(DISTINCT loan_id),
        2
    ) AS default_rate_pct
FROM loan_cohort_history 
WHERE mob BETWEEN 0 AND 36
GROUP BY
    cohort_month,
    mob
ORDER BY
    cohort_month,
    mob;
    
    -- 4d) Identify each loan's first default
CREATE TABLE loan_first_default AS
SELECT
    loan_id,
    cohort_month,
    MIN(mob) AS first_default_mob
FROM loan_cohort_history
WHERE delinq_status_months >= 3
  AND mob BETWEEN 0 AND 36
GROUP BY
    loan_id,
    cohort_month;
-- check it
SELECT *
FROM loan_first_default
ORDER BY cohort_month, first_default_mob;

-- 4e)
CREATE TABLE vintage_curve_data AS
WITH cohort_size AS (
    SELECT
        origination_month AS cohort_month,
        COUNT(DISTINCT loan_id) AS loans_originated
    FROM loans
    GROUP BY origination_month
),

mob_grid AS (
    SELECT DISTINCT
        cohort_month,
        mob
    FROM loan_cohort_history
    WHERE mob BETWEEN 0 AND 36
),

cumulative_defaults AS (
    SELECT
        g.cohort_month,
        g.mob,
        c.loans_originated,
        COUNT(DISTINCT f.loan_id) AS cumulative_defaulted_loans
    FROM mob_grid g
    JOIN cohort_size c
        ON g.cohort_month = c.cohort_month
    LEFT JOIN loan_first_default f
        ON g.cohort_month = f.cohort_month
       AND f.first_default_mob <= g.mob
    GROUP BY
        g.cohort_month,
        g.mob,
        c.loans_originated
)

SELECT
    cohort_month,
    mob,
    loans_originated,
    cumulative_defaulted_loans,
    ROUND(
        cumulative_defaulted_loans * 100.0
        / loans_originated,
        2
    ) AS cumulative_default_rate_pct
FROM cumulative_defaults
ORDER BY
    cohort_month,
    mob;
    
-- check it
SELECT *
FROM vintage_curve_data
WHERE mob BETWEEN 0 AND 36
ORDER BY cohort_month, mob;

-- 5. Purpose, IFRS9 stage, DPD transitions, root cause, FICO waterfall
-- 5a. Default rate by loan purpose
SELECT
    l.loan_purpose,
    CASE l.loan_purpose
        WHEN 'P' THEN 'Purchase'
        WHEN 'C' THEN 'Cash-Out Refi'
        WHEN 'N' THEN 'No Cash-Out Refi'
        ELSE 'Other'
    END                                                     AS purpose_label,
    COUNT(DISTINCT c.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN c.delinq_status_months >= 3
          THEN c.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN c.delinq_status_months >= 3
          THEN c.loan_id END) * 100.0 /
          COUNT(DISTINCT c.loan_id), 2)                     AS default_rate_pct
FROM clean_performance c
JOIN loans l ON c.loan_id = l.loan_id
GROUP BY l.loan_purpose
ORDER BY default_rate_pct DESC;

-- 5b) IFRS9 stage distribution
SELECT
    ifrs9_stage,
    COUNT(*)                                                AS record_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2)      AS pct_of_portfolio
FROM loan_monthly_status
GROUP BY ifrs9_stage
ORDER BY ifrs9_stage;

-- 5c. DPD transition matrix (top 15 transitions)
WITH dpd_changes AS (
    SELECT
        loan_id,
        snapshot_date,
        dpd,
        LAG(dpd) OVER (PARTITION BY loan_id ORDER BY snapshot_date) AS prev_dpd
    FROM loan_monthly_status
)
SELECT
    prev_dpd    AS from_dpd,
    dpd         AS to_dpd,
    COUNT(*)    AS transitions
FROM dpd_changes
WHERE prev_dpd IS NOT NULL
  AND (prev_dpd != dpd)
GROUP BY prev_dpd, dpd
ORDER BY transitions DESC;

-- 5d)  Root cause tag distribution among defaults
SELECT
    root_cause_tag,
    COUNT(DISTINCT loan_id)             AS defaulted_loans,
    ROUND(COUNT(DISTINCT loan_id) * 100.0 /
          SUM(COUNT(DISTINCT loan_id)) OVER(), 2) AS pct_of_defaults
FROM default_events
GROUP BY root_cause_tag
ORDER BY pct_of_defaults DESC;

-- 5e. Shift-Share Decomposition by FICO Bucket
-- Rate effect vs. Mix effect vs. Portfolio Default Rate
--
-- NOTE: this is a single-snapshot (cross-sectional) contribution analysis —
-- it decomposes today's portfolio default rate into how much each FICO
-- bucket over/under-contributes vs. an equal-weighted (1/6) benchmark mix.
-- It is NOT a period-over-period shift-share (which would decompose a CHANGE
-- in default rate between two dates into rate vs. mix effects). To get a
-- true shift-share, run this on two snapshot dates and compare.

WITH segment_stats AS (
    SELECT
        b.fico_bucket,
        COUNT(DISTINCT r.loan_id) AS segment_loans,
        COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3 THEN r.loan_id
        END) AS segment_defaults,
        ROUND(COUNT(DISTINCT CASE WHEN r.delinq_status_months >= 3 THEN r.loan_id END) * 100.0
            / COUNT(DISTINCT r.loan_id),4) AS segment_default_rate
    FROM clean_performance r
    JOIN borrowers b
        ON r.loan_id = b.loan_id
    GROUP BY b.fico_bucket
),

portfolio_totals AS (
    SELECT
        SUM(segment_loans) AS total_loans,
        SUM(segment_defaults) AS total_defaults,

        ROUND(
            SUM(segment_defaults) * 100.0
            / SUM(segment_loans),
            4
        ) AS portfolio_default_rate

    FROM segment_stats
)

SELECT
    s.fico_bucket,

    s.segment_loans,
    s.segment_defaults,
    s.segment_default_rate,

    p.portfolio_default_rate,

    -- Actual portfolio share of the FICO segment
    ROUND(s.segment_loans * 100.0 / p.total_loans,2) AS segment_mix_pct,
    -- RATE EFFECT
    -- Difference between segment default rate and
    -- portfolio default rate, weighted by actual segment mix
    ROUND(
        (s.segment_default_rate - p.portfolio_default_rate)
        * s.segment_loans / p.total_loans,
        4
    ) AS rate_effect,

    -- MIX EFFECT
    -- Difference between actual segment mix and
    -- equal reference mix (1/5), valued at portfolio default rate
    ROUND(
        p.portfolio_default_rate
        * (s.segment_loans / p.total_loans - 1.0 / 5.0),4) AS mix_effect

FROM segment_stats s
CROSS JOIN portfolio_totals p
ORDER BY s.fico_bucket;



-- =====================================================================
-- END OF SCRIPT
-- =====================================================================

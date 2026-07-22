-- =====================================================================
-- LOAN ROOT CAUSE ANALYSIS (RCA) — FANNIE MAE MORTGAGE DATA
-- Combined SQL script (MySQL Workbench)
-- =====================================================================
-- Sections:
--   1. Table creation: loans, borrowers, loan_monthly_status, default_events
--   2. Sanity checks / row counts
--   3. Segment default rate queries (FICO, LTV, combo, state)
--   4. Vintage / cohort analysis
--   5. Purpose, IFRS9 stage, DPD transitions, root cause, FICO waterfall
-- =====================================================================

USE loan_rca_fnma;

-- =====================================================================
-- 1. TABLE CREATION
-- =====================================================================

-- 1a. loans: one row per unique loan
CREATE TABLE loans AS
SELECT DISTINCT
    loan_id,
    origination_date,
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
    loan_type,
    channel                 AS origination_channel,
    property_state,
    first_time_buyer,
    num_borrowers
FROM raw_performance;

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
FROM raw_performance;

-- 1c. loan_monthly_status: one row per loan per month
CREATE TABLE loan_monthly_status AS
SELECT
    CONCAT(loan_id, '_', reporting_period)  AS status_id,
    loan_id,
    reporting_period        AS snapshot_date,
    current_dpd             AS dpd,
    CASE
        WHEN current_dpd = 0 OR current_dpd IS NULL THEN 'Current'
        WHEN current_dpd = 1                         THEN '30 DPD'
        WHEN current_dpd = 2                         THEN '60 DPD'
        WHEN current_dpd = 3                         THEN '90 DPD'
        ELSE '120+ DPD'
        END                     AS dpd_bucket,
    CASE
        WHEN current_dpd = 0 OR current_dpd IS NULL THEN 'Stage 1'
        WHEN current_dpd <= 2                        THEN 'Stage 2'
        ELSE 'Stage 3'
    END                     AS ifrs9_stage,
    current_upb             AS current_balance,
    current_rate,
    loan_age
FROM raw_performance;

-- 1d. default_events: only Stage 3 loans
CREATE TABLE default_events AS
SELECT
    CONCAT(loan_id, '_', reporting_period, '_default')  AS event_id,
    loan_id,
    reporting_period        AS event_date,
    CASE
        WHEN dti > 45                           THEN 'High DTI'
        WHEN orig_ltv > 90                      THEN 'High LTV'
        WHEN loan_purpose = 'C'                 THEN 'Cash-Out Refi'
        WHEN loan_type = 'ARM'                  THEN 'ARM Rate Shock'
        ELSE 'Other / Unknown'
    END                     AS root_cause_tag,
    CASE
        WHEN current_dpd >= 6  THEN 'Severe'
        WHEN current_dpd >= 3  THEN 'Moderate'
        ELSE 'Mild'
    END                     AS severity,
    net_loss,
    zero_balance_code
FROM raw_performance
WHERE current_dpd >= 3;


-- =====================================================================
-- 2. SANITY CHECKS / ROW COUNTS
-- =====================================================================

SELECT COUNT(*) AS loans_count FROM loans;
SELECT COUNT(*) AS borrowers_count FROM borrowers;
SELECT COUNT(*) AS status_count FROM loan_monthly_status;
SELECT COUNT(*) AS default_count FROM default_events;

-- unique loans that ever defaulted
SELECT
    COUNT(DISTINCT loan_id)                          AS total_loans,
    COUNT(DISTINCT CASE WHEN current_dpd >= 3
          THEN loan_id END)                          AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN current_dpd >= 3
          THEN loan_id END) * 100.0 /
          COUNT(DISTINCT loan_id), 2)                AS default_rate_pct
FROM raw_performance;


-- =====================================================================
-- 3. SEGMENT DEFAULT RATE QUERIES
-- =====================================================================

-- 3a. Default rate by FICO bucket
SELECT
    b.fico_bucket,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM raw_performance r
JOIN borrowers b ON r.loan_id = b.loan_id
GROUP BY b.fico_bucket
ORDER BY default_rate_pct DESC;

-- 3b. Default rate by LTV bucket
SELECT
    l.ltv_bucket,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM raw_performance r
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY l.ltv_bucket
ORDER BY default_rate_pct DESC;

-- 3c. Combo: FICO bucket x LTV bucket (top 10)
SELECT
    b.fico_bucket,
    l.ltv_bucket,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM raw_performance r
JOIN borrowers b ON r.loan_id = b.loan_id
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY b.fico_bucket, l.ltv_bucket
ORDER BY default_rate_pct DESC
LIMIT 10;

-- 3d. Default rate by property state (min 10 loans, top 15)
SELECT
    l.property_state,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM raw_performance r
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY l.property_state
HAVING total_loans >= 10
ORDER BY default_rate_pct DESC
LIMIT 15;


-- =====================================================================
-- 4. VINTAGE / COHORT ANALYSIS
-- =====================================================================

-- 4a. Loans originated by raw origination_date
SELECT
    origination_date,
    COUNT(DISTINCT loan_id) AS loans_originated
FROM loans
GROUP BY origination_date
ORDER BY origination_date;

-- 4b. Build proper cohort date columns
ALTER TABLE loans ADD COLUMN orig_month INT, ADD COLUMN orig_year INT, ADD COLUMN orig_cohort DATE;

UPDATE loans
SET
  orig_year = CAST(RIGHT(origination_date, 4) AS UNSIGNED),
  orig_month = CAST(LEFT(origination_date, LENGTH(origination_date) - 4) AS UNSIGNED);

UPDATE loans
SET orig_cohort = STR_TO_DATE(CONCAT(orig_year, '-', LPAD(orig_month, 2, '0'), '-01'), '%Y-%m-%d');

-- 4c. Cohort sizing
SELECT orig_cohort, COUNT(*) AS loans_originated
FROM loans
GROUP BY orig_cohort
ORDER BY orig_cohort;

SELECT DISTINCT dpd_bucket FROM loan_monthly_status;

-- 4d. Full vintage curve: cumulative default rate by cohort x months-on-book
WITH cohort_sizes AS (
    SELECT
        orig_cohort,
        COUNT(DISTINCT loan_id) AS loans_originated
    FROM loans
    GROUP BY orig_cohort
    HAVING COUNT(DISTINCT loan_id) >= 100
),

vintage_curve AS (
    SELECT
        l.orig_cohort,
        TIMESTAMPDIFF(
            MONTH,
            l.orig_cohort,
            STR_TO_DATE(
                CONCAT(
                    RIGHT(lms.snapshot_date, 4), '-',
                    LPAD(LEFT(lms.snapshot_date, LENGTH(lms.snapshot_date) - 4), 2, '0'),
                    '-01'
                ),
                '%Y-%m-%d'
            )
        ) AS months_on_book,
        COUNT(DISTINCT lms.loan_id) AS active_loans,
        SUM(CASE WHEN lms.dpd_bucket IN ('90 DPD', '120+ DPD') THEN 1 ELSE 0 END) AS period_defaults
    FROM loans l
    JOIN loan_monthly_status lms ON lms.loan_id = l.loan_id
    JOIN cohort_sizes cs ON cs.orig_cohort = l.orig_cohort
    GROUP BY l.orig_cohort, months_on_book
)

SELECT
    v.orig_cohort,
    v.months_on_book,
    v.active_loans,
    v.period_defaults,
    cs.loans_originated,
    SUM(v.period_defaults) OVER (
        PARTITION BY v.orig_cohort ORDER BY v.months_on_book
    ) AS running_defaults,
    ROUND(
        SUM(v.period_defaults) OVER (PARTITION BY v.orig_cohort ORDER BY v.months_on_book)
        / cs.loans_originated * 100, 2
    ) AS cumulative_default_rate_pct
FROM vintage_curve v
JOIN cohort_sizes cs ON cs.orig_cohort = v.orig_cohort
WHERE v.months_on_book IS NOT NULL AND v.months_on_book >= 0
ORDER BY v.orig_cohort, v.months_on_book;


-- =====================================================================
-- 5. PURPOSE / IFRS9 / DPD TRANSITIONS / ROOT CAUSE / FICO WATERFALL
-- =====================================================================

-- 5a. Default rate by loan purpose
SELECT
    l.loan_purpose,
    CASE l.loan_purpose
        WHEN 'P' THEN 'Purchase'
        WHEN 'C' THEN 'Cash-Out Refi'
        WHEN 'N' THEN 'No Cash-Out Refi'
        ELSE 'Other'
    END                                                     AS purpose_label,
    COUNT(DISTINCT r.loan_id)                               AS total_loans,
    COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END)                               AS defaulted_loans,
    ROUND(COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
          THEN r.loan_id END) * 100.0 /
          COUNT(DISTINCT r.loan_id), 2)                     AS default_rate_pct
FROM raw_performance r
JOIN loans l ON r.loan_id = l.loan_id
GROUP BY l.loan_purpose
ORDER BY default_rate_pct DESC;

-- 5b. IFRS9 stage distribution
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
ORDER BY transitions DESC
LIMIT 15;

-- 5d. Root cause tag distribution among defaults
SELECT
    root_cause_tag,
    COUNT(DISTINCT loan_id)             AS defaulted_loans,
    ROUND(COUNT(DISTINCT loan_id) * 100.0 /
          SUM(COUNT(DISTINCT loan_id)) OVER(), 2) AS pct_of_defaults
FROM default_events
GROUP BY root_cause_tag
ORDER BY defaulted_loans DESC;

-- 5e. FICO segment waterfall: rate effect vs. mix effect vs. portfolio default rate
WITH segment_stats AS (
    SELECT
        b.fico_bucket,
        COUNT(DISTINCT r.loan_id)                               AS segment_loans,
        COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
              THEN r.loan_id END)                               AS segment_defaults,
        ROUND(COUNT(DISTINCT CASE WHEN r.current_dpd >= 3
              THEN r.loan_id END) * 100.0 /
              COUNT(DISTINCT r.loan_id), 4)                     AS segment_default_rate
    FROM raw_performance r
    JOIN borrowers b ON r.loan_id = b.loan_id
    GROUP BY b.fico_bucket
),
portfolio_totals AS (
    SELECT
        SUM(segment_loans)      AS total_loans,
        SUM(segment_defaults)   AS total_defaults,
        ROUND(SUM(segment_defaults) * 100.0 / SUM(segment_loans), 4) AS portfolio_default_rate
    FROM segment_stats
)
SELECT
    s.fico_bucket,
    s.segment_loans,
    s.segment_default_rate,
    p.portfolio_default_rate,
    ROUND(s.segment_loans * 100.0 / p.total_loans, 2)          AS segment_mix_pct,
    ROUND((s.segment_default_rate - p.portfolio_default_rate)
          * s.segment_loans / p.total_loans, 4)                 AS rate_effect,
    ROUND(p.portfolio_default_rate
          * (s.segment_loans - p.total_loans / 5.0)
          / p.total_loans, 4)                                   AS mix_effect
FROM segment_stats s
CROSS JOIN portfolio_totals p
ORDER BY rate_effect DESC;

-- =====================================================================
-- END OF SCRIPT
-- =====================================================================

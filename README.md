# mortgage-default-rca
Mortgage Loan Default — Root Cause Analysis
Tools: MySQL (Workbench) · Python (standard library + Google Colab) · Power BI  
Data: Fannie Mae Single-Family Loan Performance Data, 2020Q1  
Domain: Credit Risk · Mortgage Analytics · IFRS 9
---
Project Overview
This project investigates the root causes of mortgage loan defaults using Fannie Mae's publicly available loan performance data. The analysis covers borrower credit quality, collateral risk, portfolio composition, delinquency migration, regulatory staging, and vintage performance — structured to reflect the kind of multi-dimensional credit risk analysis performed in banking and risk management teams.
The end deliverable is a two-page Power BI dashboard backed by 10 analytical SQL queries, designed to demonstrate end-to-end data skills for credit risk and data analyst roles.
---
Data Preparation
Fannie Mae Single-Family Loan Performance data (2020Q1) was sourced as a ~8GB pipe-delimited flat file with no column headers. An initial load of 100,000 sequential rows was attempted but discarded — all loans clustered around Dec 2019/Jan 2020 originations, making cohort and vintage analysis meaningless due to the lack of vintage spread.
To correct this, a reservoir sampling script using only Python standard library modules (`random`, `csv`, `pathlib`) was run locally — avoiding third-party DLL restrictions on the corporate machine — to draw 150,000 random rows across the full file. This produced `2020Q1_random.csv`, which was uploaded to Google Colab where pandas mapped 25 columns by position and engineered the following derived variables:
FICO bucket — credit score bands (620–659, 660–699, 700–739, 740–779, 780+)
LTV bucket — loan-to-value bands (≤60, 61–75, 76–80, 81–90, 91–97)
DPD bucket — delinquency severity (Current, 30 DPD, 60 DPD, 90 DPD, 120+ DPD)
IFRS 9 stage — regulatory classification (Stage 1: current; Stage 2: 30+ DPD; Stage 3: 90+ DPD)
Root cause tag — heuristic classification of defaults by primary driver (High LTV, High DTI, Cash-Out Refi, Other/Unknown)
A `.sql` dump was generated and imported into MySQL via batched INSERT statements. All subsequent SQL analysis and Power BI visuals are based on this sample.
---
Database Schema
Database: `loan_rca_fnma`
Table	Description
`raw_performance`	Staging table — all 25 columns as VARCHAR, one row per monthly loan snapshot
`loans`	One row per loan — origination details: LTV, loan purpose, property type, state, origination date
`borrowers`	One row per loan — FICO bucket, DTI
`loan_monthly_status`	One row per loan per month — DPD, DPD bucket, IFRS 9 stage
`default_events`	Only loans that reached 90+ DPD — with root cause tag and severity
---
Analysis — SQL Queries
Query 1 — Default Rate by FICO Bucket
Measures default rate across five credit score bands. Clear inverse relationship observed: borrowers in the 620–659 band default at 5.05%, versus 0.51% for 780+ borrowers — a 10× difference in credit risk across the FICO spectrum.
Query 2 — Default Rate by LTV Bucket
Measures default rate by loan-to-value ratio. Higher LTV consistently predicts higher default: 91–97 LTV loans default at 2.27%, compared to 0.78% for ≤60 LTV loans. Collateral cushion is a meaningful risk differentiator even within a performing portfolio.
Query 3 — Default Rate by FICO × LTV (Combined Segmentation)
Two-dimensional risk matrix crossing FICO and LTV buckets. Identifies the highest-risk segment as low FICO + high LTV — confirming that risk factors compound multiplicatively rather than additively.
Query 4 — Default Rate by State
Geographic distribution of defaults. Virgin Islands (VI), Nevada (NV), and Hawaii (HI) show elevated rates, though small loan counts in some states limit statistical reliability. California, New York, and Florida show moderate but meaningful default rates given their portfolio size.
Query 5 — Default Rate by Loan Purpose
Counterintuitive finding: Purchase loans defaulted at a higher rate than Cash-Out Refinance loans in this sample. This challenges the conventional assumption that cash-out refis are riskier, and likely reflects the higher LTV and lower seasoning of purchase loans in the observation window.
Query 6 — IFRS 9 Stage Distribution
Portfolio-level regulatory staging snapshot: 96.66% Stage 1 (performing), 1.52% Stage 2 (watchlist), 1.81% Stage 3 (credit-impaired). The Stage 2 / Stage 3 ratio of approximately 1:1.2 is worth monitoring — a healthy portfolio typically sees Stage 2 as a meaningful early-warning buffer ahead of Stage 3.
Query 7 — DPD Migration Analysis (LAG Window Function)
Month-over-month transition tracking using `LAG()` to identify loans moving between delinquency states. Captures cure rates (loans returning to Current), deterioration paths (30→60→90+ DPD), and re-default patterns. This is the closest equivalent to a transition matrix in SQL.
Query 8 — Root Cause Breakdown
Heuristic classification of defaulted loans by primary driver:
High LTV: 34.53%
High DTI: 23.02%
Cash-Out Refi: 21.32%
Other / Unknown: 21.14%
Collateral over-leverage (High LTV) is the single largest identified driver, consistent with the LTV analysis in Query 2.
Query 9 — Shift-Share Decomposition by FICO Bucket
Separates each FICO bucket's contribution to portfolio default rate into two components:
Rate effect — contribution from that segment's own default rate being above/below portfolio average
Mix effect — contribution from that segment's share of the total portfolio
Key finding: the 700–739 FICO bucket is the largest portfolio risk driver not because it has the worst credit quality, but because it represents the largest share of the portfolio (19.79%). The 780+ bucket, despite excellent credit quality (negative rate effect), contributes positively to portfolio risk purely through its 36.86% portfolio weight.
Query 10 — Vintage / Cohort Analysis
Cumulative default rate by months-on-book, segmented by origination cohort (monthly vintages from Aug 2019 to Mar 2020, filtered to cohorts with ≥100 loans originated). Key findings:
November 2019 vintage has the highest observed cumulative default rate (1.86% at ~75 months seasoning)
All cohorts follow the expected convex curve — defaults front-loaded in early seasoning, gradually flattening
2020 cohorts appear lower due to shorter observation window (censoring), not better credit quality — a methodological caveat noted in the analysis
---
Key Findings Summary
Dimension	Finding
Credit Quality	620–659 FICO borrowers default at 10× the rate of 780+ borrowers
Collateral	91–97 LTV loans carry nearly 3× the default rate of ≤60 LTV loans
Loan Purpose	Purchase loans outdefault Cash-Out Refis — counterintuitive, driven by higher LTV at origination
Root Cause	High LTV is the primary identifiable default driver (34.5% of defaults)
Portfolio Composition	700–739 FICO is the biggest risk driver by portfolio weight, not credit quality
Regulatory Staging	96.7% Stage 1; Stage 2/3 ratio suggests limited early-warning buffer
Vintage Performance	Nov 2019 cohort worst performing; all cohorts show classic front-loaded default curves
---
Dashboard (Power BI)
Page 1 — Main Dashboard
Default Rate by FICO Bucket (bar chart)
Default Rate by LTV Bucket (bar chart)
Default Rate by State (bar chart)
Default Root Cause Breakdown (donut chart)
IFRS 9 Stage Distribution (bar chart)
Shift-Share Decomposition by FICO Bucket (clustered bar — rate effect vs mix effect)
Page 2 — Vintage Analysis
Cumulative Default Rate by Vintage Cohort (line chart — 8 cohort lines, months-on-book on X-axis)
---
Limitations & Caveats
Sample size: 150,000 rows from a single quarterly file. Findings are directionally valid but not statistically extrapolable to the full Fannie Mae universe.
Observation window: All data comes from a single performance file snapshot. Later-vintage cohorts (2020) have fewer months of observed performance and will understate true lifetime default rates.
Root cause heuristics: Root cause tags are rule-based approximations, not model-derived. A loan tagged "High LTV" may have defaulted for unrelated reasons.
Geographic thin cells: Several states (VI, HI, NV) show high default rates but have small loan counts — interpret with caution.
---
Repository Structure
```
├── data_prep/
│   └── reservoir_sample.py       # Standard-library reservoir sampling script
├── sql/
│   ├── 01_schema.sql             # Table creation
│   ├── 02_transform.sql          # Raw → loans/borrowers/loan_monthly_status/default_events
│   ├── 03_analysis_queries.sql   # All 10 analytical queries
├── exports/                      # CSV exports used in Power BI
├── dashboard/
│   └── loan_default_rca.pbix     # Power BI dashboard file
└── README.md
```
---
Data source: Fannie Mae Single-Family Loan Performance Data (publicly available). This project is for portfolio and educational purposes only.

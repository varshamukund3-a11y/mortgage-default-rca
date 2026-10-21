Mortgage Loan Default: Root Cause Analysis

Tools: MySQL · Python (standard library + pandas on Google Colab) · Power BI Data: Fannie Mae Single-Family Loan Performance Data, 2020Q1 acquisition cohort Domain: Credit risk · Mortgage analytics · IFRS 9


What this project does

This project asks one question: what drives mortgage loans to default?

I sampled about 150,000 loans from Fannie Mae's public loan performance data, loaded them into MySQL, and wrote SQL queries to compare default rates across credit score, loan-to-value (LTV), state, and other loan features. I also tracked how delinquency moves from month to month, classified loans into IFRS 9 stages, compared origination cohorts by loan age, and split each credit score band's risk contribution using shift-share decomposition. The results are shown in a two-page Power BI dashboard.

A loan is treated as defaulted when it reaches 90 or more days past due (DPD).

Key findings
Credit score is the strongest driver of default. The default rate is 5.05% for the 620–659 band and 0.51% for the 780+ band, a gap of about 10×.
LTV matters too, but less. The default rate rises from 0.75% (LTV ≤60) to 2.29% (LTV 91–97), about 3×.
Low credit score and high leverage compound. The worst combination (FICO 620–659, LTV 81–90) defaults at 7.28%, higher than either factor alone.
Shift-share suggests the credit score gap is a real difference in borrower risk, not just a result of portfolio mix. See the caveats on the lower-risk bands in section 4.
The book is mostly performing. 97.74% of records are IFRS 9 Stage 1.
About a third of defaults could not be explained by simple underwriting variables (34.53% tagged "Other / Unknown"). Events like job loss are not in origination data.
Later cohorts look better, partly because they have had less time to default. Cohorts should be compared at the same loan age.
Data preparation
The source is a very large (~8 GB) pipe-delimited file with no column headers.
An initial load of the first 100,000 rows was discarded because the loans were clustered around Dec 2019/Jan 2020, which made cohort analysis meaningless.
I replaced it with reservoir sampling (Python standard library only: random, csv, pathlib) to draw about 150,000 rows at random so every row has an equal chance of selection.
In Google Colab, pandas mapped the 25 columns by position and created these derived fields:
FICO bucket: 620–659, 660–699, 700–739, 740–779, 780+
LTV bucket: ≤60, 61–75, 76–80, 81–90, 91–97
DPD bucket: Current, 30, 60, 90, 120+
IFRS 9 stage: Stage 1 (current), Stage 2 (30+ DPD), Stage 3 (90+ DPD)
Root cause tag: a rule-based label for defaulted loans (High LTV, High DTI, Cash-Out Refi, Other / Unknown)
A SQL dump of batched INSERT statements was imported into MySQL.

The segmentation tables below cover 128,582 loans that fall in the five FICO bands and have an LTV bucket. The portfolio default rate is 1.32%.

Database schema

Database: loan_rca_fnma

Table	Description
raw_performance	Staging table. All 25 columns as text, one row per monthly loan snapshot
loans	One row per loan: LTV, loan purpose, property type, state, origination date
borrowers	One row per loan: FICO bucket, DTI
loan_monthly_status	One row per loan per month: DPD, DPD bucket, IFRS 9 stage
default_events	Loans that reached 90+ DPD, with root cause tag and severity
Analysis and results
1. Default rate by FICO band
FICO band	Loans	Defaults	Default rate
620–659	3,701	187	5.05%
660–699	11,718	350	2.99%
700–739	25,440	488	1.92%
740–779	40,333	438	1.09%
780+	47,390	240	0.51%
2. Default rate by LTV band
LTV band	Loans	Defaults	Default rate
≤60	30,976	231	0.75%
61–75	35,180	406	1.15%
76–80	27,633	368	1.33%
81–90	14,709	239	1.62%
91–97	20,085	459	2.29%
3. FICO × LTV: highest-risk segments
FICO band	LTV band	Loans	Defaults	Default rate
620–659	81–90	302	22	7.28%
620–659	91–97	404	29	7.18%
660–699	91–97	2,044	108	5.28%
620–659	61–75	1,078	56	5.19%
620–659	76–80	744	33	4.44%

Some of these segments are small, so a few defaults can move the rate noticeably.

4. Shift-share decomposition by FICO band

Shift-share answers: does a band look risky because its borrowers default more, or just because it is a large part of the portfolio?

Rate effect = (segment default rate − portfolio default rate) × segment share of portfolio
Mix effect = (segment share − equal-weight share of 20%) × portfolio default rate
Net = rate effect + mix effect

This is a cross-sectional decomposition (across bands at one point in time) with an equal-weight benchmark, not a comparison across two time periods. Effects are in percentage points, and each effect column sums to zero because both are measured against a benchmark.

FICO band	Segment rate	Portfolio rate	Segment mix	Rate effect	Mix effect	Net
620–659	5.05%	1.32%	2.88%	+0.107	−0.227	−0.120
660–699	2.99%	1.32%	9.11%	+0.152	−0.144	+0.008
700–739	1.92%	1.32%	19.79%	+0.118	−0.003	+0.115
740–779	1.09%	1.32%	31.37%	−0.075	+0.151	+0.076
780+	0.51%	1.32%	36.86%	−0.302	+0.223	−0.079

How to read it:

620–659 and 660–699 have clearly positive rate effects, so these are genuinely higher-risk borrowers. The 620–659 band has a negative net because it is only 2.9% of the portfolio.
700–739 has the largest net, mainly because its default rate is above average and it makes up nearly 20% of loans. It accounts for about 29% of all defaults.
780+ has the lowest default rate by a wide margin. Its large share offsets part of that advantage but not all of it.
5. IFRS 9 staging
Stage	Records	Share
Stage 1 (performing)	146,603	97.74%
Stage 2 (significant increase in credit risk)	1,617	1.08%
Stage 3 (credit-impaired)	1,780	1.19%
6. Root cause tagging of defaults

Tags are rule-based approximations, not model output. Each defaulted loan gets one tag.

Root cause	Defaults	Share
Other / Unknown	588	34.53%
High DTI	392	23.02%
Cash-Out Refi	363	21.32%
High LTV	360	21.14%
7. Default rate by state (selected)
State	Loans	Defaults	Default rate
NV	2,111	56	2.65%
HI	513	12	2.34%
NJ	3,387	73	2.16%
FL	9,053	171	1.89%
CA	16,433	301	1.83%
NY	4,607	84	1.82%

The Virgin Islands show 9.09% but are based on only 11 loans, so they are excluded from conclusions.

8. Vintage (cohort) analysis

Loans are grouped by origination month and compared by months on book (MOB), so a loan that is 12 months old is compared with other 12-month-old loans regardless of calendar date. Cohorts with fewer than 500 loans were excluded because one default can swing a small cohort's rate by several percentage points.

Cohort	Cumulative default rate at MOB 36 (approx.)
2019-09	0.35%
2019-10	1.43%
2019-11	1.58%
2019-12	1.30%
2020-01	0.93%
2020-02	0.61%
2020-03	0.61%

Later cohorts look better, but part of that is seasoning: they have been observed for fewer months. The 2019-09 to 2019-12 cohorts are the most directly comparable, and they still show a modest improvement into late 2019.

9. Delinquency migration (DPD)

I used LAG() window functions to compare each loan's DPD bucket with the previous month. The observed movement was mostly short-lived early delinquency (Current → 1–29 DPD → Current), with almost no loans moving into deeper buckets. This comes from the data, not a short observation window: loans are tracked monthly over a long history. A single acquisition quarter of a mostly low-risk portfolio produces few delinquency events. I treat this section as directional only.

Dashboard
Page 1, Main dashboard: default rate by FICO, LTV and state; root cause breakdown (donut); IFRS 9 stage distribution; shift-share rate vs mix effect.
Page 2, Vintage analysis: cumulative default rate by cohort against months on book.
Limitations
One acquisition quarter. All loans were acquired by Fannie Mae in Jan–Mar 2020 and the sample is about 150,000 rows. Results are directional and should not be extended to the full Fannie Mae book.
Association, not proof of cause. The analysis shows which characteristics go with higher default rates. It does not prove that any single factor causes default.
Root cause tags are rule-based. A loan tagged "High LTV" may have defaulted for another reason, and a loan with several risk factors gets only one tag.
Shift-share uses an equal-weight (20%) benchmark. A different benchmark, such as a prior-period portfolio mix, would change the mix effects.
Small segments. Some FICO × LTV cells and states have few loans, so their rates are noisy.
Censoring in vintages. Newer cohorts have had less time to default.
Limited delinquency depth. See section 9.
Repository contents
├── README.md
├── LICENSE
├── loan_default_rca_v2.sql      # Schema, transforms and the analytical queries
└── SQL loan default.pbix        # Two-page Power BI dashboard
How to reproduce
Download the Fannie Mae Single-Family Loan Performance Data for 2020Q1 (free registration with Fannie Mae is required).
Draw a random sample with reservoir sampling and save it as a CSV.
Map the columns and create the derived buckets with pandas, then generate the SQL INSERT dump.
Import into MySQL and run loan_default_rca_v2.sql.
Open the .pbix file in Power BI Desktop and refresh from the exported tables.
Data source and licence

Data: Fannie Mae Single-Family Loan Performance Data (publicly available). This project is for portfolio and educational purposes only. Code is released under the MIT licence.

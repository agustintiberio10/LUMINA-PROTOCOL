# LUMINA Protocol V5.0 — Dashboards

## Overview

Six dashboard sections provide comprehensive protocol visibility. Each section targets a specific operational concern and includes recommended metrics, refresh rates, and visualization types.

---

## 1. Protocol Health Dashboard

**Purpose**: At-a-glance system status for daily operations.

**Refresh Rate**: Real-time (every 60 seconds)

### Metrics

| Metric | Source | Visualization | Alert Threshold |
|--------|--------|---------------|-----------------|
| CoverRouter status (active/paused) | Contract state | Status indicator (green/red) | Red = page |
| SolvencyOracle status (active/paused) | Contract state | Status indicator (green/red) | Red = page |
| SolvencyOracle last update time | Contract state | Time since last update | >2h = warning |
| Chainlink feed freshness | Chainlink contract | Time since last answer | >2h = warning |
| Chainlink Automation last execution | Automation logs | Time since last run | >2h = warning |
| Coverage ratio (current) | SolvencyOracle | Gauge (0-200%) | <50% = critical |
| LINK balance (automation) | LINK token | Number | <5 LINK = warning |
| System uptime (30d rolling) | Computed | Percentage | <99% = review |

### Layout

- Top row: 4 status indicators (CoverRouter, SolvencyOracle, Chainlink Feed, Automation)
- Middle: Large coverage ratio gauge
- Bottom: Timeline of system events (pauses, parameter changes, incidents)

---

## 2. Financial Dashboard

**Purpose**: Treasury health, revenue tracking, and runway analysis.

**Refresh Rate**: Every 15 minutes

### Metrics

| Metric | Source | Visualization | Alert Threshold |
|--------|--------|---------------|-----------------|
| Treasury total balance (USDC) | TreasuryManager | Large number | <$100k = warning |
| BondVault balance (USDC) | BondVault contract | Large number with trend | <30% obligations = warning |
| Total outstanding bond obligations | Computed from active bonds | Number | N/A |
| Coverage ratio (vault/obligations) | Computed | Percentage with trend | <50% = critical |
| Daily buyback amount (configured) | TWAPBurner | Number | N/A |
| Total LUMINA burned (all-time) | Burn address balance | Number with cumulative chart | N/A |
| LUMINA burned (last 7 days) | Events | Bar chart (daily) | N/A |
| Weekly treasury inflow | Events | Line chart | Declining trend = info |
| Weekly treasury outflow | Events | Line chart (stacked by category) | Exceeds inflow = warning |
| Runway at current burn rate | Computed | Number (months) | <6 months = warning |
| CEX allocation (monthly) | Events | Bar chart | Near limit = info |
| Maintenance spend (monthly) | Events | Bar chart vs. budget | >80% budget = info |

### Layout

- Top row: Key numbers (treasury balance, vault balance, coverage ratio, runway)
- Middle left: Revenue/expense line chart (30-day trend)
- Middle right: Buyback performance chart (amount burned vs. cost)
- Bottom: Spending breakdown by category (pie chart, monthly)

---

## 3. Activity Dashboard

**Purpose**: User engagement and protocol utilization metrics.

**Refresh Rate**: Every 5 minutes

### Metrics

| Metric | Source | Visualization | Alert Threshold |
|--------|--------|---------------|-----------------|
| Bonds created (today) | BondCreated events | Number with sparkline | 0 for 3 days = info |
| Bonds created (7-day / 30-day) | Events | Line chart | Declining trend = info |
| Average bond size (USDC) | Events | Number with trend | N/A |
| Total bonds active | Contract state | Number | N/A |
| Bonds triggered (today / 7-day) | BondTriggered events | Number with chart | >10/hour = warning |
| Bonds expired (today / 7-day) | BondExpired events | Number | N/A |
| Claims processed (today / 7-day) | ClaimProcessed events | Number with chart | N/A |
| Unique users (7-day / 30-day) | Unique addresses | Number | N/A |
| New users (7-day) | First-time interactors | Number with trend | N/A |
| Total value bonded (all-time) | Cumulative events | Large number | N/A |
| Average bond duration | Computed | Number (days) | N/A |
| Bond maturity distribution | Active bonds | Histogram | N/A |

### Layout

- Top row: Today's activity (bonds created, triggered, claimed)
- Middle: 30-day activity timeline (stacked area: created, triggered, expired)
- Bottom left: User growth chart
- Bottom right: Bond size distribution histogram

---

## 4. Risk Indicators Dashboard

**Purpose**: Early warning system for potential issues.

**Refresh Rate**: Every 5 minutes

### Metrics

| Metric | Source | Visualization | Alert Threshold |
|--------|--------|---------------|-----------------|
| LUMINA/USD price | Chainlink + DEX | Line chart with threshold lines | <$0.005 = critical |
| LUMINA price 24h change | Computed | Percentage (color-coded) | >-20% = warning |
| LUMINA liquidity depth (±10%) | DEX pool | Number (USDC) | <$50k = warning |
| Coverage ratio trend (7-day) | Computed | Trend line with projection | Crossing 50% = critical |
| Trigger probability (next 7 days) | Model estimate | Percentage gauge | >50% = warning |
| Concentration risk (top 5 bonds as % of vault) | Computed | Percentage | >60% = warning |
| Oracle deviation (Chainlink vs. DEX spot) | Computed | Percentage | >5% = warning |
| Pending claims as % of vault | Computed | Percentage | >50% = critical |
| Time to next large bond maturity | Active bonds | Countdown | <7 days = info |
| Flash loan activity near protocol | Forta | Event count (24h) | Any = info |
| Unusual gas patterns on contracts | Tenderly | Anomaly score | High = warning |

### Layout

- Top: LUMINA price chart with critical threshold line ($0.005) and warning ($0.01)
- Middle left: Risk heatmap (coverage, concentration, liquidity, oracle health)
- Middle right: Trigger probability gauge with 7-day trend
- Bottom: Event feed of risk-relevant occurrences

---

## 5. User-Specific Dashboard (Public)

**Purpose**: Individual bond holder can view their positions and protocol status.

**Refresh Rate**: Real-time

### Metrics (Per-User)

| Metric | Source | Visualization |
|--------|--------|---------------|
| Active bonds (count and total value) | User's bonds | Summary cards |
| Each bond: status, maturity date, trigger condition, current value | Bond details | Table/cards |
| Claimable amount (if any triggered) | Contract state | Highlighted number |
| Historical bonds (completed/expired/triggered) | Events | History table |
| Personal P&L (premiums paid vs. claims received) | Computed | Summary |

### Protocol Status (Visible to Users)

| Metric | Source | Visualization |
|--------|--------|---------------|
| Protocol status (active/paused) | Contract state | Status badge |
| Current coverage ratio | SolvencyOracle | Simple gauge |
| LUMINA price | Chainlink | Number |
| Total bonds active (protocol-wide) | Contract state | Number |
| Recent protocol activity | Events | Feed |

### Layout

- Top: Protocol status bar (green = healthy, yellow = caution, red = paused)
- Main area: User's bonds with status and actions
- Sidebar: Protocol health summary
- Bottom: Transaction history

---

## 6. Operational Dashboard (Internal)

**Purpose**: Team-only view for operational efficiency tracking.

**Refresh Rate**: Hourly

### Metrics

| Metric | Source | Visualization |
|--------|--------|---------------|
| Multisig transaction queue | Safe API | Pending list |
| Average multisig response time (7-day) | Computed from Safe data | Number (hours) |
| Open incidents (by severity) | Incident tracker | Count badges |
| Alerts fired (24h / 7-day) | PagerDuty | Bar chart by severity |
| False positive rate (7-day) | Manual tagging | Percentage |
| Automation success rate | Chainlink logs | Percentage |
| Gas spent on operations (7-day) | Transaction logs | ETH amount |
| LINK consumption rate | Token transfers | LINK/day with runway |
| Upcoming scheduled actions | Calendar | List |
| Documentation staleness | Git commits | Last updated dates |

### Layout

- Top row: Open incidents, pending multisig txs, automation health
- Middle: Alert volume trend (are we getting noisier or quieter?)
- Bottom left: Operational costs breakdown
- Bottom right: Upcoming actions and deadlines

---

## Implementation Recommendations

### Tool Mapping

| Dashboard | Recommended Platform |
|-----------|---------------------|
| Protocol Health | Tenderly + Custom frontend |
| Financial | Dune Analytics |
| Activity | Dune Analytics |
| Risk Indicators | Tenderly + Custom |
| User-Specific | Protocol frontend (React) |
| Operational | Grafana or internal tool |

### Data Sources

- **On-chain events**: Indexed via subgraph (The Graph) or direct RPC
- **Contract state**: Direct RPC calls (cached with 60s TTL)
- **Price data**: Chainlink feeds + DEX subgraph
- **Operational data**: PagerDuty API, Safe API, Chainlink Automation API
- **Historical analytics**: Dune Analytics SQL queries

### Access Control

| Dashboard | Access |
|-----------|--------|
| Protocol Health | Team only |
| Financial | Team only (summary published monthly) |
| Activity | Public |
| Risk Indicators | Team only |
| User-Specific | Public (user sees only their data) |
| Operational | Team only |

---

## Dashboard Review Cadence

- **Daily**: Protocol Health, Risk Indicators (morning check)
- **Weekly**: Financial, Activity, Operational (Monday review)
- **Monthly**: All dashboards reviewed for accuracy and relevance
- **Quarterly**: Dashboard requirements reassessed, new metrics added/removed

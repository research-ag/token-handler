# Detected bugs

This document lists defects discovered while adding tests to the project.
For each bug there is a corresponding **commented-out**, failing reproduction
test in `test/detected_bugs.test.mo`. The reproductions are commented out so
that the test suite stays green; uncomment a block to observe the failure.

The production code was intentionally **not** modified (per the task); only
tests were added.

---

## Bug 1 — `state()` traps (arithmetic overflow) when total withdrawals exceed total consolidations

**Location:** `src/lib.mo`, function `state`, line 206:

```motoko
consolidated = d.totalConsolidated - w.totalWithdrawn;

```

**Problem:**
Both `d.totalConsolidated` and `w.totalWithdrawn` are `Nat`, so the subtraction
traps ("arithmetic overflow") whenever `totalWithdrawn > totalConsolidated`.

This is not an exotic situation. Credit can enter the system **without ever
being consolidated** — most notably through `depositFromAllowance`, which
credits the user directly (it increases `allowanceManager.totalCredited` but
never `depositManager.totalConsolidated`). As soon as such credit is withdrawn,
`totalWithdrawn` becomes positive while `totalConsolidated` is still `0`, and
any subsequent call to `state()` traps.

**Reproduction (see `test/detected_bugs.test.mo`, block "Bug 1"):**

1. `depositFromAllowance` to credit a user 10 (no consolidation happens).
2. `withdrawFromCredit` the full 10 (`totalWithdrawn` becomes 10).
3. Call `handler.state()` → traps with `arithmetic overflow` at `lib.mo:206`.

Observed failure:

```
FAIL src/lib.mo:206:24: execution error, arithmetic overflow
-> 206 |         consolidated = d.totalConsolidated - w.totalWithdrawn;
```

**Impact:** `state()` is a public, read-only accessor. After a legitimate
allowance-based deposit + withdrawal, the whole canister can no longer report
its state (every `state()` call traps). Note that the internal accounting
invariant (`assertInvariant`) still holds — only the `state()` projection is
broken.

**Suggested fix:** compute the value in `Int` (e.g. expose `consolidated` as an
`Int`, or `Int.max(0, totalConsolidated - totalWithdrawn)`), or track the net
consolidated balance in a way that cannot go negative.

---

## Bug 2 — `notify` traps (arithmetic overflow) when the tracked deposit decreases

**Location:** `src/DepositManager.mo`, function `do_notify`, lines 94–98:

```motoko
let prevDeposit = entry.deposit();
if (latestDeposit < prevDeposit) trap("latestDeposit < prevDeposit on notify");
if (latestDeposit == prevDeposit) return ?(0, 0);
entry.setDeposit(latestDeposit);

let depositInc = latestDeposit - prevDeposit : Nat;

```

**Problem:**
The `trap` parameter is **not** a real trap/abort — in `lib.mo` it is bound to
`freezeTokenHandler`, which merely sets `isFrozen_ := true` and logs an
`#error`. It does **not** stop execution. Therefore, when
`latestDeposit < prevDeposit`, the function keeps running and reaches
`latestDeposit - prevDeposit : Nat`, which underflows and causes a **real**
arithmetic-overflow trap of the whole message.

Because the message traps, all its state changes are rolled back — including the
`isFrozen_ := true` that was supposed to happen — so the intended "freeze the
handler gracefully and keep going" behaviour is never achieved.

**Reproduction (see `test/detected_bugs.test.mo`, block "Bug 2"):**

1. `notify` with balance 20 → tracked deposit becomes 20.
2. `notify` again with a decreased balance 10 (still above the fee).
3. The call traps with `arithmetic overflow` at `DepositManager.mo:98`.

Observed failure:

```
FAIL src/DepositManager.mo:98:22: execution error, arithmetic overflow
-> 98 | let depositInc = latestDeposit - prevDeposit : Nat;
```

**Impact:** A decreasing sub-account balance between two `notify` calls (e.g.
funds moved out externally, or a ledger quirk) hard-traps `notify` instead of
freezing the handler as the guard clearly intends.

**Suggested fix:** make the guard actually stop execution, e.g. `return null`
(or a dedicated result) right after invoking the freeze callback, instead of
falling through into the `Nat` subtraction.

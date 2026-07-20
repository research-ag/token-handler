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

---

## Bug 3 — `consolidate()` traps (arithmetic overflow) when the ledger fee decreases during an in-flight consolidation

**Location:** `src/DepositManager.mo`, function `consolidate` (the stale `fee`
captured before the transfer `await`); the trap itself surfaces in
`src/FeeManager.mo`, function `subtractFee`, line 46:

```motoko
// DepositManager.consolidate
let fee = feeManager.ledgerFee(icrc84); // captured BEFORE await
let consolidated : Nat = deposit - fee;
let res = await* ICRC84Helper.consolidate(icrc84, entry.key(), deposit, ctx);
switch (res) {
  case (#ok _) {
    self.totalConsolidated += consolidated;
    entry.setDeposit(0);
    feeManager.subtractFee(fee); // uses STALE fee
    ...;
  };
  ...;
};

```

```motoko
// FeeManager.subtractFee
public func subtractFee(self : FeeManager, fee : Nat) {
  self.outstandingFees -= fee; // Nat underflow -> trap
};

```

**Problem:**
`consolidate` reads the ledger fee into `fee` **before** awaiting the transfer.
While the transfer message is in flight, a concurrent `fetchFee` can lower the
ledger fee. That fee change runs `FeeManager.onFeeChanged`, which lowers
`outstandingFees` for every still-queued deposit (the deposit being consolidated
is still in the deposits tree, since `setDeposit(0)` has not been called yet).
When the transfer then returns `#ok`, `consolidate` calls
`feeManager.subtractFee(fee)` with the **stale, higher** fee. Since
`outstandingFees` has already been reduced to reflect the new lower fee,
`outstandingFees -= fee` underflows (`Nat`) and traps the whole message.

Because the message traps, all of its effects are rolled back: the successful
consolidation is effectively lost, and repeated attempts keep trapping under the
same conditions.

**Reproduction (see `test/detected_bugs.test.mo`, block "Bug 3"):**

1. Set the ledger fee to 5.
2. `notify` balance 20 → tracked deposit 20, `outstandingFees` = 5.
3. Start a successful consolidation (transfer returns `#Ok`) but, while it is in
   flight, `fetchFee` lowers the ledger fee to 3 (so `onFeeChanged` reduces
   `outstandingFees` to 3).
4. The consolidation success path calls `subtractFee(5)` while `outstandingFees`
   is only 3 → traps with `arithmetic overflow`.

Observed failure:

```
FAIL src/FeeManager.mo:46:5: execution error, arithmetic overflow
-> 46 |     self.outstandingFees -= fee;
```

**Impact:** A ledger-fee decrease that races with a successful consolidation
hard-traps the consolidation instead of completing it, and the trap rolls back
the transfer bookkeeping. The mirror case (fee _increase_) does not trap but
leaves `outstandingFees`/`handlerPool` skewed, because `consolidated` and the
subtracted fee are likewise computed from the stale value.

**Suggested fix:** re-read the current ledger fee after the transfer completes
(or track the exact fee actually charged by the ledger for that transfer) and
use that value for both `consolidated` and `subtractFee`, instead of the value
captured before the `await`.

// Failing reproductions for the bugs described in ../detected_bugs.md.
//
// These tests are INTENTIONALLY COMMENTED OUT so that the test suite stays
// green. Uncomment a block (and the imports) to observe the corresponding
// failure. The production code was not changed (per the task); only tests were
// added.
//
// import Principal "mo:core/Principal";

// import TokenHandler "../src";
// import MockLedger "util/mock_ledger";
// import Util "util/common";

// let DEBUG = false;
// let user1 = Principal.fromBlob("1");
// let user1_account = { owner = user1; subaccount = null };
// let account = { owner = Principal.fromBlob("o"); subaccount = null };

// // ---------------------------------------------------------------------------
// // Bug 1: state() traps with arithmetic overflow when totalWithdrawn exceeds
// //        totalConsolidated (e.g. after an allowance-funded credit is
// //        withdrawn, since allowance deposits never get consolidated).
// // Fails at: src/lib.mo:206  (consolidated = d.totalConsolidated - w.totalWithdrawn)
// // ---------------------------------------------------------------------------
// do {
//   let mock_ledger = MockLedger.MockLedger(DEBUG, "bug1");
//   let (handler, ctx, _journal, _) = Util.createHandler(mock_ledger, false);

//   // fee 0, surcharge 0: credit user1 with 10 via allowance (no consolidation).
//   ignore mock_ledger.transfer_from_.stage_unlocked(? #Ok 1);
//   assert (await* TokenHandler.depositFromAllowance(handler, user1, user1_account, 10, null, ctx)) == #ok(10, 1);
//   assert handler.userCredit(user1) == 10;

//   // Withdraw the whole credit: totalWithdrawn becomes 10 while
//   // totalConsolidated is still 0.
//   ignore mock_ledger.transfer_.stage_unlocked(? #Ok 2);
//   assert (await* TokenHandler.withdrawFromCredit(handler, user1, account, 10, null, ctx)) == #ok(2, 10);

//   // BUG: this traps with "arithmetic overflow" (0 - 10 as Nat) instead of
//   // returning consolidated = 0.
//   let s = handler.state();
//   assert s.flow.withdrawn == 10;
// };

// // ---------------------------------------------------------------------------
// // Bug 2: notify() traps with arithmetic overflow when the tracked deposit
// //        decreases. The `trap` callback (freezeTokenHandler) only logs/sets a
// //        flag and does NOT abort, so execution falls through to
// //        `latestDeposit - prevDeposit : Nat`.
// // Fails at: src/DepositManager.mo:98
// // ---------------------------------------------------------------------------
// do {
//   let mock_ledger = MockLedger.MockLedger(DEBUG, "bug2");
//   let (handler, ctx, _journal, _) = Util.createHandler(mock_ledger, false);

//   // fee 0, surcharge 0: notify balance 20 -> tracked deposit becomes 20.
//   ignore mock_ledger.balance_.stage_unlocked(?20);
//   assert (await* TokenHandler.notify(handler, user1, ctx)) == ?(20, 20);
//   assert handler.userCredit(user1) == 20;

//   // Notify again with a DECREASED balance 10 (< previous 20, > fee 0).
//   // BUG: this traps with "arithmetic overflow" instead of gracefully
//   // freezing the handler.
//   ignore mock_ledger.balance_.stage_unlocked(?10);
//   ignore (await* TokenHandler.notify(handler, user1, ctx));
// };

// // ---------------------------------------------------------------------------
// // Bug 3: consolidate() traps with arithmetic overflow (outstandingFees
// //        underflow) when the ledger fee DECREASES while a SUCCESSFUL
// //        consolidation transfer is in flight.
// //
// //        consolidate() captures `fee = feeManager.ledgerFee(...)` BEFORE the
// //        transfer await. If a concurrent fetchFee lowers the ledger fee, then
// //        onFeeChanged() lowers `outstandingFees` accordingly. On the success
// //        path consolidate() then calls `feeManager.subtractFee(fee)` with the
// //        STALE (higher) fee, so `outstandingFees -= fee` underflows.
// // Fails at: src/FeeManager.mo:46 (self.outstandingFees -= fee)
// // ---------------------------------------------------------------------------
// do {
//   let mock_ledger = MockLedger.MockLedger(DEBUG, "bug3");
//   let (handler, ctx, _journal, state) = Util.createHandler(mock_ledger, false);

//   // ledger fee = 5, surcharge = 0.
//   ignore mock_ledger.fee_.stage_unlocked(?5);
//   ignore (await* TokenHandler.fetchFee(handler, ctx));
//   assert handler.ledgerFee() == 5;

//   // notify balance 20 -> credit 15, deposit 20, outstandingFees = 5.
//   ignore mock_ledger.balance_.stage_unlocked(?20);
//   assert (await* TokenHandler.notify(handler, user1, ctx)) == ?(20, 15);
//   assert state() == (20, 0, 1);

//   // Start a successful consolidation, but decrease the ledger fee to 3 while
//   // the transfer is in flight. onFeeChanged lowers outstandingFees 5 -> 3.
//   ignore mock_ledger.transfer_.stage_unlocked(?#Ok 0);
//   ignore mock_ledger.fee_.stage_unlocked(?3);
//   let f = async { await* TokenHandler.trigger(handler, 1, ctx) };
//   ignore (await* TokenHandler.fetchFee(handler, ctx));

//   // BUG: consolidate() success path calls subtractFee(5) while outstandingFees
//   // is only 3 -> arithmetic overflow trap at FeeManager.mo:46.
//   await f;
//   assert state() == (0, 15, 0);
// };
